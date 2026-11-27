defmodule Newbee.Colony.ProjectReview do
  @moduledoc "Independent file-contract verification and durable adoption into the project's isolated workspace."
  alias Newbee.Colony.{Control, Decomposition, Honey, Store, Trace, WorkspaceReview}

  @doc false
  def schedule do
    if Enum.any?(Store.list_tasks(), &candidate?/1) do
      Task.Supervisor.start_child(__MODULE__.Tasks, &run_once/0)
    end

    :ok
  end

  @doc "Process one pending candidate. Restarting the reviewer reuses the existing application receipt."
  def run_once do
    tasks = Map.new(Store.list_tasks(), &{&1["id"], &1})

    tasks
    |> Map.values()
    |> Enum.filter(&candidate?/1)
    |> Enum.sort_by(&{if(&1["application"], do: 0, else: 1), &1["created_at"], &1["id"]})
    |> Enum.find(fn child ->
      root = tasks[child["workflow_root"]]

      active_root?(root, child) and
        not staging_unsettled?(siblings(tasks, root), child["id"]) and
        not Control.blocked?(root["colony_id"], root["assigned_bee_id"], root["id"]) and
        not Control.blocked?(child["colony_id"], child["assigned_bee_id"], child["id"])
    end)
    |> case do
      nil -> :idle
      child -> verify(child)
    end
  end

  # Also checked inside the WorkspaceReview intent transaction, immediately before file writes.
  @doc false
  def eligible?(data, child) do
    root = data["tasks"][child["workflow_root"]]
    cid = child["colony_id"]

    candidate?(child) and active_root?(root, child) and
      not staging_unsettled?(siblings(data["tasks"], root), child["id"]) and
      Enum.all?(
        [
          {"colony", cid},
          {"work", root["id"]},
          {"work", child["id"]},
          {"bee", root["assigned_bee_id"]},
          {"bee", child["assigned_bee_id"]}
        ],
        fn {scope, id} -> get_in(data, ["controls", Control.key(cid, scope, id), "paused"]) != true end
      )
  end

  @doc false
  def authorize_apply?(data, child, changes) do
    root = data["tasks"][child["workflow_root"]]

    eligible?(data, child) and isolated_target(root, child) == :ok and
      Enum.sort(Enum.map(changes, & &1["path"])) == Enum.sort(child["project_writes"])
  end

  @doc false
  def staging_unsettled?(children, except \\ nil) do
    Enum.any?(children, fn child ->
      child["id"] != except and get_in(child, ["application", "state"]) in ~w(applying partial unknown failed)
    end)
  end

  @doc false
  def can_materialize?(child) do
    case Store.get_task(child["workflow_root"]) do
      {:ok, root} ->
        active_root?(root, child) and
          not staging_unsettled?(
            Store.tasks_for_colony(root["colony_id"])
            |> Enum.filter(&(&1["workflow_root"] == root["id"]))
          )

      _ ->
        false
    end
  end

  defp siblings(tasks, root), do: Enum.map(root["workflow"]["children"] || [], &tasks[&1])

  defp active_root?(root, child) do
    is_map(root) and Decomposition.project?(root) and root["status"] not in ["cancelled", "done", "failed"] and
      root["colony_id"] == child["colony_id"] and get_in(root, ["workflow", "phase"]) == "executing" and
      child["id"] in (get_in(root, ["workflow", "children"]) || [])
  end

  defp candidate?(child) do
    child["status"] == "pending_review" and Decomposition.project_step?(child) and
      is_binary(child["result"]) and is_nil(child["project_review_error"])
  end

  defp verify(child) do
    with {:ok, root} <- Store.get_task(child["workflow_root"]),
         :ok <- isolated_target(root, child),
         {:ok, review} <- WorkspaceReview.review(child),
         :ok <- declared_files(child["project_writes"], review),
         {:ok, receipt} <- WorkspaceReview.apply(child, review["patch_sha256"], "project:" <> child["result"]) do
      finish(child, receipt)
    else
      {:error, code, message} -> record_error(child, code, message)
      _ -> record_error(child, "workspace_missing", "项目隔离工作区不可用")
    end
  end

  defp isolated_target(root, child) do
    target = get_in(root, ["workspace", "path"])

    if is_binary(target) and target != "/" and target != root["source_root"] and
         child["workspace_source"] == target and get_in(child, ["workspace", "root"]) == target do
      :ok
    else
      {:error, "wrong_project_target", "只能将分项成果应用到总任务的隔离工作区"}
    end
  end

  defp declared_files(expected, review) do
    actual = Enum.map(review["files"], & &1["path"])

    if review["omitted_files"] == 0 and Enum.sort(actual) == Enum.sort(expected) do
      :ok
    else
      missing = Enum.take(expected -- actual, 4)
      extra = Enum.take(actual -- expected, 4)
      {:error, "project_file_contract", "未通过文件交付验收：缺少 #{inspect(missing)}；范围外 #{inspect(extra)}。"}
    end
  end

  defp finish(child, receipt) do
    Store.transaction(fn data ->
      current = data["tasks"][child["id"]]
      honey = data["honey"][child["result"]]
      application = current && current["application"]

      if same_candidate?(current, child) and eligible?(data, current) and is_map(honey) and
           honey["work_revision"] == current["context_revision"] and is_map(application) and
           application["state"] == "applied" and application["patch_sha256"] == receipt["patch_sha256"] and
           application["honey_id"] == honey["id"] and application["context_revision"] == current["context_revision"] do
        note = "已核对声明文件及实际差异，补丁已进入项目隔离工作区；仍需组合测试。"
        {:ok, reviewed} = Honey.review(honey, "accept", "project-checker", note)
        updated = bump(current, %{"status" => "done", "waiting_for" => nil, "next_step" => note})
        data = data |> put_in(["tasks", child["id"]], updated) |> put_in(["honey", honey["id"]], reviewed)

        {data, _} =
          Store.put_entry(
            data,
            "trace",
            Trace.entry(%{
              "colony_id" => child["colony_id"],
              "task_id" => child["id"],
              "type" => "honey",
              "text" => note,
              "data" => %{"honey_id" => honey["id"], "patch_sha256" => receipt["patch_sha256"]}
            })
          )

        {:ok, {:ok, receipt}, data}
      else
        {:ok, :ignored, data}
      end
    end)
  end

  defp record_error(child, code, message) do
    Store.transaction(fn data ->
      current = data["tasks"][child["id"]]

      if same_candidate?(current, child) and eligible?(data, current) do
        # A bad, unapplied candidate can be sent back to a worker. An ambiguous application
        # must be reconciled against the same receipt and never automatically rerun.
        rework = code == "project_file_contract" and is_nil(current["application"])

        updated =
          bump(current, %{
            "status" => if(rework, do: "blocked", else: "pending_review"),
            "waiting_for" => "project_review",
            "project_review_error" => message,
            "next_step" => message
          })

        {:ok, {:error, code, message}, put_in(data, ["tasks", child["id"]], updated)}
      else
        {:ok, :ignored, data}
      end
    end)
  end

  defp same_candidate?(current, child) do
    is_map(current) and current["status"] == "pending_review" and current["result"] == child["result"] and
      current["execution_generation"] == child["execution_generation"] and
      current["context_revision"] == child["context_revision"]
  end

  defp bump(task, attrs),
    do:
      task
      |> Map.merge(attrs)
      |> Map.update!("revision", &(&1 + 1))
      |> Map.put("updated_at", System.system_time(:millisecond))
end
