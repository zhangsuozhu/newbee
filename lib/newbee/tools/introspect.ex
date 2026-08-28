defmodule Newbee.Tools.Introspect do
  @moduledoc """
  Elixir 模块内省工具：查询真实导出、moduledoc 和 BEAM 信息。
  模型用它了解已加载模块的 API，不必读源码。

  ## 函数清单
  - `exports(module :: module()) :: [{atom(), arity()}]` — 模块公开函数签名列表（过滤 `__info__/module_info`）。
  - `moduledoc(module :: module()) :: String.t() | nil` — 模块 `@moduledoc` 首段（经 `Code.fetch_docs`）。
  - `beam_info(module :: module()) :: %{module: module(), exports: [...], attributes: map()}` — beam chunk 摘要，经 `:beam_lib.chunks` 取 `:attributes`。

  ## 可跑示例
      Newbee.Tools.Introspect.exports(Newbee.Tools.Fs)
      Newbee.Tools.Introspect.moduledoc(Newbee.Tools.Run)
      Newbee.Tools.Introspect.beam_info(Newbee.Diff)

  """

  @doc "模块公开函数签名列表：[{name, arity}]。"
  def exports(module) do
    if Code.ensure_loaded?(module) do
      module.__info__(:functions) |> Enum.reject(fn {n, _} -> n in [:__info__, :module_info] end)
    else
      []
    end
  end

  @doc "模块 @moduledoc（首段）。"
  def moduledoc(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        doc

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "beam chunk 摘要：%{module, exports, attributes}（Abstract Code 里提取的 attributes 子集）。"
  def beam_info(module) do
    case :code.which(module) do
      path when is_list(path) or is_binary(path) ->
        chunk_path = if is_list(path), do: List.to_string(path), else: path

        case :beam_lib.chunks(String.to_charlist(chunk_path), [:attributes]) do
          {:ok, {_, [attributes: attrs]}} ->
            %{
              module: module,
              exports: exports(module),
              attributes: Map.new(attrs, fn {k, v} -> {k, v} end)
            }

          _ ->
            %{module: module, exports: exports(module), attributes: %{}}
        end

      _ ->
        %{module: module, exports: exports(module), attributes: %{}}
    end
  rescue
    _ -> %{module: module, exports: exports(module), attributes: %{}}
  end
end
