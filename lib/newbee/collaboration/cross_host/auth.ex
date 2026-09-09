defmodule Newbee.Collaboration.CrossHost.Auth do
  @moduledoc "加群鉴权：服务器身份钉选、口令限流、设备独立凭据、改口令与踢分离。"

  @rate_window_ms 60_000
  @rate_max 10
  @lock_threshold 5
  @lock_base_ms 30_000
  @lock_max_ms 900_000
  @table :xh_auth_attempts

  @doc "校验服务器身份：必须钉选指纹一致，否则视为假服务器拒绝。"
  @spec verify_server(String.t(), String.t()) :: :ok | {:error, String.t(), String.t()}
  def verify_server(expected, presented) when is_binary(expected) and is_binary(presented) do
    cond do
      expected == "" or presented == "" -> {:error, "bad_server_identity", "缺少服务器身份指纹"}
      byte_size(expected) < 16 -> {:error, "bad_server_identity", "服务器指纹无效"}
      Plug.Crypto.secure_compare(expected, presented) -> :ok
      true -> {:error, "fake_server", "服务器身份不匹配，拒绝发送口令"}
    end
  end
  def verify_server(_, _), do: {:error, "bad_server_identity", "缺少服务器身份指纹"}

  @doc "加群限流检查。"
  @spec check_rate(String.t()) :: :ok | {:error, String.t(), String.t()}
  def check_rate(gid) when is_binary(gid) do
    ensure_table()
    now = System.system_time(:millisecond)
    case :ets.lookup(@table, gid) do
      [] -> :ok
      [{_, st}] ->
        st = prune(st, now)
        cond do
          Map.get(st, :locked_until, 0) > now -> {:error, "rate_limited", "尝试过于频繁，请稍后重试"}
          length(Map.get(st, :attempts, [])) >= @rate_max -> {:error, "rate_limited", "尝试过于频繁，请稍后重试"}
          true -> :ok
        end
    end
  end

  @doc "记录一次加群结果，成功清失败计数，失败退避。"
  @spec note_result(String.t(), boolean()) :: :ok
  def note_result(gid, ok?) when is_binary(gid) and is_boolean(ok?) do
    ensure_table()
    now = System.system_time(:millisecond)
    st = case :ets.lookup(@table, gid) do
      [] -> %{attempts: [], fails: 0, locked_until: 0}
      [{_, s}] -> prune(s, now)
    end
    ns = if ok? do
      %{st | attempts: [], fails: 0, locked_until: 0}
    else
      fails = Map.get(st, :fails, 0) + 1
      attempts = [now | Map.get(st, :attempts, [])]
      locked = if fails >= @lock_threshold do
        backoff = min(@lock_base_ms * trunc(:math.pow(2, fails - @lock_threshold)), @lock_max_ms)
        now + backoff
      else
        Map.get(st, :locked_until, 0)
      end
      %{st | attempts: attempts, fails: fails, locked_until: locked}
    end
    :ets.insert(@table, {gid, ns})
    :ok
  end

  @doc "签发设备独立凭据，plain 仅返回一次。"
  @spec issue_device(map(), String.t(), String.t()) :: {:ok, map(), map()}
  def issue_device(group, member_id, display) when is_map(group) and is_binary(member_id) do
    did = "d_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    plain = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    hash = :crypto.hash(:sha256, plain)
    dev = %{"id" => did, "member_id" => member_id, "display" => display, "token_hash" => Base.encode64(hash), "paused" => false, "created_at" => System.system_time(:millisecond)}
    devs = Map.get(group, "devices", %{})
    {:ok, Map.put(group, "devices", Map.put(devs, did, Map.delete(dev, "plain"))), Map.put(dev, "plain", plain)}
  end

  @doc "校验设备凭据。"
  @spec verify_device(map(), String.t(), String.t()) :: boolean()
  def verify_device(group, did, plain) when is_map(group) and is_binary(did) and is_binary(plain) do
    case get_in(group, ["devices", did]) do
      %{"token_hash" => hb, "paused" => false} ->
        with {:ok, expected} <- Base.decode64(hb) do
          Plug.Crypto.secure_compare(:crypto.hash(:sha256, plain), expected)
        else
          _ -> false
        end
      _ -> false
    end
  end
  def verify_device(_, _, _), do: false

  @doc "暂停接新任务，已运行继续。"
  @spec pause_device(map(), String.t(), boolean()) :: map()
  def pause_device(group, did, paused) when is_map(group) and is_binary(did) and is_boolean(paused) do
    case get_in(group, ["devices", did]) do
      nil -> group
      d -> put_in(group, ["devices", did], Map.put(d, "paused", paused))
    end
  end

  @doc "设备心跳：更新 last_seen 用于在线判定。"
  @spec touch_device(map(), String.t()) :: map()
  def touch_device(group, did) when is_map(group) and is_binary(did) do
    case get_in(group, ["devices", did]) do
      nil -> group
      d -> put_in(group, ["devices", did], Map.put(d, "last_seen", System.system_time(:millisecond)))
    end
  end

  @doc "移除单设备，不影响成员其他设备。"
  @spec remove_device(map(), String.t()) :: map()
  def remove_device(group, did) when is_map(group) and is_binary(did) do
    devs = Map.get(group, "devices", %{})
    group |> Map.put("devices", Map.delete(devs, did)) |> bump_member_epoch()
  end

  @doc "移除成员并连带其设备，递增 epoch 让票据立即失效。"
  @spec remove_member(map(), String.t()) :: map()
  def remove_member(group, mid) when is_map(group) and is_binary(mid) do
    devs = Map.get(group, "devices", %{})
    kept = devs |> Enum.reject(fn {_, d} -> Map.get(d, "member_id") == mid end) |> Map.new()
    members = Map.get(group, "members", %{})
    group |> Map.put("devices", kept) |> Map.put("members", Map.delete(members, mid)) |> bump_member_epoch()
  end

  defp bump_member_epoch(group) do
    Map.update(group, "member_epoch", 1, fn e -> e + 1 end)
  end

  defp prune(st, now) do
    atts = Map.get(st, :attempts, []) |> Enum.filter(fn t -> now - t < @rate_window_ms end)
    Map.put(st, :attempts, atts)
  end

  defp ensure_table do
    Newbee.Collaboration.CrossHost.Store.ensure_owned(@table)
  end
end
