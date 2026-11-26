defmodule Newbee.Colony.Decomposition do
  @moduledoc "Bounded task plans, isolated assignments and recovery-safe dependency scheduling."
  alias Newbee.Colony.{Bee, Control, Honey, Id, ProjectLease, Store, Task, Work}
  @max_children 4
  @max_concurrency 3
  @project_max_children 30
  @project_concurrency 6
  @terminal ~w(done failed cancelled)
  @complete ~w(pending_review done)

  def managed?(%{"workflow" => %{"strategy" => strategy}} = task) when strategy in ["decompose", "project"],
    do: is_nil(task["workflow_root"]) and task["conversation_child"] != true

  def managed?(_), do: false

  def project?(task), do: get_in(task, ["workflow", "strategy"]) == "project" and managed?(task)
  def project_step?(task), do: is_list(task["project_writes"]) and task["conversation_child"] == true

  def context(task) do
    intro =
      "只读调查项目入口、约束、接口和测试，再规划可独立交付的分工。禁止修改文件、外部写入、调用Hive或派生会话。完成时 done 的 summary 只返回 JSON：\n"

    if project?(task) do
      intro <>
        ~s({"summary":"总体目标、接口与集成验证方法","tasks":[{"id":"api","title":"实现接口","scope":"边界和交付目标","writes":["lib/api.ex"],"depends_on":[],"acceptance":["可核对的验收项"]}]}) <>
        "。最多#{@project_max_children}项，同时执行最多#{@project_concurrency}项。只有可独立提交真实文件的分工才单列。每项 writes 列出 1 至 8 个确实需要新增、修改或删除的相对文件路径，不能列目录、通配符或重复分配同一文件。依赖必须引用本计划 id，不能成环。完成一项后，由系统检查差异与声明完全一致，并把通过的文件放入总任务隔离目录，下游才会开工。验收项陈述预期和测试方法，不是自动执行的命令。总任务还要做组合验证，最后由用户核对并采用。"
    else
      intro <>
        ~s({"summary":"整体方案与集成方法","tasks":[{"id":"implementation","title":"实现目标","scope":"交付目标、修改边界、验证方法","depends_on":[],"acceptance":["可核对的验收项"]}]}) <>
        "。1至4项，最多3项同时执行；简单任务可为1项，不为并发硬拆。有依赖的项目按顺序执行；依赖必须引用本计划id且无环。每项分工均在独立目录执行，最终由负责人集成真实文件并组合验证。"
    end
  end

  # This function and advance/1 run inside the Store transaction. No Store calls,
  # filesystem reads or process messages are allowed in this snapshot boundary.
  def complete(data, root, summary) do
    current = data["tasks"][root["id"]] || root

    cond do
      not managed?(current) ->
        {:error, "invalid_workflow", "当前任务不支持自动分工"}

      (get_in(current, ["workflow", "children"]) || []) != [] ->
        {:ok, {:ok, current}, data}

      current["status"] in @terminal ->
        {:ok, :ignored, data}

      true ->
        with {:ok, plan_summary, plan} <- parse_plan(summary, project?(current)),
             path when is_binary(path) and path != "/" <- get_in(current, ["workspace", "path"]) do
          {data, root} = build_plan(data, current, plan_summary, plan)
          next = dispatch_ready(data, root)
          {:ok, {:ok, next["tasks"][root["id"]]}, next}
        else
          {:error, reason} -> block_plan(data, current, reason)
          _ -> block_plan(data, current, "独立工作目录尚未就绪，请重试规划。")
        end
    end
  end

  def advance(data) do
    data = ProjectLease.expire(data, System.system_time(:millisecond))

    (data["tasks"] || %{})
    |> Map.values()
    |> Enum.filter(&managed?/1)
    |> Enum.reduce(data, fn root, acc ->
      root = acc["tasks"][root["id"]]

      if root["status"] not in @terminal and get_in(root, ["workflow", "phase"]) == "executing" and
           not paused?(acc, root) do
        acc = dispatch_ready(acc, root)
        children = child_tasks(acc, root)

        if children != [] and length(children) == length(root["workflow"]["children"]) and
             Enum.all?(children, &released?(acc, &1)) do
          integrate(acc, root, children)
        else
          acc
        end
      else
        acc
      end
    end)
  end

  def view(root) do
    tasks = Map.new(Store.all("tasks"), &{&1["id"], &1})
    honey = Map.new(Store.all("honey"), &{&1["id"], &1})
    snapshot = %{"tasks" => tasks, "honey" => honey}
    children = child_tasks(snapshot, root)

    devices =
      if ProjectLease.pool?(root) do
        ids =
          MapSet.new(
            Store.all("identities") |> Enum.filter(&(&1["colony_id"] == root["colony_id"] and &1["revoked"] == false)),
            & &1["bee_id"]
          )

        now = System.system_time(:millisecond)

        Store.list_bees()
        |> Enum.filter(
          &(&1["colony_id"] == root["colony_id"] and &1["project_runner_allowed"] == true and
              MapSet.member?(ids, &1["id"]))
        )
        |> Enum.map(fn bee ->
          Map.take(bee, ~w(id display)) |> Map.put("state", ProjectLease.device_status(bee, now))
        end)
        |> Enum.sort_by(& &1["display"])
      else
        []
      end

    rows =
      Enum.map(children, fn child ->
        result = honey[child["result"]] || %{}

        %{
          "id" => child["id"],
          "title" => child["title"],
          "scope" => child["description"],
          "device" => Enum.find_value(devices, fn d -> if d["id"] == child["assigned_bee_id"], do: d["display"] end),
          "status" => if(child["project_review_error"], do: "blocked", else: child["status"]),
          "waiting_for" => child["waiting_for"],
          "depends_on" => child["depends_on"] || [],
          "activity" => child["project_review_error"] || child["activity"],
          "next_step" => child["next_step"],
          "summary" => result["content"],
          "question" => child["question"]
        }
      end)

    %{
      "phase" =>
        case root["status"] do
          "pending_review" -> "reviewing"
          "done" -> "completed"
          "cancelled" -> "ended"
          _ -> get_in(root, ["workflow", "phase"]) || "planning"
        end,
      "summary" => get_in(root, ["workflow", "summary"]) || "",
      "strategy" => get_in(root, ["workflow", "strategy"]),
      "pool" => get_in(root, ["workflow", "project_pool"]),
      "devices" => devices,
      "concurrency" => concurrency(root),
      "total" => length(get_in(root, ["workflow", "children"]) || []),
      "completed" => Enum.count(children, &released?(snapshot, &1)),
      # settled 数“不再推进”的分项：交付、失败、取消都算，用来回答
      # “这条工作是不是已经收尾了”。只看 completed 会让被取消/失败的分项
      # 永远停在 0/N，进度看起来永不结束。
      "settled" => Enum.count(children, &settled?(snapshot, &1)),
      "failed" => Enum.count(children, &(&1["status"] == "failed")),
      "cancelled" => Enum.count(children, &(&1["status"] == "cancelled")),
      "children" => rows
    }
  end

  defp settled?(data, child) do
    child["status"] in @terminal or released?(data, child)
  end

  defp parse_plan(text, project) when is_binary(text) and byte_size(text) <= 100_000 do
    text = String.trim(text)
    limit = if project, do: @project_max_children, else: @max_children

    slices =
      case {:binary.match(text, "{"), :binary.matches(text, "}")} do
        {{first, _}, ends} when ends != [] ->
          [{last, _}] = Enum.take(ends, -1)
          if last >= first, do: [binary_part(text, first, last - first + 1)], else: []

        _ ->
          []
      end

    decoded =
      Enum.find_value([text | slices], fn part ->
        case Jason.decode(part) do
          {:ok, value} -> {:parsed, value}
          _ -> nil
        end
      end)

    with {:parsed, %{"summary" => summary, "tasks" => items}} <- decoded,
         true <- nonempty?(summary, 4000),
         true <- is_list(items) and length(items) in 1..limit,
         {:ok, plan} <- normalize_plan(items, project, limit),
         true <- valid_dag?(plan),
         true <- not project or disjoint_paths?(Enum.flat_map(plan, & &1["writes"])) do
      {:ok, String.trim(summary), plan}
    else
      _ ->
        note = if project, do: "；writes 必须是具体、不重叠的相对文件路径", else: ""
        {:error, "分工计划无效：请返回1至#{limit}项明确目标、范围和验收要求，依赖必须存在且不能成环#{note}。"}
    end
  end

  defp parse_plan(_, _), do: {:error, "分工计划必须是有效且不超过 100 KB 的 JSON 文本。"}

  defp normalize_plan(items, project, limit) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      if is_map(item) and nonempty?(item["id"], 64) and Regex.match?(~r/\A[a-zA-Z0-9._-]+\z/, item["id"]) and
           nonempty?(item["title"], 200) and nonempty?(item["scope"], 10_000) and
           is_list(item["depends_on"] || []) and length(item["depends_on"] || []) <= limit and
           Enum.all?(item["depends_on"] || [], &nonempty?(&1, 64)) and
           is_list(item["acceptance"]) and length(item["acceptance"]) in 1..20 and
           Enum.all?(item["acceptance"], &nonempty?(&1, 2000)) and
           (not project or valid_writes?(item["writes"])) do
        normalized =
          Map.take(item, if(project, do: ~w(id title scope acceptance writes), else: ~w(id title scope acceptance)))
          |> Map.put("depends_on", Enum.uniq(item["depends_on"] || []))

        {:cont, {:ok, [normalized | acc]}}
      else
        {:halt, :invalid}
      end
    end)
    |> case do
      {:ok, plan} -> {:ok, Enum.reverse(plan)}
      error -> error
    end
  end

  defp valid_writes?(paths) when is_list(paths) and length(paths) in 1..8 do
    Enum.all?(paths, fn path ->
      nonempty?(path, 512) and not Regex.match?(~r/[[:cntrl:]\\*?\[\]{}:]/, path) and
        Enum.all?(
          String.split(path, "/"),
          &(&1 not in ["", ".", "..", ".git", ".newbee", "_build", "deps", "node_modules"])
        )
    end)
  end

  defp valid_writes?(_), do: false

  defp disjoint_paths?(paths) do
    set = MapSet.new(paths)

    MapSet.size(set) == length(paths) and
      Enum.all?(paths, fn path ->
        parts = String.split(path, "/")
        parents = parts |> Enum.drop(-1) |> Enum.scan(&(&2 <> "/" <> &1))
        Enum.all?(parents, &(not MapSet.member?(set, &1)))
      end)
  end

  defp valid_dag?(plan) do
    deps = Map.new(plan, &{&1["id"], MapSet.new(&1["depends_on"])})

    length(plan) == map_size(deps) and
      Enum.all?(deps, fn {_id, refs} -> Enum.all?(refs, &Map.has_key?(deps, &1)) end) and
      peel_ready(deps)
  end

  # Remove whole ready layers instead of walking the same ancestry repeatedly in a diamond DAG.
  defp peel_ready(deps) when map_size(deps) == 0, do: true

  defp peel_ready(deps) do
    ready = for {id, refs} <- deps, MapSet.size(refs) == 0, into: MapSet.new(), do: id

    MapSet.size(ready) > 0 and
      deps
      |> Map.drop(MapSet.to_list(ready))
      |> Map.new(fn {id, refs} -> {id, MapSet.difference(refs, ready)} end)
      |> peel_ready()
  end

  defp build_plan(data, root, summary, plan) do
    ids = Map.new(plan, &{&1["id"], Id.new(:task, :local)})
    project = project?(root)

    {data, children} =
      Enum.reduce(Enum.with_index(plan, 1), {data, []}, fn {item, index}, {acc, children} ->
        {acc, bee_id} = if project, do: {acc, nil}, else: new_worker(acc, root["colony_id"], "执行者 #{index}")
        deps = Enum.map(item["depends_on"], &ids[&1])

        child =
          Task.new(%{
            "id" => ids[item["id"]],
            "colony_id" => root["colony_id"],
            "title" => item["title"],
            "description" => item["scope"],
            "parent_task_id" => root["id"],
            "assigned_bee_id" => bee_id,
            "coordinator_bee_id" => root["assigned_bee_id"],
            "cwd" => root["cwd"],
            "acceptance" => item["acceptance"],
            "constraints" => root["constraints"] || [],
            "facts" => root["facts"] || []
          })
          |> Map.merge(Map.take(root, ~w(source_root origin_session_id execution_config)))
          |> Map.merge(%{
            "plan_id" => item["id"],
            "depends_on" => deps,
            "workflow_root" => root["id"],
            "owner_kind" => "ai",
            "created_by" => root["created_by"],
            "workspace_source" => get_in(root, ["workspace", "path"]),
            "integration_required" => true,
            "conversation" => true,
            "conversation_child" => true,
            "autonomous" => true,
            "mode" => "execution",
            "inputs" => [],
            "execution_generation" => 1,
            "consumed_context_revision" => 0,
            "status" => "blocked",
            "waiting_for" => if(deps == [], do: "capacity", else: "dependencies"),
            "next_step" => if(deps == [], do: "等待可用执行位置。", else: "等待上游分工交付。")
          })

        child = if project, do: Map.put(child, "project_writes", item["writes"]), else: child
        {put_in(acc, ["tasks", child["id"]], child), [child["id"] | children]}
      end)

    children = Enum.reverse(children)

    root =
      root
      |> put_in(["workflow", "plan"], plan)
      |> put_in(["workflow", "summary"], summary)
      |> put_in(["workflow", "children"], children)
      |> put_in(["workflow", "phase"], "executing")
      |> Map.merge(%{
        "mode" => "execution",
        "status" => "blocked",
        "waiting_for" => "children",
        "next_step" => "各项分工按依赖推进，交付后统一集成验证。"
      })
      |> bump()

    {put_in(data, ["tasks", root["id"]], root), root}
  end

  defp new_worker(data, cid, display) do
    bee = Bee.new(%{"colony_id" => cid, "kind" => "ai", "role" => "worker", "display" => display})
    {put_in(data, ["bees", bee["id"]], bee), bee["id"]}
  end

  defp concurrency(root), do: if(project?(root), do: @project_concurrency, else: @max_concurrency)

  defp dispatch_ready(data, root) do
    children = child_tasks(data, root)

    if project?(root) and Newbee.Colony.ProjectReview.staging_unsettled?(children),
      do: data,
      else: dispatch_ready(data, root, children)
  end

  defp dispatch_ready(data, root, children) do
    limit = concurrency(root)

    live_deliveries =
      for d <- Map.values(data["deliveries"] || %{}),
          d["status"] in ["pending", "dispatching", "accepted", "remote_pending"],
          into: MapSet.new(),
          do: d["task_id"]

    active = Enum.count(children, &occupied?(data, &1, live_deliveries))

    {data, _count} =
      Enum.reduce_while(children, {data, active}, fn child, {acc, count} ->
        cond do
          count >= limit or paused?(acc, root) ->
            {:halt, {acc, count}}

          child["status"] == "blocked" and child["waiting_for"] in ["dependencies", "capacity"] and
            not paused?(acc, child) and
              Enum.all?(child["depends_on"] || [], fn dep -> released?(acc, acc["tasks"][dep]) end) ->
            case ProjectLease.allocate(acc, root, child, System.system_time(:millisecond)) do
              {:ok, assigned} -> {:cont, {dispatch_child(acc, assigned), count + 1}}
              :wait -> {:halt, {acc, count}}
            end

          true ->
            {:cont, {acc, count}}
        end
      end)

    data
  end

  defp dispatch_child(data, child) do
    deps = Enum.map(child["depends_on"] || [], &data["tasks"][&1])
    project = project_step?(child)

    {data, bee_id} =
      if is_binary(child["assigned_bee_id"]),
        do: {data, child["assigned_bee_id"]},
        else: new_worker(data, child["colony_id"], "项目执行 · " <> child["title"])

    instruction =
      if project do
        "只完成此项目分项。仅在你的隔离目录修改 writes 声明的文件，每个声明文件都应存在对应差异。依赖补丁已经放入你的基线，不要复制其他分项工作区。交付真实文件、验证与未覆盖范围；系统另行检查并应用来源差异。不得修改父级/源项目，禁止外部写入或再委派。\n" <>
          Jason.encode!(%{
            "scope" => child["description"],
            "writes" => child["project_writes"],
            "acceptance" => child["acceptance"],
            "retry_note" => child["project_retry_note"],
            "dependencies" => project_material(data, deps)
          })
      else
        "只完成这项已分配分工，不自行再委派。只修改自己的隔离目录；上游目录仅可读取。需要上游文件时先把必要变更集成到自己目录，再实施和验证。交付真实文件位置、修改说明、验证与限制。\n" <>
          Jason.encode!(%{
            "scope" => child["description"],
            "acceptance" => child["acceptance"],
            "dependencies" => material(data, deps)
          })
      end

    child =
      child
      |> Map.merge(%{
        "status" => "claimed",
        "assigned_bee_id" => bee_id,
        "waiting_for" => nil,
        "next_step" => "按分工实施并验证。",
        "context_revision" => child["context_revision"] + 1
      })
      |> bump()

    data =
      if ProjectLease.remote?(child),
        do: put_in(data, ["bees", bee_id, "project_last_claimed_at"], System.system_time(:millisecond)),
        else: data

    delivery = Work.new_delivery(child, %{"instruction" => instruction})
    data |> put_in(["tasks", child["id"]], child) |> put_in(["deliveries", delivery["id"]], delivery)
  end

  defp integrate(data, root, children) do
    root =
      root
      |> put_in(["workflow", "phase"], "integrating")
      |> Map.merge(%{
        "mode" => "execution",
        "status" => "claimed",
        "waiting_for" => nil,
        "next_step" => "分工已交付，负责人正在集成真实文件并组合验证。",
        "context_revision" => root["context_revision"] + 1
      })
      |> bump()

    instruction =
      if project?(root) do
        "所有分项已通过文件范围与差异指纹检查，补丁已经应用到你的隔离工作区；不要重新应用。核对组合改动和用户补充要求，运行适用的项目测试，报告实际结果和未验证范围。不写源项目、不提交或推送；最终由用户核对与采用。\n" <>
          Jason.encode!(project_material(data, children))
      else
        "所有分工已交付。读取每个独立工作目录的真实文件，将需要的修改合入你的隔离目录，解决接口与文件冲突，并运行组合验证。不得只拼接总结声称完成；不要写回源项目、提交或推送。结合pending_inputs中的最新要求，报告成果位置、验证方法与未验证范围。\n" <>
          Jason.encode!(material(data, children))
      end

    delivery = Work.new_delivery(root, %{"instruction" => instruction})
    data |> put_in(["tasks", root["id"]], root) |> put_in(["deliveries", delivery["id"]], delivery)
  end

  defp material(data, children) do
    Enum.map(children, fn child ->
      result = data["honey"][child["result"]] || %{}

      %{
        "title" => child["title"],
        "workspace" => child["workspace"],
        "content" => result["content"],
        "evidence" => result["evidence"],
        "limitations" => result["limitations"]
      }
    end)
  end

  defp child_tasks(data, root),
    do:
      Enum.flat_map(get_in(root, ["workflow", "children"]) || [], fn id ->
        case data["tasks"][id] do
          nil -> []
          child -> [child]
        end
      end)

  defp submitted?(_data, nil), do: false

  defp submitted?(data, child) do
    result = data["honey"][child["result"]]
    child["status"] in @complete and is_map(result) and result["work_revision"] == child["context_revision"]
  end

  defp project_material(data, children) do
    Enum.map(children, fn child ->
      %{
        "id" => child["plan_id"],
        "writes" => child["project_writes"],
        "patch_sha256" => get_in(child, ["application", "patch_sha256"]),
        "honey_id" => child["result"],
        "summary" => data["honey"][child["result"]]["content"] |> to_string() |> String.slice(0, 600)
      }
    end)
  end

  @doc false
  def released?(_data, nil), do: false

  def released?(data, child) do
    if project_step?(child) do
      child["status"] == "done" and submitted?(data, child) and
        Honey.accepted?(data["honey"][child["result"]]) and
        get_in(child, ["application", "state"]) == "applied" and
        get_in(child, ["application", "context_revision"]) == child["context_revision"] and
        get_in(child, ["application", "honey_id"]) == child["result"]
    else
      submitted?(data, child)
    end
  end

  defp occupied?(data, child, live_deliveries) do
    not submitted?(data, child) and child["status"] not in @terminal and
      (child["status"] in ["claimed", "running"] or MapSet.member?(live_deliveries, child["id"]) or
         (project_step?(child) and is_map(child["question"])))
  end

  defp paused?(data, task) do
    cid = task["colony_id"]

    task["status"] in ["cancelled", "done"] or
      Enum.any?(
        [{"colony", cid}, {"work", task["id"]}, {"work", task["parent_task_id"]}, {"bee", task["assigned_bee_id"]}],
        fn {scope, id} ->
          is_binary(id) and get_in(data, ["controls", Control.key(cid, scope, id), "paused"]) == true
        end
      )
  end

  defp block_plan(data, root, reason) do
    root =
      root
      |> Map.merge(%{"status" => "blocked", "waiting_for" => "plan", "next_step" => reason <> " 可重试规划，不会据此直接执行。"})
      |> bump()

    {:ok, {:ok, root}, put_in(data, ["tasks", root["id"]], root)}
  end

  defp nonempty?(value, size), do: is_binary(value) and byte_size(value) in 1..size and String.trim(value) != ""

  defp bump(task),
    do: task |> Map.update("revision", 1, &(&1 + 1)) |> Map.put("updated_at", System.system_time(:millisecond))
end
