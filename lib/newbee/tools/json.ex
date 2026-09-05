defmodule Newbee.Tools.Json do
  @moduledoc """
  JSON tool: decode, encode, and read at `a.b[0]` paths.
  Path syntax: `a.b[0].c` (dots + array indexes) — the usual way to pluck fields from API responses.

  ## Functions
  - `decode(text :: String.t()) :: {:ok, value} | {:error, %{reason: :decode_failed, line:, column:, position:}}` — parse a JSON document (on `Jason.decode`); bad JSON returns an error map with line/column.
  - `encode(value, pretty \\\\ false) :: String.t() | {:error, :encode_failed}` — encode to JSON, prettified when `pretty: true`.
  - `get(value, path :: String.t()) :: {:ok, v} | :error` — read at a path (never raises).
  - `get!(value, path :: String.t()) :: v | nil` — read at a path, `[idx]` segments index into arrays.

  ## Runnable example
      {:ok, m} = Newbee.Tools.Json.decode(~s({"a": {"b": [1,2]}}))
      Newbee.Tools.Json.get(m, "a.b[0]")         # => {:ok, 1}
      Newbee.Tools.Json.get!(m, "a.b[1]")        # => 2
      Newbee.Tools.Json.encode(%{a: 1}, true)
  """

  @doc "Parse JSON. {:ok, value} on success; structured error with line/column/position on bad JSON."
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

  @doc "Encode to a JSON document (optionally prettified). Returns the text directly, or `{:error, :encode_failed}`."
  def encode(value, pretty \\ false) do
    if pretty, do: Jason.encode!(value, pretty: true), else: Jason.encode!(value)
  rescue
    _ -> {:error, :encode_failed}
  end

  @doc "Read at a path: Json.get!(resp, \"data.items[0].name\"). Missing segment returns nil."
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

  @doc "Read at a path (never raises). Missing segment returns :error, explicit null returns {:ok, nil}. Returns {:ok, v} | :error."
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
