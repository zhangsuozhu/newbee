defmodule Newbee.Colony.Decomposition do
  @moduledoc "Bounded task plans, isolated assignments and recovery-safe dependency scheduling."
  alias Newbee.Colony.{Bee, Control, Id, Store, Task, Work}
  @max_children 4
  @max_concurrency 3
  @terminal ~w(done failed cancelled)
  @complete ~w(pending_review done)

  def managed?(%{"workflow" => %{"strategy" => "decompose"}} = task),
    do: is_nil(task["workflow_root"]) and task["conversation_child"] != true

  def managed?(_), do: false

  def context(_task) do
    "只读调查项目入口、现有约束和测试，再规划可以交付的分工。禁止修改文件或外部写入；禁止调用Hive、子代理或会话派生。用户已授权完成总任务，不要求用户配置成员或确认内部阶段。完成时done的summary只返回JSON：" <>
      ~s({"summary":"整体方案与集成方法","tasks":[{"id":"implementation","title":"实现目标","scope":"交付目标、修改边界、验证方法","depends_on":[],"acceptance":["可核对的验收项"]}]}) <>
      "。1至4项，最多3项同时执行；简单任务可为1项，不为并发硬拆。有依赖的项目按顺序执行；依赖必须引用本计划id且无环。每项分工均在独立目录执行，最终由负责人集成真实文件并组合验证。"
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
        with {:ok, plan_summary, plan} <- parse_plan(summary),
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
             Enum.all?(children, &submitted?(acc, &1)) do
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

    rows =
      Enum.map(children, fn child ->
        result = honey[child["result"]] || %{}

        %{
          "id" => child["id"],
          "title" => child["title"],
          "scope" => child["description"],
          "status" => child["status"],
          "waiting_for" => child["waiting_for"],
          "depends_on" => child["depends_on"] || [],
          "activity" => child["activity"],
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
      "concurrency" => @max_concurrency,
      "total" => length(get_in(root, ["workflow", "children"]) || []),
      "completed" => Enum.count(children, &submitted?(snapshot, &1)),
      "children" => rows
    }
  end

  defp parse_plan(text) when is_binary(text) and byte_size(text) <= 100_000 do
    text = String.trim(text)

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
         true <- is_list(items) and length(items) in 1..@max_children,
         {:ok, plan} <- normalize_plan(items),
         true <- valid_dag?(plan) do
      {:ok, String.trim(summary), plan}
    else
      _ -> {:error, "分工计划无效：请返回1至4项明确目标、范围和验收要求，依赖必须存在且不能成环。"}
    end
  end

  defp parse_plan(_), do: {:error, "分工计划必须是有效的JSON文本。"}

  defp normalize_plan(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      if is_map(item) and nonempty?(item["id"], 64) and Regex.match?(~r/\A[a-zA-Z0-9._-]+\z/, item["id"]) and
           nonempty?(item["title"], 200) and nonempty?(item["scope"], 10_000) and
           is_list(item["depends_on"] || []) and length(item["depends_on"] || []) <= @max_children and
           Enum.all?(item["depends_on"] || [], &nonempty?(&1, 64)) and
           is_list(item["acceptance"]) and length(item["acceptance"]) in 1..20 and
           Enum.all?(item["acceptance"], &nonempty?(&1, 2000)) do
        normalized =
          Map.take(item, ~w(id title scope acceptance)) |> Map.put("depends_on", Enum.uniq(item["depends_on"] || []))

        {:cont, {:ok, acc ++ [normalized]}}
      else
        {:halt, :invalid}
      end
    end)
  end

  defp valid_dag?(plan) do
    deps = Map.new(plan, &{&1["id"], &1["depends_on"]})

    length(plan) == map_size(deps) and
      Enum.all?(plan, fn item ->
        Enum.all?(item["depends_on"], &Map.has_key?(deps, &1)) and acyclic?(item["id"], deps, MapSet.new())
      end)
  end

  defp acyclic?(id, deps, seen) do
    not MapSet.member?(seen, id) and Enum.all?(deps[id] || [], &acyclic?(&1, deps, MapSet.put(seen, id)))
  end

  defp build_plan(data, root, summary, plan) do
    ids = Map.new(plan, &{&1["id"], Id.new(:task, :local)})

    {data, children} =
      Enum.reduce(Enum.with_index(plan, 1), {data, []}, fn {item, index}, {acc, children} ->
        bee =
          Bee.new(%{"colony_id" => root["colony_id"], "kind" => "ai", "role" => "worker", "display" => "执行者 #{index}"})

        deps = Enum.map(item["depends_on"], &ids[&1])

        child =
          Task.new(%{
            "id" => ids[item["id"]],
            "colony_id" => root["colony_id"],
            "title" => item["title"],
            "description" => item["scope"],
            "parent_task_id" => root["id"],
            "assigned_bee_id" => bee["id"],
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

        {acc |> put_in(["bees", bee["id"]], bee) |> put_in(["tasks", child["id"]], child), children ++ [child["id"]]}
      end)

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

  defp dispatch_ready(data, root) do
    Enum.reduce(get_in(root, ["workflow", "children"]) || [], data, fn id, acc ->
      child = acc["tasks"][id]
      active = Enum.count(child_tasks(acc, root), &occupied?(acc, &1))

      ready =
        is_map(child) and child["status"] == "blocked" and child["waiting_for"] in ["dependencies", "capacity"] and
          active < @max_concurrency and not paused?(acc, root) and not paused?(acc, child) and
          Enum.all?(child["depends_on"] || [], fn dep -> submitted?(acc, acc["tasks"][dep]) end)

      if ready do
        deps = Enum.map(child["depends_on"] || [], &acc["tasks"][&1])

        instruction =
          "只完成这项已分配分工，不自行再委派。只修改自己的隔离目录；上游目录仅可读取。需要上游文件时先把必要变更集成到自己目录，再实施和验证。交付真实文件位置、修改说明、验证与限制。\n" <>
            Jason.encode!(%{
              "scope" => child["description"],
              "acceptance" => child["acceptance"],
              "dependencies" => material(acc, deps)
            })

        child =
          child
          |> Map.merge(%{
            "status" => "claimed",
            "waiting_for" => nil,
            "next_step" => "按分工实施并验证。",
            "context_revision" => child["context_revision"] + 1
          })
          |> bump()

        delivery = Work.new_delivery(child, %{"instruction" => instruction})
        acc |> put_in(["tasks", id], child) |> put_in(["deliveries", delivery["id"]], delivery)
      else
        acc
      end
    end)
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

    delivery =
      Work.new_delivery(root, %{
        "instruction" =>
          "所有分工已交付。读取每个独立工作目录的真实文件，将需要的修改合入你的隔离目录，解决接口与文件冲突，并运行组合验证。不得只拼接总结声称完成；不要写回源项目、提交或推送。结合pending_inputs中的最新要求，报告成果位置、验证方法与未验证范围。\n" <>
            Jason.encode!(material(data, children))
      })

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

  defp occupied?(data, child) do
    not submitted?(data, child) and
      (child["status"] in ["claimed", "running"] or
         Enum.any?(
           Map.values(data["deliveries"] || %{}),
           &(&1["task_id"] == child["id"] and &1["status"] in ["pending", "dispatching", "accepted"])
         ))
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
