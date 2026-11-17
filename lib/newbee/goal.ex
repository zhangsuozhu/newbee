defmodule Newbee.Goal do
  @moduledoc ~S"""
  自主目标驱动（同步版 + 富状态），借鉴 Codex thread_goals。

  持久化目录：`NEWBEE_GOALS_DIR`（默认 `GlobalStore` 根下的 `goals/`，测试环境即临时目录），每个会话一个
  `<session_id>.json` 快照。读侧区分“历史快照”和“当前目标”：

    * `load/1` 原样返回落盘快照（诊断/测试用）；
    * `load_active/1` 只在目标仍然成立时返回它：status=active、updated_at 未过期、
      会话仍存在。内核崩溃/被杀时没人会把 active 改成终态，不过滤就会把上次
      遗留的 active 残影当成“现在在跑的目标”；
    * `prune_stale/1` 是显式清理入口。

  done 出口用 `finish/2`：先写终态快照（含最终 tokens_used）并读回校验，再删除
  文件，确保内存里看到的完成态与真正落过盘的内容一致。
  """

  @max_rounds 50

  # 内核崩溃/被杀时没人能把 active 改成终态，磁盘上的 active 只说明“上次跑到哪”。
  # 超过 24h 未更新即视为残影（可用 NEWBEE_GOAL_STALE_MS 覆盖，测试用）。
  @stale_after_ms 24 * 60 * 60 * 1000

  defmodule State do
    @enforce_keys [:id, :text]
    defstruct id: nil,
              text: nil,
              objective: nil,
              status: :active,
              token_budget: nil,
              tokens_used: 0,
              time_used_ms: 0,
              rounds: 0,
              max_rounds: 50,
              idle: 0,
              blocked_streak: 0,
              last_block_reason: nil,
              created_at: nil,
              updated_at: nil,
              session_id: nil

    @statuses [:active, :paused, :budget_limited, :blocked, :complete]
    def statuses, do: @statuses
    def valid_status?(s) when s in @statuses, do: true
    def valid_status?(_), do: false
  end

  def new_state(text, opts \\ []) do
    now = System.system_time(:millisecond)
    tok_budget = Keyword.get(opts, :token_budget) || Keyword.get(opts, :budget)

    %State{
      id: "goal_" <> random_id(),
      text: String.trim(text),
      objective: String.trim(text),
      status: :active,
      token_budget: normalize_budget(tok_budget),
      tokens_used: 0,
      time_used_ms: 0,
      rounds: 0,
      max_rounds: Keyword.get(opts, :max_rounds, @max_rounds),
      idle: 0,
      blocked_streak: 0,
      created_at: now,
      updated_at: now,
      session_id: Keyword.get(opts, :session_id)
    }
  end

  def run(kernel, text, opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, @max_rounds)
    do_run(kernel, text, max_rounds, 1)
  end

  def continue(kernel, text) do
    Newbee.Agent.Loop.submit(kernel, text)
  end

  defp do_run(kernel, text, max_rounds, round, error_retryed? \\ false)

  defp do_run(_kernel, _text, max_rounds, round, _error_retryed?) when round > max_rounds do
    {:goal_limit, round - 1}
  end

  defp do_run(kernel, text, max_rounds, round, error_retryed?) do
    input =
      if round == 1,
        do: text,
        else: "(Autonomous round #{round}: goal unmet, keep working. Call done when achieved.)"

    case Newbee.Agent.Loop.submit(kernel, input) do
      {:done, summary} ->
        {:done, summary}

      {:ask, q} ->
        {:ask, q}

      {:text, _} ->
        do_run(kernel, text, max_rounds, round + 1, false)

      {:interrupted, _} ->
        {:interrupted, :user}

      {:error, e} ->
        if error_retryed? do
          {:error, e}
        else
          Newbee.DebugLog.log(:goal, "LLM error on round #{round}, retrying: #{inspect(e)}")
          do_run(kernel, text, max_rounds, round + 1, true)
        end
    end
  end

  @doc "写运行态快照。落盘失败不影响主循环（返回 :ok）。"
  def persist(state, _ \\ nil)

  def persist(%State{} = s, _) do
    _ = write_snapshot(s)
    :ok
  end

  @doc """
  done 出口：把终态快照（含最终 tokens_used）落盘并读回校验，然后删除目标文件。

  返回 `{:ok, persisted}`，`persisted` 是校验通过、确实写进过磁盘的 JSON map；
  写盘/校验失败时返回 `{:error, reason}`（文件仍会被清理，避免残留 active）。
  """
  def finish(state, opts \\ [])

  def finish(%State{} = state, opts) do
    final = finalize(state, opts)
    result = write_snapshot(final)
    _ = clear_persist(final.session_id)

    case result do
      :ok -> {:ok, persist_map(final)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "原样读取落盘快照（不做有效性过滤；当前目标请用 load_active/2）。"
  def load(session_id) when is_binary(session_id) do
    case File.read(goal_path(session_id)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
          {:ok, _other} -> {:error, :invalid_snapshot}
          {:error, reason} -> {:error, {:invalid, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  读“当前目标”：只有仍在跑的目标才返回。

  过滤条件：status 为 active、updated_at 不早于 `stale_after_ms/0`、会话仍存在
  （`check_session: false` 可跳过）。否则返回
  `{:error, :missing | :stale | :not_active | :session_missing | {:invalid, term}}`。
  """
  def load_active(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, snapshot} <- load(session_id) do
      now = Keyword.get(opts, :now, System.system_time(:millisecond))

      cond do
        not active_snapshot?(snapshot) ->
          {:error, :not_active}

        stale?(snapshot, now) ->
          {:error, :stale}

        Keyword.get(opts, :check_session, true) and not Newbee.Session.exists?(session_id) ->
          {:error, :session_missing}

        true ->
          {:ok, snapshot}
      end
    end
  end

  @doc """
  启动/接管会话时的轻量清理：仅当该会话的快照已过期或已不是 active 时删除，
  避免把崩溃/被杀留下的 active 残影当成当前目标。返回 :ok | :kept。
  """
  def discard_stale(session_id, opts \\ []) when is_binary(session_id) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))

    case load(session_id) do
      {:ok, snapshot} ->
        if active_snapshot?(snapshot) and not stale?(snapshot, now) do
          :kept
        else
          clear_persist(session_id)
        end

      {:error, _} ->
        clear_persist(session_id)
    end
  end

  @doc """
  显式清理残留快照：删除过期、JSON 不可读、或（`check_session: true` 时）会话
  已不存在的目标文件。返回 `{:ok, removed_ids}`。仍在轮上的新目标不会被删。
  """
  def prune_stale(opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    check_session = Keyword.get(opts, :check_session, false)

    removed =
      goals_dir()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.filter(&prune?(&1, now, check_session))
      |> Enum.map(fn path ->
        id = Path.basename(path, ".json")
        _ = File.rm(path)
        id
      end)

    {:ok, removed}
  end

  @doc "active 目标过期阈值（毫秒）；`NEWBEE_GOAL_STALE_MS` 可覆盖（正整数）。"
  def stale_after_ms do
    case System.get_env("NEWBEE_GOAL_STALE_MS") do
      nil ->
        @stale_after_ms

      raw ->
        case Integer.parse(String.trim(raw)) do
          {n, ""} when n > 0 -> n
          _ -> @stale_after_ms
        end
    end
  end

  @doc "快照是否过期（updated_at 缺失或不可解析按过期处理）。"
  def stale?(snapshot, now \\ System.system_time(:millisecond))

  def stale?(snapshot, now) when is_integer(now) do
    case snapshot_updated_at(snapshot) do
      nil -> true
      at -> now - at > stale_after_ms()
    end
  end

  def stale?(_snapshot, _now), do: true

  def clear_persist(session_id) when is_binary(session_id) do
    File.rm(goal_path(session_id))
    :ok
  end

  def clear_persist(_), do: :ok

  @doc "目标快照目录：`NEWBEE_GOALS_DIR`，否则 `GlobalStore.root()/goals`（测试环境不写用户 home）。"
  def goals_dir do
    System.get_env("NEWBEE_GOALS_DIR") || Path.join(Newbee.GlobalStore.root(), "goals")
  end

  @doc false
  def goal_path(session_id) when is_binary(session_id), do: Path.join(goals_dir(), session_id <> ".json")

  # ── 内部 ──

  defp finalize(%State{} = state, opts) do
    %State{
      state
      | status: Keyword.get(opts, :status, :complete),
        updated_at: System.system_time(:millisecond)
    }
  end

  defp write_snapshot(%State{session_id: nil}), do: :ok

  defp write_snapshot(%State{} = s) do
    path = goal_path(s.session_id)
    json = persist_map(s)

    with :ok <- write_json(path, json),
         {:ok, body} <- File.read(path),
         {:ok, on_disk} <- Jason.decode(body) do
      if on_disk == json, do: :ok, else: {:error, :persist_mismatch}
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  rescue
    e -> {:error, {:write_failed, Exception.message(e)}}
  end

  defp write_json(path, json) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(json))
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp persist_map(%State{} = s) do
    %{
      "id" => s.id,
      "text" => s.text,
      "objective" => s.objective || s.text,
      "status" => to_string(s.status),
      "token_budget" => s.token_budget,
      "tokens_used" => s.tokens_used || 0,
      "time_used_ms" => s.time_used_ms || 0,
      "rounds" => s.rounds || 0,
      "max_rounds" => s.max_rounds || @max_rounds,
      "idle" => s.idle || 0,
      "blocked_streak" => s.blocked_streak || 0,
      "created_at" => s.created_at,
      "updated_at" => s.updated_at
    }
  end

  defp active_snapshot?(snapshot) do
    is_map(snapshot) and Map.get(snapshot, "status") in ["active", :active]
  end

  defp snapshot_updated_at(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, "updated_at") || Map.get(snapshot, :updated_at) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      s when is_binary(s) -> parse_iso_ms(s)
      _ -> nil
    end
  end

  defp snapshot_updated_at(_), do: nil

  defp parse_iso_ms(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp prune?(path, now, check_session) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, snapshot} when is_map(snapshot) ->
            stale?(snapshot, now) or (check_session and missing_session?(path))

          _ ->
            true
        end

      _ ->
        false
    end
  end

  defp missing_session?(path), do: not Newbee.Session.exists?(Path.basename(path, ".json"))

  defp normalize_budget(nil), do: nil

  defp normalize_budget(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp normalize_budget(n) when is_integer(n) and n > 0, do: n
  defp normalize_budget(_), do: nil

  defp random_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
