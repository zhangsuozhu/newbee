defmodule Newbee.Collaboration.CrossHost.Join do
  @moduledoc "加入流程：验服务器身份->限流->验口令->发设备凭据->登记能力。口令正确默认直接加入。"
  alias Newbee.Collaboration.CrossHost.Auth
  alias Newbee.Collaboration.CrossHost.Group
  alias Newbee.Collaboration.CrossHost.Scheduler
  @spec join(map(), map()) :: {:ok, map(), map()} | {:error, term(), term()}
  def join(group, params) when is_map(group) and is_map(params) do
    gid = Map.get(group, "id", "")

    with :ok <- Auth.verify_server(Map.get(params, "expected_fp", ""), Map.get(params, "presented_fp", "")),
         :ok <- Auth.check_rate(gid),
         true <- Group.verify_password(group, Map.get(params, "password", "")) do
      Auth.note_result(gid, true)
      mid = Map.get(params, "member_id", "m_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false))
      display = Map.get(params, "display", "device")
      members = Map.get(group, "members", %{})

      g1 =
        Map.put(
          group,
          "members",
          Map.put_new(members, mid, %{"display" => display, "joined_at" => System.system_time(:millisecond)})
        )

      {:ok, g2, dev} = Auth.issue_device(g1, mid, display)
      caps = Scheduler.detect()
      out = %{"member_id" => mid, "device" => dev, "caps" => caps, "quota" => Scheduler.default_quota()}
      {:ok, g2, out}
    else
      {:error, _, _} = err ->
        Auth.note_result(Map.get(group, "id", ""), false)
        err

      false ->
        Auth.note_result(Map.get(group, "id", ""), false)
        {:error, "bad_password", "口令错误"}
    end
  end

  @doc "加群码指纹与本机 Hub 证书指纹不一致时，说明码是另一台 Hub 的。"
  @spec wrong_hub?(term()) :: boolean()
  def wrong_hub?(presented) when is_binary(presented) and presented != "" do
    case Newbee.Web.Cert.fingerprint() do
      {:ok, local} -> presented != local
      _ -> false
    end
  end

  def wrong_hub?(_), do: false

  @doc "群不存在时的面向用户错误：先排除拿错 Hub，再报不存在。"
  @spec missing_group_error(term()) :: {:error, String.t(), String.t()}
  def missing_group_error(presented_fp) do
    if wrong_hub?(presented_fp) do
      {:error, "wrong_hub", "加群码不属于本机 Hub（证书指纹对不上）。请确认你现在连的是建群的那台机器，或让建群者在他那台机器的界面上操作。"}
    else
      {:error, "not_found", "协作群不存在：可能群已被解散，或本机 Hub 重启后记录丢失，请重新建群后再加。"}
    end
  end

  @spec invite(map(), binary(), binary()) :: map()
  def invite(group, address, fp) when is_map(group) and is_binary(address) and is_binary(fp) do
    %{
      "group" => Map.get(group, "name", ""),
      "project" => Map.get(group, "project_id", ""),
      "address" => address,
      "fingerprint" => fp
    }
  end

  @code_prefix "XG1."
  @doc "生成加群码：含群ID、指纹与一次性明文口令，粘贴即入群；只显示给建群者，注意保密。"
  @spec join_code(map(), String.t() | nil) :: binary()
  def join_code(group, plain \\ nil) when is_map(group) do
    payload = %{"v" => 1, "gid" => Map.get(group, "id"), "fp" => Map.get(group, "server_fp")}
    payload = if is_binary(plain) and plain != "", do: Map.put(payload, "pw", plain), else: payload
    raw = :json.encode(payload) |> IO.iodata_to_binary()
    @code_prefix <> Base.url_encode64(raw, padding: false)
  end

  def parse_code(code) when is_binary(code) do
    s = code |> String.trim() |> String.replace_prefix(@code_prefix, "")

    cond do
      byte_size(code) != byte_size(s) -> decode_code(s)
      String.contains?(s, "?") or String.contains?(s, "#") or String.starts_with?(s, "http") -> parse_link(s)
      s != "" and not String.contains?(s, " ") and byte_size(s) <= 64 -> {:ok, %{"gid" => s, "fp" => nil}}
      true -> {:error, "bad_code", "加群码看不懂，请检查后重试"}
    end
  end

  defp decode_code(s) do
    with {:ok, raw} <- Base.url_decode64(s, padding: false),
         %{"v" => 1, "gid" => gid} = m <-
           (try do
              :json.decode(raw)
            rescue
              _ -> %{}
            end) do
      {:ok, %{"gid" => gid, "fp" => Map.get(m, "fp"), "pw" => Map.get(m, "pw")}}
    else
      _ -> {:error, "bad_code", "加群码看不懂，请检查后重试"}
    end
  end

  defp parse_link(s) do
    try do
      uri = URI.parse(s)
      q = URI.decode_query(uri.query || "")
      hq = if uri.fragment, do: URI.decode_query(uri.fragment), else: %{}
      gid = Map.get(q, "gid") || Map.get(hq, "gid")
      fp = Map.get(q, "fp") || Map.get(hq, "fp")
      if is_binary(gid) and gid != "", do: {:ok, %{"gid" => gid, "fp" => fp}}, else: {:error, "bad_code", "链接里没有群信息"}
    rescue
      _ -> {:error, "bad_code", "加群码看不懂，请检查后重试"}
    end
  end
end
