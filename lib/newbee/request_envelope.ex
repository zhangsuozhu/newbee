defmodule Newbee.RequestEnvelope do
  @moduledoc """
  上一次路由请求的可缓存前缀快照（prefix-cache 方案 I1）。

  由 Agent.Loop 在每次标准路由请求（stream_chat）发出前写入；Archive 摘要路径
  消费（I2/I3）。快照是"请求将发送的消息 + tools + route"的逐字节引用，
  Archive 只读不猜——摘要请求 = 快照严格前缀 + 尾部压缩指令时，provider
  前缀缓存命中才成立。非 LLM client 或无会话时不写（no-op），绝不为
  无法证明的前缀伪装命中。
  """

  @file_name "last-routed-request.json"
  @version 2

  @doc """
  记录即将发出的标准路由请求。

  - `session` 为 nil → no-op；
  - `client` 不是 `%Newbee.LLM.Client{}`（注入函数/测试 stub）→ no-op；
  - 写失败静默降级（rescue → :ok），不影响主循环。

  用 tmp + rename 原子写；`messages` 与 `tools` 存 JSON 编码后的同一对象树，
  不做任何截断/降维/重排。
  """
  def record(session, client, messages, tools \\ Newbee.Codec.tools())

  @spec record(Newbee.Session.t() | nil, map() | nil, list(), list()) :: :ok
  def record(%Newbee.Session{} = session, %Newbee.LLM.Client{} = client, messages, tools)
      when is_list(messages) and is_list(tools) do
    path = path_for(session)

    route = Newbee.LLM.Client.cache_route(client)

    env = %{
      "version" => @version,
      "base_url" => client.base_url,
      "model" => client.model,
      "route" => route,
      "tools" => tools,
      "messages" => messages,
      "message_count" => length(messages),
      "sha256" => sha256(messages, tools, route),
      "recorded_at" => iso_now()
    }

    try do
      File.mkdir_p!(session.dir)
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode_to_iodata!(env))
      File.rename!(tmp, path)
      :ok
    rescue
      _ -> :ok
    end
  end

  def record(_s, _c, _m, _t), do: :ok

  @doc "读取快照。缺失/损坏/版本不符/字段非法 → nil（视为无快照，走抽取路径）。"
  def load(%Newbee.Session{} = session) do
    case File.read(path_for(session)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"version" => @version} = env} ->
            if valid?(env), do: env, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  命中资格：快照存在且 route（base_url、model、API 模式、reasoning、cache key、缓存选项等）与当前 client 一致。

  tools 与请求属性都必须一致，避免把只共享消息前缀、但实际 provider 请求体不同的摘要请求误判为可复用。
  旧版本快照没有完整 route 指纹，会在读取时失配并回到有界抽取路径。
  """
  def hit_eligible?(env, %Newbee.LLM.Client{} = client) when is_map(env) do
    env["base_url"] == client.base_url and
      env["model"] == client.model and
      env["route"] == Newbee.LLM.Client.cache_route(client) and
      tools_current?(env["tools"])
  end

  def hit_eligible?(_env, _client), do: false

  # 用键序无关指纹比较：快照 tools 可能来自 JSON 解码（字符串键）或直接构造
  # （原子键），map 键序与列表顺序都不可靠，递归排序键后按编码字节比较。

  defp canon_tools(tools) do
    tools |> Enum.map(&canon_json/1) |> Enum.sort() |> Enum.join("|")
  end

  # 键序无关指纹：map → 排序键的 JSON 片段（内嵌值用 JSON 编码），list → 元素指纹连接。
  defp canon_json(%{} = m) do
    m
    |> Map.to_list()
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> to_string(k) <> "=" <> canon_json(v) end)
    |> Enum.join(",")
  end

  defp canon_json(v) when is_list(v), do: Enum.map(v, &canon_json/1) |> Enum.join(";")

  defp canon_json(v), do: Jason.encode!(v)

  defp tools_current?(tools) when is_list(tools) do
    canon_tools(tools) == canon_tools(Newbee.Codec.tools())
  end

  defp tools_current?(_), do: false

  @doc "快照文件路径（测试/诊断用）。"
  def path(%Newbee.Session{} = session), do: path_for(session)

  defp path_for(%Newbee.Session{dir: dir}), do: Path.join(dir, @file_name)

  defp valid?(env) do
    base_ok =
      is_binary(env["base_url"]) and is_binary(env["model"]) and
        is_map(env["route"]) and is_list(env["tools"]) and is_list(env["messages"]) and
        is_integer(env["message_count"]) and env["message_count"] == length(env["messages"]) and
        is_binary(env["sha256"]) and is_binary(env["recorded_at"])

    if base_ok do
      try do
        sha256(env["messages"], env["tools"], env["route"]) == env["sha256"]
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp sha256(messages, tools, route) do
    # canonical：键序与原子串键无关，JSON往返稳定，防篡改毒化digest
    payload = canon_json(messages) <> "|" <> canon_json(tools) <> "|" <> canon_json(route)
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
