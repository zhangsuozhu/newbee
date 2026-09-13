defmodule Newbee.Colony.Task do
  @moduledoc """
  任务：蜂群中唯一产生临时协调关系的地方（附录 L/N）。

  - 任务以“刺激（stimulus）”形式广播；Bee 按响应阈值与能力自领取（B 节）。
  - `claim/3` 用 revision 做乐观锁（CAS），同一时刻只有一个 Bee 能领到。
  - 心跳超时后任务自动回到可领取池（Bee 消失任务不烂尾）。
  - 父子关系只表达任务拆分（`parent_task_id` + `coordinator_bee_id`），
    不代表 Bee 的永久上下级。
  """

  @statuses ~w(pending claimed running blocked pending_review done failed cancelled)
  @terminal ~w(done failed cancelled)
  @active ~w(claimed running blocked)
  @default_budget %{"max_children" => 4, "max_depth" => 3}
  @claim_timeout_ms 10 * 60 * 1000

  def statuses, do: @statuses
  def terminal?(task), do: Map.get(task, "status") in @terminal
  def active?(task), do: Map.get(task, "status") in @active

  @doc """
  新建任务。attrs: colony_id, title, description?, requires?, assigned_bee_id?,
  coordinator_bee_id?, parent_task_id?, priority?, budget?, source?
  """
  def new(attrs) when is_map(attrs) do
    now = Map.get(attrs, "created_at") || now_ms()
    parent = blank_to_nil(Map.get(attrs, "parent_task_id"))

    %{
      "id" => Map.get(attrs, "id") || Newbee.Colony.Id.new(:task, scope_for(attrs)),
      "colony_id" => Map.get(attrs, "colony_id"),
      "parent_task_id" => parent,
      "title" => blank_to_nil(Map.get(attrs, "title")) || "未命名任务",
      "description" => blank_to_nil(Map.get(attrs, "description")) || "",
      "kind" => blank_to_nil(Map.get(attrs, "kind")) || "default",
      "requires" => normalize_list(Map.get(attrs, "requires")),
      "status" => Map.get(attrs, "status") || "pending",
      "priority" => clamp01(Map.get(attrs, "priority") || 0.2),
      "assigned_bee_id" => blank_to_nil(Map.get(attrs, "assigned_bee_id")),
      "coordinator_bee_id" => blank_to_nil(Map.get(attrs, "coordinator_bee_id")),
      "claimed_at" => nil,
      "heartbeat_at" => nil,
      "completed_at" => nil,
      "result" => nil,
      "acceptance" => Map.get(attrs, "acceptance") || [],
      "constraints" => Map.get(attrs, "constraints") || [],
      "facts" => Map.get(attrs, "facts") || [],
      "decisions" => [],
      "context_revision" => 0,
      "next_step" => nil,
      "evidence" => [],
      "limitations" => [],
      "session_id" => Map.get(attrs, "session_id"),
      "source" => Map.get(attrs, "source") || "user",
      "budget" => Map.merge(@default_budget, Map.get(attrs, "budget") || %{}),
      "revision" => 0,
      "created_at" => now,
      "updated_at" => now
    }
  end

  @doc """
  刺激强度（0..1）：优先级基数 + 等待时间增长（防饿）+ 阻塞下游加成。
  论文形态见 Bonabeau 等 1998（S 型响应），工程实现改为可排序的确定性数值。
  """
  def stimulate(task, now \\ nil) do
    now = now || now_ms()
    base = Map.get(task, "priority", 0.2)
    created = Map.get(task, "created_at") || now
    waited_min = max(0, now - created) / 60_000
    waiting = min(0.5, waited_min * 0.02)
    blocked_bonus = if Map.get(task, "status") == "blocked", do: 0.1, else: 0.0
    clamp01(base + waiting + blocked_bonus)
  end

  @doc """
  领取评分（越高越优先领取）。能力不匹配返回 :infinity（硬门槛，不会抢到干不了的活）。
  load 为该 Bee 当前在办任务数；affinity 取 Bee 的 affinity map（默认 0.5）。
  """
  def score(bee, task, now \\ nil, load \\ 0) do
    if Newbee.Colony.Bee.can?(bee, task) do
      now = now || now_ms()
      stimulus = stimulate(task, now)
      affinity = affinity_for(bee, task)
      threshold = Newbee.Colony.Bee.threshold(bee, task)
      w = %{stimulus: 1.0, affinity: 0.6, load: 0.4, threshold: 0.8}
      w.stimulus * stimulus + w.affinity * affinity - w.load * load - w.threshold * threshold
    else
      :infinity
    end
  end

  @doc "排序后的可领取任务（score 从高到低）。"
  def claimable(bee, tasks, now \\ nil) do
    tasks
    |> Enum.filter(fn t -> Map.get(t, "status") == "pending" end)
    |> Enum.map(fn t -> {score(bee, t, now), t} end)
    |> Enum.reject(fn {s, _} -> s == :infinity end)
    |> Enum.sort_by(fn {s, t} -> {-s, Map.get(t, "id")} end)
    |> Enum.map(fn {_, t} -> t end)
  end

  @doc """
  领取任务（CAS）。成功返回 {:ok, task}；失败 :conflict（已被领取且未超时）、
  :incapable（能力不足）、:not_claimable（终态）、:not_found。
  """
  def claim(task, bee, now \\ nil) do
    now = now || now_ms()

    cond do
      terminal?(task) ->
        {:error, :not_claimable}

      not Newbee.Colony.Bee.can?(bee, task) ->
        {:error, :incapable}

      Map.get(task, "status") == "pending" ->
        {:ok, do_claim(task, bee, now)}

      Map.get(task, "assigned_bee_id") == Map.get(bee, "id") and
          Map.get(task, "status") in @active ->
        {:ok, task}

      true ->
        {:error, :conflict}
    end
  end

  defp do_claim(task, bee, now) do
    task
    |> Map.put("status", "claimed")
    |> Map.put("assigned_bee_id", Map.get(bee, "id"))
    |> Map.put("claimed_at", now)
    |> Map.put("heartbeat_at", now)
    |> Map.put("revision", Map.get(task, "revision", 0) + 1)
    |> Map.put("updated_at", now)
  end

  def stale?(task, now) do
    last = Map.get(task, "heartbeat_at") || Map.get(task, "claimed_at") || 0
    now - last > @claim_timeout_ms
  end

  @doc """
  状态迁移。event: start/block/unblock/complete/fail/cancel/release；
  opts: bee_id（执行者）、result、note。
  """
  def transition(task, event, opts \\ []) do
    now = now_ms()
    status = Map.get(task, "status")

    case event do
      "start"
      when status in ["claimed", "blocked"] or
             (status == "pending" and :erlang.map_get("owner_kind", task) == "human") ->
        {:ok, put_status(task, "running", now, opts)}

      "block" when status in ["claimed", "running"] ->
        {:ok, put_status(task, "blocked", now, opts)}

      "unblock" when status == "blocked" ->
        {:ok, put_status(task, "running", now, opts)}

      "complete" when status in ["claimed", "running", "blocked"] ->
        task = put_status(task, "done", now, opts)
        {:ok, Map.put(task, "completed_at", now)}

      "fail" when status in ["claimed", "running", "blocked", "pending"] ->
        task = put_status(task, "failed", now, opts)
        {:ok, Map.put(task, "completed_at", now)}

      "cancel" when status not in @terminal ->
        task = put_status(task, "cancelled", now, opts)
        {:ok, Map.put(task, "completed_at", now)}

      "release" when status not in @terminal ->
        {:ok, release(task, now)}

      "reclaim" when status not in @terminal ->
        {:ok, release(task, now)}

      _ ->
        {:error, :invalid_transition}
    end
  end

  defp put_status(task, status, now, opts) do
    task
    |> Map.put("status", status)
    |> Map.put("revision", Map.get(task, "revision", 0) + 1)
    |> Map.put("updated_at", now)
    |> Map.put("heartbeat_at", now)
    |> maybe_put("result", Keyword.get(opts, :result))
    |> maybe_assign(Keyword.get(opts, :bee_id))
  end

  defp maybe_assign(task, nil), do: task
  defp maybe_assign(task, bee_id), do: Map.put(task, "assigned_bee_id", bee_id)

  defp release(task, now) do
    task
    |> Map.put("status", "pending")
    |> Map.put("assigned_bee_id", nil)
    |> Map.put("claimed_at", nil)
    |> Map.put("heartbeat_at", nil)
    |> Map.put("revision", Map.get(task, "revision", 0) + 1)
    |> Map.put("updated_at", now)
  end

  @doc "心跳：更新活跃时间，防止任务被判定超时。"
  def heartbeat(task, now \\ nil) do
    now = now || now_ms()
    task |> Map.put("heartbeat_at", now) |> Map.put("updated_at", now)
  end

  @doc """
  任务拆分为子任务。校验并行预算与深度预算（默认 max_children=4、max_depth=3）。
  children: [%{"title" => ..., "requires" => ..., "description" => ...}]
  返回 {:ok, [child_task]} | {:error, :budget_exceeded | :depth_exceeded | reason}
  """
  def decompose(parent, children, all_tasks, opts \\ []) do
    budget = Map.get(parent, "budget", @default_budget)
    max_children = Map.get(budget, "max_children", 4)
    max_depth = Map.get(budget, "max_depth", 3)

    existing =
      Enum.count(all_tasks, fn t -> Map.get(t, "parent_task_id") == Map.get(parent, "id") end)

    depth = depth(parent, all_tasks)
    coordinator = Keyword.get(opts, :coordinator_bee_id) || Map.get(parent, "assigned_bee_id")

    cond do
      terminal?(parent) ->
        {:error, :not_claimable}

      existing + length(children) > max_children ->
        {:error, :budget_exceeded}

      depth + 1 > max_depth ->
        {:error, :depth_exceeded}

      children == [] ->
        {:error, :no_children}

      true ->
        now = now_ms()

        built =
          Enum.map(children, fn child ->
            child
            |> Map.new(fn {k, v} -> {to_string(k), v} end)
            |> Map.put("colony_id", Map.get(parent, "colony_id"))
            |> Map.put("parent_task_id", Map.get(parent, "id"))
            |> Map.put("coordinator_bee_id", coordinator)
            |> Map.put("budget", budget)
            |> Map.put("source", "decompose")
            |> Map.put("created_at", now)
            |> new()
          end)

        {:ok, built}
    end
  end

  @doc "任务在树中的深度（根为 1）。"
  def depth(task, all_tasks) do
    by_id = Map.new(all_tasks, fn t -> {Map.get(t, "id"), t} end)
    walk_depth(task, by_id, 1)
  end

  defp walk_depth(task, by_id, acc) do
    case Map.get(task, "parent_task_id") do
      nil ->
        acc

      pid ->
        case Map.get(by_id, pid) do
          nil -> acc
          parent -> walk_depth(parent, by_id, acc + 1)
        end
    end
  end

  @doc "把任务列表组装成树：根任务（parent 不在集合内）列表，children 递归。"
  def tree(all_tasks, opts \\ []) do
    by_parent =
      Enum.group_by(all_tasks, fn t -> Map.get(t, "parent_task_id") end)

    roots =
      all_tasks
      |> Enum.filter(fn t -> is_nil(Map.get(t, "parent_task_id")) end)
      |> Enum.sort_by(fn t -> {-stimulate(t), Map.get(t, "created_at", 0)} end)

    now = now_ms()
    Enum.map(roots, fn root -> node(root, by_parent, now, Keyword.get(opts, :depth_limit, 6)) end)
  end

  defp node(task, by_parent, now, budget) do
    children =
      by_parent
      |> Map.get(Map.get(task, "id"), [])
      |> Enum.sort_by(fn t -> Map.get(t, "created_at", 0) end)

    children =
      if budget > 1 do
        Enum.map(children, &node(&1, by_parent, now, budget - 1))
      else
        []
      end

    public(task, now) |> Map.put("children", children)
  end

  @doc "对外视图：附上计算出来的 stimulus。"
  def public(task, now \\ nil) do
    task
    |> Map.put("stimulus", Float.round(stimulate(task, now), 3))
    |> Map.put("is_terminal", terminal?(task))
  end

  defp affinity_for(bee, task) do
    affinity = Map.get(bee, "affinity", %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    kind = Map.get(task, "kind") || "default"
    Map.get(affinity, kind, 0.5)
  end

  defp normalize_list(nil), do: []

  defp normalize_list(list) when is_list(list),
    do:
      list
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  defp normalize_list(single) when is_binary(single), do: normalize_list([single])
  defp normalize_list(_), do: []

  defp clamp01(v) when is_number(v), do: v |> max(0.0) |> min(1.0)
  defp clamp01(_), do: 0.0

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v

  defp scope_for(%{"scope" => "xhost"}), do: :xhost
  defp scope_for(_), do: :local

  defp now_ms, do: System.system_time(:millisecond)
end
