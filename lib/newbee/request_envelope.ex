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
  @version 1

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

    env = %{
      "version" => @version,
      "base_url" => client.base_url,
      "model" => client.model,
      "tools" => tools,
      "messages" => messages,
      "message_count" => length(messages),
      "sha256" => sha256(messages, tools),
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

  @doc "命中资格：快照存在且 route（base_url + model）与当前 client 一致。"
  def hit_eligible?(env, %Newbee.LLM.Client{} = client) when is_map(env) do
    env["base_url"] == client.base_url and env["model"] == client.model
  end

  def hit_eligible?(_env, _client), do: false

  @doc "快照文件路径（测试/诊断用）。"
  def path(%Newbee.Session{} = session), do: path_for(session)

  defp path_for(%Newbee.Session{dir: dir}), do: Path.join(dir, @file_name)

  defp valid?(env) do
    is_binary(env["base_url"]) and is_binary(env["model"]) and
      is_list(env["tools"]) and is_list(env["messages"]) and
      is_integer(env["message_count"])
  end

  defp sha256(messages, tools) do
    :crypto.hash(:sha256, Jason.encode_to_iodata!(%{"messages" => messages, "tools" => tools}))
    |> Base.encode16(case: :lower)
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
