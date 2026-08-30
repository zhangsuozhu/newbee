defmodule Newbee.LLM.ResponsesContinuation do
  @moduledoc """
  Responses API 的会话级 continuation checkpoint。

  仅当上次成功请求的 route、tools、reasoning 与逻辑 input 都是当前请求的严格
  前缀时，才返回 `previous_response_id` 与新增 input。checkpoint 只持久化前缀
  长度与哈希，不复制会话正文；中断/失败不覆盖，因此进程重启后仍可尝试续接。
  """

  @version 1

  def plan(nil, _envelope, _input), do: :full

  def plan(path, envelope, input) when is_binary(path) and is_map(envelope) and is_list(input) do
    with %{} = checkpoint <- load(path),
         true <- checkpoint["envelope_sha256"] == sha256(envelope),
         count when is_integer(count) and count >= 0 <- checkpoint["input_count"],
         true <- length(input) > count,
         {prefix, delta} <- Enum.split(input, count),
         true <- checkpoint["input_sha256"] == sha256(prefix),
         response_id when is_binary(response_id) and response_id != "" <- checkpoint["response_id"] do
      {:continue, response_id, delta}
    else
      _ -> :full
    end
  end

  def commit(nil, _envelope, _input, _response_id), do: :ok

  def commit(path, envelope, input, response_id)
      when is_binary(path) and is_map(envelope) and is_list(input) and is_binary(response_id) and response_id != "" do
    checkpoint = %{
      "version" => @version,
      "envelope_sha256" => sha256(envelope),
      "input_count" => length(input),
      "input_sha256" => sha256(input),
      "response_id" => response_id,
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(checkpoint))
    File.rename!(tmp, path)
    :ok
  rescue
    _ -> :ok
  end

  def commit(_path, _envelope, _input, _response_id), do: :ok

  def clear(nil), do: :ok

  def clear(path) when is_binary(path) do
    File.rm(path)
    File.rm(path <> ".tmp")
    :ok
  rescue
    _ -> :ok
  end

  defp load(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"version" => @version} = checkpoint} <- Jason.decode(bytes) do
      checkpoint
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sha256(value) do
    :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
  end
end
