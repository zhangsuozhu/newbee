defmodule Newbee.Web.TeamWorkbench do
  @moduledoc "Read-only index pointing to existing task and approval records."
  alias Newbee.Colony.{Membership, Store}
  alias Newbee.Collaboration.{Coordinator, CrossHost}

  def dispatch(params) do
    token = params["__token__"]

    with :ok <- Membership.session_access(token, params["sessionId"]),
         {:error, _, _} <- Membership.authenticate(token) do
      {groups, tasks} = Coordinator.workbench()
      remote = CrossHost.Store.list_public()
      remote_tasks = CrossHost.Store.workbench_tasks()
      {:ok, project(Store.workbench_snapshot(), groups, remote, tasks, remote_tasks)}
    else
      _ -> {:error, "forbidden", "只有宿主用户可以查看跨团队工作台"}
    end
  end

  @doc false
  def project(data, groups, remote, hive_tasks \\ [], remote_tasks \\ []) do
    tasks = data["tasks"]
    colonies = data["colonies"]
    proposals = Map.values(data["team_proposals"])
    runs = Map.values(data["team_runs"])
    internal = MapSet.new(Enum.map(proposals, & &1["task_id"]) ++ Enum.map(runs, & &1["colony_id"]))

    children =
      tasks
      |> Map.values()
      |> Enum.filter(&(&1["conversation_hidden"] != true && is_binary(&1["workflow_root"] || &1["parent_task_id"])))
      |> Enum.group_by(&(&1["workflow_root"] || &1["parent_task_id"]))

    rows =
      Enum.flat_map(tasks, fn {id, task} ->
        cond do
          task["conversation_hidden"] == true or task["conversation_child"] == true ->
            []

          task["conversation"] == true and is_binary(task["origin_session_id"]) ->
            [row("conversation", task, root_state(task, children[id] || []), %{session_id: task["origin_session_id"]})]

          task["parent_task_id"] || task["workflow_root"] || task["team_run_id"] || task["team_proposal_id"] ->
            []

          MapSet.member?(internal, id) or MapSet.member?(internal, task["colony_id"]) ->
            []

          get_in(colonies, [task["colony_id"], "conversation_owner_session"]) ->
            []

          true ->
            [row("colony", task, task_state(task), %{colony_id: task["colony_id"]})]
        end
      end) ++
        Enum.map(runs, fn run ->
          current = tasks[run["current_task_id"]] || %{}

          state =
            case run["status"] do
              "closed" -> "delivered"
              "completed" -> "confirm"
              "halted" -> "blocked"
              _ -> task_state(current)
            end

          row("team", run, state, %{colony_id: run["colony_id"]})
        end) ++
        Enum.flat_map(proposals, fn proposal ->
          case proposal["status"] do
            "approved" -> []
            status -> [row("proposal", proposal, proposal_state(status), %{colony_id: proposal["colony_id"]})]
          end
        end)

    hive =
      Enum.map(hive_tasks, fn task ->
        task = Map.put(task, "id", task["task_id"])

        state =
          case task["status"] do
            "succeeded" -> "delivered"
            "submitted" -> "review"
            status when status in ~w(pending assigned accepted) -> "queued"
            _ -> task_state(task)
          end

        row("hive", task, state, %{session_id: task["session_id"], group_id: task["group_id"], task_id: task["task_id"]})
      end)

    remote_rows =
      Enum.map(remote_tasks, fn task ->
        state =
          case task["status"] do
            "done" -> "finished"
            "waiting_input" -> "answer"
            "unknown" -> "blocked"
            status when status in ~w(queued accepted) -> "queued"
            _ -> task_state(task)
          end

        row("remote_task", task, state, %{group_id: task["group_id"], task_id: task["id"]})
      end)

    queues = (rows ++ hive ++ remote_rows) |> Enum.sort_by(&{&1.updated_at, &1.id}, :desc) |> Enum.group_by(& &1.queue)

    %{
      queues: Map.new(~w(attention active history), &{&1, Enum.take(Map.get(queues, &1, []), 100)}),
      counts: Map.new(queues, fn {key, items} -> {key, length(items)} end),
      groups: Enum.map(groups, &Map.take(&1, ~w(group_id title status coordinator_session_id task_count member_count))),
      remote: Enum.map(remote, &Map.take(&1, ~w(id name device_count))),
      colonies:
        colonies
        |> Map.values()
        |> Enum.reject(&(&1["conversation_owner_session"] || MapSet.member?(internal, &1["id"])))
        |> Enum.map(&Map.take(&1, ~w(id name status)))
    }
  end

  defp root_state(task, children) do
    state = task_state(task)

    if state in ~w(working queued) do
      Enum.find_value(~w(answer approval blocked), state, fn attention ->
        if Enum.any?(children, &(task_state(&1) == attention)), do: attention
      end)
    else
      state
    end
  end

  defp task_state(%{"status" => "done"}), do: "delivered"
  defp task_state(%{"status" => "cancelled"}), do: "stopped"
  defp task_state(%{"approval_required" => true}), do: "approval"
  defp task_state(%{"status" => "pending_review"}), do: "review"
  defp task_state(%{"question" => question}) when is_map(question), do: "answer"
  defp task_state(%{"waiting_for" => "user"}), do: "answer"
  defp task_state(%{"waiting_for" => reason}) when reason in ~w(children dependencies capacity), do: "working"
  defp task_state(%{"status" => status}) when status in ~w(blocked failed), do: "blocked"
  defp task_state(%{"status" => status}) when status in ~w(pending claimed), do: "queued"
  defp task_state(_), do: "working"

  defp proposal_state("draft_ready"), do: "approval"
  defp proposal_state("rejected"), do: "stopped"
  defp proposal_state(status) when status in ~w(failed draft_invalid), do: "blocked"
  defp proposal_state(_), do: "working"

  defp timestamp(value) when is_integer(value), do: value

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_unix(at, :millisecond)
      _ -> 0
    end
  end

  defp timestamp(_), do: 0

  defp row(kind, record, state, target) do
    queue =
      cond do
        state in ~w(review confirm answer approval blocked) -> "attention"
        state in ~w(delivered finished stopped) -> "history"
        true -> "active"
      end

    %{
      id: record["id"],
      kind: kind,
      state: state,
      queue: queue,
      target: target,
      title: record["title"] || record["name"] || record["goal"] || "未命名工作",
      updated_at: timestamp(record["updated_at"] || record["created_at"])
    }
  end
end
