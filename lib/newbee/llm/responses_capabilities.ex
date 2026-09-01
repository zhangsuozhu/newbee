defmodule Newbee.LLM.ResponsesCapabilities do
  @moduledoc """
  Responses API 能力探测结果的磁盘持久化。

  Responses 的 stream / encrypted_reasoning / continuation 能力由 `Newbee.LLM.Responses`
  在运行时探测（收到网关的 4xx 报错后降级），探测结果原本只存 `:persistent_term`，
  进程一重启就丢——于是每次重启都要重新踩一遍 400 才能再次探测出网关不支持的
  能力，每次踩错都伴随一次全量 input 重放，既慢又贵。

  本模块把探测结果按 route（`{base_url, model}`）落盘到
  `~/.newbee/llm-responses-capabilities.json`（可用 `NEWBEE_HOME` 覆盖根目录），
  重启后直接复用。只记**降级后的真实能力**（探测到不支持 → false）；
  未探测过的键不落盘，保持默认乐观（true），首次仍会尝试。
  """

  @file_name "llm-responses-capabilities.json"

  @doc "能力文件路径（`$NEWBEE_HOME` 或 `~/.newbee` 下）。"
  def path do
    root =
      case System.get_env("NEWBEE_HOME") do
        nil ->
          if Mix.env() == :test do
            Path.join(System.tmp_dir!(), "newbee-test-caps")
          else
            Path.join(System.user_home!(), ".newbee")
          end

        home ->
          home
      end

    Path.join(root, @file_name)
  end

  @doc "读某 route 已持久化的能力（无文件/坏文件/无此 route → %{}）。键为 atom。"
  def load(scope) do
    with {:ok, bytes} <- File.read(path()),
         {:ok, %{} = all} <- Jason.decode(bytes),
         %{} = caps <- Map.get(all, scope_key(scope)) do
      for {k, v} <- caps, k in ["stream", "encrypted_reasoning", "continuation"], is_boolean(v),
          into: %{} do
        {String.to_existing_atom(k), v}
      end
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  @doc "合并持久化某 route 的一项能力（原子 tmp+rename 写；失败静默，不影响请求）。"
  def put(scope, capability, value)
      when capability in [:stream, :encrypted_reasoning, :continuation] and is_boolean(value) do
    p = path()
    all = read_all()
    key = scope_key(scope)
    current = Map.get(all, key, %{})

    updated =
      Map.put(all, key, Map.put(current, Atom.to_string(capability), value))

    File.mkdir_p!(Path.dirname(p))
    tmp = p <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(updated))
    File.rename!(tmp, p)
    :ok
  rescue
    _ -> :ok
  end

  defp read_all do
    with {:ok, bytes} <- File.read(path()),
         {:ok, %{} = all} <- Jason.decode(bytes) do
      all
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # scope = {base_url, model}；文件里以字符串键存储，避免 Jason 把 tuple 编成 list。
  defp scope_key({base_url, model}), do: "#{base_url}::#{model}"
end
