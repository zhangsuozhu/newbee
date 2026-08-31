defmodule Newbee.Tools.Structural do
  # -- 宽容参数 --
  defp normalize_path(p) when is_binary(p), do: p
  defp normalize_path(p) when is_atom(p), do: to_string(p)
  defp normalize_path(%{path: p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{"path" => p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{file: p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{"file" => p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path([p]) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(other), do: to_string(other)

  defp normalize_module(m) when is_atom(m), do: m
  defp normalize_module(m) when is_binary(m) do
    m = String.trim(m)
    m = String.trim_leading(m, "Elixir.")
    try do
      String.to_existing_atom("Elixir." <> m)
    rescue
      _ ->
        parts = String.split(m, ".") |> Enum.map(&String.to_atom/1)
        Module.concat(parts)
    end
  end
  defp normalize_module(%{module: m}), do: normalize_module(m)
  defp normalize_module(%{"module" => m}), do: normalize_module(m)
  defp normalize_module(%{mod: m}), do: normalize_module(m)
  defp normalize_module(%{"mod" => m}), do: normalize_module(m)
  defp normalize_module(other) when is_atom(other), do: other
  defp normalize_module(other) when is_binary(other), do: normalize_module(other)
  defp normalize_module(other), do: other

  defp normalize_arity(a) when is_integer(a), do: a
  defp normalize_arity(a) when is_binary(a) do
    case Integer.parse(String.trim(a)) do
      {n, ""} -> n
      _ -> a
    end
  end
  defp normalize_arity(a) when is_atom(a) do
    case Integer.parse(to_string(a)) do
      {n, ""} -> n
      _ -> a
    end
  end
  defp normalize_arity(other), do: other

  @moduledoc """
  Elixir 结构编辑工具：按模块和函数定位 AST 级插入/替换。路径与模块参数宽容：`path` 支持 `binary` | `atom` | `%{path: p}`，`module` 支持 `atom` | `"My.Module"` | `%{module: m}`。
  与快照行号文本轨（`Tools.Edit`）互补：本模块用 Sourceror
  解析出的行列元数据做结构化插入/替换，落盘后统一 `Code.format_string!`。

  ## 函数清单
  - `list_functions(path :: String.t(), module :: module()) :: {:ok, [String.t()]} | {:error, :module_not_found}` — 列 `defmodule` 内 `def/defp` 签名，如 `["def hello/1", "defp helper/0"]`。
  - `insert_function(path, module, def_code :: String.t()) :: {:ok, :inserted} | {:error, %{reason: :syntax_error, hint: String.t()}} | {:error, :module_not_found}` — 在模块最后一个 `end` 前插入函数源码，自动缩进 2 空格。语法错误的 def_code 返回 `{:error, %{reason: :syntax_error, hint: ...}}` 而非静默成功。
  - `replace_function(path, module, name :: atom(), arity :: integer(), new_code :: String.t()) :: {:ok, :replaced} | {:error, :function_not_found | :module_not_found}` — 按 `name/arity` 定位整段定义换新，按原列缩进。
  - `format(path :: String.t()) :: {:ok, :formatted} | {:error, reason}` — `Code.format_string!` 格式化后回写。

  ## 可跑示例
      {:ok, sigs} = Newbee.Tools.Structural.list_functions("lib/my.ex", My.Module)
        {:ok, sigs} = Newbee.Tools.Structural.list_functions("lib/my.ex", "My.Module")
        {:ok, sigs} = Newbee.Tools.Structural.list_functions(%{path: "lib/my.ex", module: My.Module})
      {:ok, :inserted} = Newbee.Tools.Structural.insert_function("lib/my.ex", My.Module, "def hello(name), do: \"hi\"")
      {:ok, :replaced} = Newbee.Tools.Structural.replace_function("lib/my.ex", My.Module, :hello, 1, "def hello(name), do: String.upcase(name)")
      {:ok, :formatted} = Newbee.Tools.Structural.format("lib/my.ex")

  """

  @doc "在模块末尾（最后一个 end 之前）插入函数源码。"
  def insert_function(path, module, def_code) do
    path = normalize_path(path)
    module = normalize_module(module)
    with :ok <- validate_syntax(def_code),
         {:ok, src} <- File.read(path),
         {:ok, quoted} <- Sourceror.parse_string(src),
         {:ok, mod_meta} <- find_module_meta(quoted, module) do
      end_line = mod_meta[:end_line]

      if end_line do
        lines = String.split(src, "\n")
        indent = "  "

        body =
          def_code
          |> String.trim()
          |> String.split("\n")
          |> Enum.map_join("\n", &(indent <> &1))

        # 在 end 行之前插入：保留 end 行本身
        end_idx = end_line - 1
        new_src = Enum.take(lines, end_idx) ++ [body, Enum.at(lines, end_idx)] ++ Enum.drop(lines, end_idx + 1)
        new_src = Enum.join(new_src, "\n")
        write_formatted(path, new_src)
        {:ok, :inserted}
      else
        {:error, :module_not_found}
      end
    end
  end

  @doc "替换模块中 name/arity 函数（整段定义换新）。"
  def replace_function(path, module, name, arity, new_code) do
    path = normalize_path(path)
    module = normalize_module(module)
    arity = normalize_arity(arity)
    name = if is_binary(name), do: String.to_atom(name), else: name
    with {:ok, src} <- File.read(path),
         {:ok, quoted} <- Sourceror.parse_string(src),
         {:ok, mod_meta} <- find_module_meta(quoted, module) do
      _ = mod_meta

      case find_function_span(quoted, module, name, arity) do
        nil ->
          {:error, :function_not_found}

        {start_line, end_line, col} ->
          lines = String.split(src, "\n")
          indent = String.duplicate(" ", max(col - 1, 0))

          body =
            new_code
            |> String.trim()
            |> String.split("\n")
            |> Enum.map_join("\n", &(indent <> &1))

          new_src = splice_lines(lines, start_line - 1, end_line - 1, [body])
          write_formatted(path, new_src)
          {:ok, :replaced}
      end
    end
  end

  @doc "列出模块的函数签名。"




  def list_functions(path, module) do
    path = normalize_path(path)
    module = normalize_module(module)
    with {:ok, src} <- File.read(path),
         {:ok, quoted} <- Sourceror.parse_string(src) do
      case find_module(quoted, module) do
        nil ->
          {:error, :module_not_found}

        {:defmodule, _, [_, block]} ->
          sigs =
            block
            |> module_body()
            |> block_list()
            |> Enum.flat_map(fn
              {kind, _, [head | _]} when kind in [:def, :defp] ->
                case head do
                  {fname, _, args} when is_atom(fname) ->
                    ["#{kind} #{fname}/#{arity_of(args)}"]

                  _ ->
                    []
                end

              _ ->
                []
            end)

          {:ok, sigs}
      end
    end
  end

  @doc "格式化文件（Code.format_string!）。"
  def format(path) do
    path = normalize_path(path)
    with {:ok, src} <- File.read(path) do
      write_formatted(path, src)
      {:ok, :formatted}
    end
  end

  # ── internals ──

  defp block_list({:__block__, _, exprs}), do: exprs
  defp block_list(nil), do: []
  defp block_list(single), do: [single]

  # do 块两种形态：Sourceror 扩展关键字 [{{:__block__, _, [:do]}, body}] 或普通 [do: body]
  defp arity_of(nil), do: 0
  defp arity_of(args) when is_list(args), do: length(args)
  defp arity_of(_), do: 0

  defp module_body([{{_, _, [:do]}, body}]), do: body
  defp module_body([{{_, _, ["do"]}, body}]), do: body
  defp module_body(do: body), do: body
  defp module_body(_), do: nil

  defp find_module(quoted, module) do
    {_, found} =
      Macro.prewalk(quoted, nil, fn
        {:defmodule, _, [{:__aliases__, _, m}, _block]} = node, acc ->
          if Module.concat(m) == module, do: {node, node}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp find_module_meta(quoted, module) do
    case find_module(quoted, module) do
      nil ->
        {:error, :module_not_found}

      {:defmodule, meta, _} ->
        end_line =
          cond do
            is_list(meta[:end]) and is_integer(meta[:end][:line]) ->
              meta[:end][:line]

            is_list(meta[:end_of_expression]) and is_integer(meta[:end_of_expression][:line]) ->
              meta[:end_of_expression][:line]

            true ->
              nil
          end

        {:ok, Keyword.put(meta, :end_line, end_line)}
    end
  end

  defp find_function_span(quoted, module, name, arity) do
    case find_module(quoted, module) do
      nil ->
        nil

      {:defmodule, _, [_, block]} ->
        block
        |> module_body()
        |> block_list()
        |> Enum.find_value(fn
          {kind, meta, [{^name, _, args} | _]} = _node when kind in [:def, :defp] ->
            if (args == nil or is_list(args)) and arity_of(args) == arity do
              start_line = meta[:line]

              end_line =
                cond do
                  is_list(meta[:end]) and is_integer(meta[:end][:line]) ->
                    meta[:end][:line]

                  is_list(meta[:end_of_expression]) and is_integer(meta[:end_of_expression][:line]) ->
                    meta[:end_of_expression][:line]

                  true ->
                    start_line
                end

              {start_line, end_line, meta[:column] || 3}
            end

          _ ->
            nil
        end)
    end
  end

  defp splice_lines(lines, from_idx, to_idx, replacement) do
    (Enum.take(lines, from_idx) ++ replacement ++ Enum.drop(lines, to_idx + 1))
    |> Enum.join("\n")
  end

  defp write_formatted(path, src) do
    formatted = IO.iodata_to_binary(Code.format_string!(src)) <> "\n"
    File.write!(path, formatted)
  rescue
    _ -> File.write!(path, src)
  end

  defp validate_syntax(code) do
    case Code.string_to_quoted(code) do
      {:ok, _} -> :ok
      {:error, {_line, error, _token}} -> {:error, %{reason: :syntax_error, hint: "def_code 语法错误: " <> inspect(error)}}
    end
  end
  @doc false
  def list_functions(%{path: p, module: m}), do: list_functions(p, m)
  @doc false
  def list_functions(%{"path" => p, "module" => m}), do: list_functions(p, m)
  @doc false
  def list_functions(%{file: p, module: m}), do: list_functions(p, m)
  @doc false
  def list_functions(%{"file" => p, "module" => m}), do: list_functions(p, m)

  @doc false
  def insert_function(%{path: p, module: m, code: c}), do: insert_function(p, m, c)
  @doc false
  def insert_function(%{"path" => p, "module" => m, "code" => c}), do: insert_function(p, m, c)
  @doc false
  def insert_function(%{path: p, module: m, def_code: c}), do: insert_function(p, m, c)

  @doc false
  def replace_function(%{path: p, module: m, name: n, arity: a, code: c}), do: replace_function(p, m, n, a, c)
  @doc false
  def replace_function(%{"path" => p, "module" => m, "name" => n, "arity" => a, "code" => c}), do: replace_function(p, m, n, a, c)

  @doc false
  def format(%{path: p}), do: format(p)
  @doc false
  def format(%{"path" => p}), do: format(p)

end
