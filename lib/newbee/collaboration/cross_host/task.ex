defmodule Newbee.Collaboration.CrossHost.Task do
  @moduledoc "任务票据：绑定人+设备+项目+预算，幂等、防重、交接不转移生产凭据。"
  @states ["queued", "running", "waiting_input", "failed", "done", "unknown"]
  @spec new(map()) :: {:ok, map()} | {:error, term(), term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, gid} <- need(attrs, "group_id"),
         {:ok, pid} <- need(attrs, "project_id"),
         {:ok, key} <- need(attrs, "idempotency_key"),
         :ok <- check_budget(Map.get(attrs, "budget", %{})),
         :ok <- check_requires(Map.get(attrs, "requires", %{})) do
      id = "t_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      task = %{
        "id" => id,
        "task_id" => Map.get(attrs, "task_id") || id,
        "source" => Map.get(attrs, "source", "cross_host"),
        "group_id" => gid,
        "project_id" => pid,
        "creator" => Map.get(attrs, "creator", ""),
        "assignee" => Map.get(attrs, "assignee", "auto"),
        "assigned_session_id" => Map.get(attrs, "assigned_session_id"),
        "assigned_device_id" => Map.get(attrs, "assigned_device_id"),
        "title" =>
          case Map.get(attrs, "title", "") do
            "" -> "未命名任务"
            nil -> "未命名任务"
            v -> v
          end,
        "description" => Map.get(attrs, "description", "") || "",
        "budget" => Map.get(attrs, "budget", %{}),
        "requires" => Map.get(attrs, "requires", %{}),
        "idempotency_key" => key,
        "status" => "queued",
        "source_digest" => Map.get(attrs, "source_digest", ""),
        "fence_version" => 0,
        "attempts" => 0,
        "created_at" => System.system_time(:millisecond)
      }

      {:ok, task}
    end
  end

  defp need(m, k) do
    case Map.get(m, k, "") do
      "" -> {:error, "missing_" <> k, "缺少" <> k}
      nil -> {:error, "missing_" <> k, "缺少" <> k}
      v -> {:ok, v}
    end
  end

  defp check_budget(b) when is_map(b), do: :ok
  defp check_budget(_), do: {:error, "bad_budget", "预算无效"}
  defp check_requires(value) when is_map(value), do: :ok
  defp check_requires(_), do: {:error, "bad_requires", "requires 必须是对象"}

  @spec transition(map(), binary()) :: {:ok, map()} | {:error, term(), term()}
  def transition(task, event) when is_map(task) and is_binary(event) do
    cur = Map.get(task, "status", "queued")

    nxt =
      case {cur, event} do
        {"queued", "start"} -> "running"
        {"running", "need_input"} -> "waiting_input"
        {"running", "fail"} -> "failed"
        {"waiting_input", "ok"} -> "done"
        {"running", "ok"} -> "done"
        {"running", "lost"} -> "unknown"
        {"waiting_input", "cancel"} -> "failed"
        {"queued", "cancel"} -> "failed"
        _ -> nil
      end

    if nxt == nil do
      {:error, "bad_transition", "非法状态迁移"}
    else
      atts = if event == "start", do: Map.get(task, "attempts", 0) + 1, else: Map.get(task, "attempts", 0)
      {:ok, task |> Map.put("status", nxt) |> Map.put("attempts", atts)}
    end
  end

  @spec fence_ok?(map(), integer(), integer()) :: term()
  def fence_ok?(_task, base, current) when is_integer(base) and is_integer(current) do
    base >= current
  end

  def fence_ok?(_, _, _), do: false
  @spec handover(map(), binary(), map()) :: {:ok, map()} | {:error, term(), term()}
  def handover(task, to_member, ctx) when is_map(task) and is_binary(to_member) and is_map(ctx) do
    if to_member == "" do
      {:error, "bad_assignee", "交接对象不能为空"}
    else
      if Map.has_key?(ctx, "prod_credential") or Map.has_key?(ctx, "admin_token") do
        {:error, "forbidden_handover", "交接不得携带生产凭据或管理员身份"}
      else
        nt =
          task
          |> Map.put("assignee", to_member)
          |> Map.put("handover", %{"ctx" => ctx, "at" => System.system_time(:millisecond)})
          |> Map.put("status", "queued")

        {:ok, nt}
      end
    end
  end

  @spec status_valid?(binary()) :: term()
  def status_valid?(s) when is_binary(s), do: s in @states
  def status_valid?(_), do: false
end
