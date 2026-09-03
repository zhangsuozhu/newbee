defmodule Newbee.Tools.Json do
  @moduledoc """
  JSON 工具：解码、编码和按 `a.b[0]` 路径取值。
  路径语法：`a.b[0].c`（点分 + 数组下标），模型常用它从 API 响应抠字段。

  ## 函数清单
  - `decode(text :: String.t()) :: {:ok, value} | {:error, %{reason: :decode_failed, line:, column:, position:}}` — 解析 JSON 字符串（基于 `Jason.decode`），非法 JSON 返回带行/列号的错误 map。
  - `encode(value, pretty \\\\ false) :: String.t() | {:error, :encode_failed}` — 编码为 JSON，`pretty: true` 时美化。
  - `get(value, path :: String.t()) :: {:ok, v} | :error` — 按路径取值（不抛错）。
  - `get!(value, path :: String.t()) :: v | nil` — 按路径取值，段含 `[idx]` 时取数组元素。

  ## 可跑示例
      {:ok, m} = Newbee.Tools.Json.decode(~s({"a": {"b": [1,2]}}))
      Newbee.Tools.Json.get(m, "a.b[0]")         # => {:ok, 1}
      Newbee.Tools.Json.get!(m, "a.b[1]")        # => 2
      Newbee.Tools.Json.encode(%{a: 1}, true)

  """

  @doc "解析 JSON。成功返回 {:ok, value}；非法 JSON 返回带 line/column/position 的结构化错误。"
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, _} = ok ->
        ok

      {:error, %Jason.DecodeError{position: pos, data: data}} ->
        # 从 position 计算 line/column
        {line, col} = line_col_from_pos(data, pos)
        {:error, %{reason: :decode_failed, line: line, column: col, position: pos}}

      {:error, _} = err ->
        err
    end
  end

  @doc "编码为 JSON 字符串（美化可选）。"
  def encode(value, pretty \\ false) do
    if pretty, do: Jason.encode!(value, pretty: true), else: Jason.encode!(value)
  rescue
    _ -> {:error, :encode_failed}
  end

  @doc "按路径从 JSON 取值：Json.get!(resp, \"data.items[0].name\")。缺段返回nil。"
  def get!(value, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn seg, acc ->
      case Regex.run(~r/^(.+?)\[(\d+)\]$/, seg) do
        [_, key, idx] ->
          case acc do
            %{^key => list} when is_list(list) -> Enum.at(list, String.to_integer(idx))
            _ -> nil
          end

        _ ->
          case acc do
            %{} -> Map.get(acc, seg)
            _ -> nil
          end
      end
    end)
  end

  @doc "按路径取值（不抛错）。缺段返回:error，显式null返回{:ok, nil}。返回 {:ok, v} | :error。"
  def get(value, path) when is_binary(path) do
    case fetch_path(value, path) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  rescue
    _ -> :error
  end

  defp fetch_path(value, path) do
    segs = String.split(path, ".", trim: true)
    do_fetch(value, segs)
  end

  defp do_fetch(acc, []), do: {:ok, acc}

  defp do_fetch(acc, [seg | rest]) do
    case Regex.run(~r/^(.+?)\[(\d+)\]$/, seg) do
      [_, key, idx_str] ->
        idx = String.to_integer(idx_str)

        case acc do
          %{^key => list} when is_list(list) ->
            if idx < length(list) do
              do_fetch(Enum.at(list, idx), rest)
            else
              :error
            end

          _ ->
            :error
        end

      _ ->
        case acc do
          %{} = m ->
            if Map.has_key?(m, seg) do
              do_fetch(Map.get(m, seg), rest)
            else
              :error
            end

          _ ->
            :error
        end
    end
  end

  defp line_col_from_pos(data, pos) do
    lines = String.split(data, "\n")

    {line, col} =
      Enum.reduce_while(lines, {1, 0}, fn line_str, {ln, acc_pos} ->
        line_len = byte_size(line_str) + 1

        if acc_pos + line_len > pos do
          {:halt, {ln, pos - acc_pos + 1}}
        else
          {:cont, {ln + 1, acc_pos + line_len}}
        end
      end)

    {line, col}
  end
end
