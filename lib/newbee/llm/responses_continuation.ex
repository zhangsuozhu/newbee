defmodule Newbee.LLM.ResponsesContinuation do
  @moduledoc """
  Responses API 的会话级 continuation checkpoint。

  仅当上次成功请求的 route、tools、reasoning 与逻辑 input 都是当前请求的严格
  前缀时，才返回 `previous_response_id` 与新增 input。checkpoint 只持久化前缀
  长度与哈希，不复制会话正文；中断/失败不覆盖，因此进程重启后仍可尝试续接。
  """

  @version 1

  @doc false
  def plan(path, envelope, input) do
    case plan_with_reason(path, envelope, input) do
      {:continue, _response_id, _delta} = result -> result
      {:full, _reason} -> :full
    end
  end

  @doc false
  def plan_with_reason(nil, _envelope, _input), do: {:full, :no_checkpoint_path}

  def plan_with_reason(path, envelope, input)
      when is_binary(path) and is_map(envelope) and is_list(input) do
    case load(path) do
      nil ->
        {:full, :missing_or_invalid_checkpoint}

      checkpoint ->
        count = checkpoint["input_count"]

        cond do
          checkpoint["envelope_sha256"] != sha256(envelope) ->
            {:full, :request_properties_changed}

          not is_integer(count) or count < 0 ->
            {:full, :invalid_input_count}

          length(input) <= count ->
            {:full, :input_is_not_a_strict_extension}

          true ->
            {prefix, delta} = Enum.split(input, count)

            cond do
              checkpoint["input_sha256"] != sha256(prefix) ->
                {:full, :input_prefix_changed}

              not (is_binary(checkpoint["response_id"]) and checkpoint["response_id"] != "") ->
                {:full, :missing_response_id}

              true ->
                {:continue, checkpoint["response_id"], delta}
            end
        end
    end
  end

  def plan_with_reason(_path, _envelope, _input), do: {:full, :invalid_arguments}

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
