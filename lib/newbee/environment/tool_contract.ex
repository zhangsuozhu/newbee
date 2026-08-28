defmodule Newbee.Environment.ToolContract do
  @moduledoc """
  模型可见工具的机器治理合同。

  动态工具必须声明用途边界、真实 API、错误语义、示例和副作用；
  builtin 工具使用编译文档做等价审计。该模块由 Adapter、Coordinator、
  Verifier 和 PluginManager 共用，任何生成路径都不能绕过。
  """

  @summary_max 120
  @boundary_max 500
  @example_max 1_000
  @examples_max 8
  @builtin_doc_max 3_500
  @plugin_callbacks [
    id: 0,
    version: 0,
    describe: 0,
    dependencies: 0,
    health: 1,
    self_test: 1,
    start: 1,
    stop: 1,
    migrate: 3
  ]

  @doc "校验动态 tool 模块及其 PluginContract envelope。"
  def validate_module(module, envelope, source)
      when is_atom(module) and is_map(envelope) and is_binary(source) do
    describe = Map.get(envelope, :describe, %{})

    errors =
      []
      |> require_equal(:kind, field(describe, :kind), :tool)
      |> require_text(:summary, field(describe, :summary), @summary_max)
      |> require_text(:when_to_use, field(describe, :when_to_use), @boundary_max)
      |> require_text(:avoid_when, field(describe, :avoid_when), @boundary_max)
      |> require_list(:capabilities, field(describe, :capabilities))
      |> require_list(:effects, field(describe, :effects))
      |> validate_error_contract(field(describe, :error_contract))
      |> validate_api(module, field(describe, :api))
      |> validate_examples(module, field(describe, :examples))
      |> validate_examples_cover_api(field(describe, :api), field(describe, :examples))
      |> validate_dynamic_docs(source, field(describe, :api))

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @doc "校验全部 builtin tool 的文档、示例和上下文预算。"
  def validate_builtins do
    errors =
      Newbee.Plugins.list()
      |> Enum.filter(&(&1.kind == :tool))
      |> Enum.flat_map(fn item ->
        module = item.name |> String.trim_leading("Elixir.") |> then(&Module.concat([&1]))

        case validate_builtin(module) do
          :ok -> []
          {:error, reasons} -> [{module, reasons}]
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "校验单个 builtin tool 的公开文档和示例。"
  def validate_builtin(module) when is_atom(module) do
    with {:docs_v1, _, _, _, module_doc, _, docs} <- Code.fetch_docs(module) do
      doc = doc_text(module_doc)
      examples = example_section(doc)
      visible_docs = visible_function_docs(docs)
      documented = visible_docs |> Enum.flat_map(&documented_arities/1) |> MapSet.new()
      hidden = docs |> hidden_function_docs() |> Enum.flat_map(&documented_arities/1) |> MapSet.new()
      exported = module.__info__(:functions) |> MapSet.new() |> MapSet.difference(hidden)

      errors =
        []
        |> maybe_error(byte_size(doc) > @builtin_doc_max, {:moduledoc_too_large, byte_size(doc), @builtin_doc_max})
        |> maybe_error(
          not MapSet.subset?(exported, documented),
          {:missing_docs, MapSet.difference(exported, documented) |> MapSet.to_list()}
        )
        |> validate_builtin_examples(module, visible_docs, examples)

      if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
    else
      _ -> {:error, [:missing_module_docs]}
    end
  end

  @doc "生成符合合同的最小工具源码骨架。"
  def template(module, plugin_id) when is_atom(module) and is_binary(plugin_id) do
    module_name = inspect(module)

    """
    defmodule #{module_name} do
      @behaviour Newbee.Environment.PluginContract
      @moduledoc "One-line purpose.\n\n## 可跑示例\n    #{module_name}.run(input)"

      def id, do: #{inspect(plugin_id)}
      def version, do: "1.0.0"
      def dependencies, do: []

      def describe do
        %{
          kind: :tool,
          summary: "one-line purpose",
          when_to_use: "when this tool is the narrowest fit",
          avoid_when: "use an existing higher-level tool when it already fits",
          capabilities: [],
          effects: [],
          error_contract: %{recoverable: :error_tuple, unexpected: :raise},
          api: [%{name: :run, arity: 1, returns: "{:ok, value} | {:error, reason}", errors: "recoverable errors are values"}],
          examples: ["#{module_name}.run(input)"]
        }
      end

      @doc "Run the tool."
      def run(input), do: {:ok, input}
    end
    """
  end

  defp validate_examples_cover_api(errors, api, examples)
       when is_list(api) and api != [] and is_list(examples) and examples != [] do
    uncovered =
      for entry <- api,
          name = field(entry, :name),
          not Enum.any?(examples, fn ex ->
            ex |> String.trim() |> String.contains?("." <> to_string(name) <> "(") and
              not String.contains?(String.trim(ex), "\n")
          end),
          do: name

    maybe_error(errors, uncovered != [], {:api_without_examples, uncovered})
  end

  defp validate_examples_cover_api(errors, _api, _examples), do: errors

  defp validate_dynamic_docs(errors, source, api) when is_list(api) do
    case source_docs(source) do
      {:ok, module_doc, documented} ->
        examples = example_section(module_doc)
        declared = MapSet.new(api, &{field(&1, :name), field(&1, :arity)})

        errors =
          errors
          |> maybe_error(module_doc == "", :missing_moduledoc)
          |> maybe_error(
            byte_size(module_doc) > @builtin_doc_max,
            {:moduledoc_too_large, byte_size(module_doc), @builtin_doc_max}
          )
          |> maybe_error(examples == "", :missing_moduledoc_examples)
          |> maybe_error(
            not MapSet.subset?(declared, documented),
            {:missing_api_docs, MapSet.difference(declared, documented) |> MapSet.to_list()}
          )

        Enum.reduce(api, errors, fn entry, acc ->
          name = field(entry, :name)

          maybe_error(
            acc,
            not String.contains?(examples, "." <> to_string(name) <> "("),
            {:missing_moduledoc_example, name}
          )
        end)

      {:error, reason} ->
        [{:invalid_source_docs, reason} | errors]
    end
  end

  defp validate_dynamic_docs(errors, _source, _api), do: errors

  defp source_docs(source) do
    with {:ok, quoted} <- Code.string_to_quoted(source),
         {:ok, body} <- module_body(quoted) do
      {module_doc, docs, _pending} =
        body
        |> block_list()
        |> Enum.reduce({"", MapSet.new(), nil}, fn
          {:@, _, [{:moduledoc, _, [doc]}]}, {_module_doc, docs, pending} when is_binary(doc) ->
            {doc, docs, pending}

          {:@, _, [{:doc, _, [doc]}]}, {module_doc, docs, _pending} when is_binary(doc) ->
            {module_doc, docs, doc}

          {kind, _, [{name, _, args} | _]}, {module_doc, docs, pending}
          when kind in [:def, :defmacro] and is_atom(name) ->
            arity = length(args || [])
            docs = if is_binary(pending) and pending != "", do: MapSet.put(docs, {name, arity}), else: docs
            {module_doc, docs, nil}

          _, acc ->
            acc
        end)

      {:ok, module_doc, docs}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_defmodule}
    end
  end

  defp module_body({:defmodule, _, [_module, [do: body]]}), do: {:ok, body}
  defp module_body(_), do: {:error, :missing_defmodule}
  defp block_list({:__block__, _, expressions}), do: expressions
  defp block_list(expression), do: [expression]

  defp validate_api(errors, module, api) when is_list(api) and api != [] do
    {declared, errors} =
      Enum.reduce(api, {MapSet.new(), errors}, fn entry, {seen, acc} ->
        name = field(entry, :name)
        arity = field(entry, :arity)
        key = {name, arity}

        acc =
          acc
          |> maybe_error(not is_atom(name), {:invalid_api_name, name})
          |> maybe_error(not is_integer(arity) or arity < 0, {:invalid_api_arity, key})
          |> maybe_error(not text?(field(entry, :returns)), {:missing_api_returns, key})
          |> maybe_error(not text?(field(entry, :errors)), {:missing_api_errors, key})
          |> maybe_error(MapSet.member?(seen, key), {:duplicate_api, key})

        {MapSet.put(seen, key), acc}
      end)

    exported = tool_exports(module)
    maybe_error(errors, declared != exported, {:api_mismatch, declared, exported})
  end

  defp validate_api(errors, _module, _api), do: [{:missing_or_invalid, :api} | errors]

  defp validate_examples(errors, module, examples)
       when is_list(examples) and examples != [] and length(examples) <= @examples_max do
    prefix = inspect(module) <> "."

    Enum.reduce(examples, errors, fn example, acc ->
      acc
      |> maybe_error(not text?(example), {:invalid_example, example})
      |> maybe_error(is_binary(example) and String.length(example) > @example_max, {:example_too_large, example})
      |> maybe_error(
        is_binary(example) and not String.contains?(example, prefix),
        {:example_does_not_call_tool, example}
      )
    end)
  end

  defp validate_examples(errors, _module, _examples),
    do: [{:missing_or_invalid, :examples} | errors]

  defp validate_error_contract(errors, contract) when is_map(contract) do
    errors
    |> maybe_error(field(contract, :recoverable) not in [:error_tuple, :none], {
      :invalid_recoverable_mode,
      field(contract, :recoverable)
    })
    |> maybe_error(field(contract, :unexpected) not in [:raise, :error_tuple], {
      :invalid_unexpected_mode,
      field(contract, :unexpected)
    })
  end

  defp validate_error_contract(errors, _),
    do: [{:missing_or_invalid, :error_contract} | errors]

  defp tool_exports(module) do
    callbacks = MapSet.new(@plugin_callbacks)
    module.__info__(:functions) |> MapSet.new() |> MapSet.difference(callbacks)
  end

  defp visible_function_docs(docs) do
    Enum.filter(docs, fn
      {{:function, name, _}, _, _, doc, _} ->
        name not in [:__info__, :module_info] and doc_text(doc) != ""

      _ ->
        false
    end)
  end

  defp hidden_function_docs(docs) do
    Enum.filter(docs, fn
      {{:function, _, _}, _, _, :hidden, _} -> true
      _ -> false
    end)
  end

  defp documented_arities({{:function, name, arity}, _, signatures, _, _}) do
    defaults =
      case signatures do
        [signature | _] -> length(Regex.scan(~r/\\/, signature))
        _ -> 0
      end

    Enum.map((arity - defaults)..arity, &{name, &1})
  end

  defp validate_builtin_examples(errors, module, docs, examples) do
    Enum.reduce(docs, errors, fn {{:function, name, _}, _, _, _, _}, acc ->
      maybe_error(acc, not String.contains?(examples, ".#{name}("), {:missing_example, {module, name}})
    end)
  end

  defp example_section(doc) do
    case String.split(doc, "## 可跑示例", parts: 2) do
      [_, tail] -> String.split(tail, "## ", parts: 2) |> hd()
      _ -> ""
    end
  end

  defp require_equal(errors, _field, expected, expected), do: errors

  defp require_equal(errors, field, value, expected),
    do: [{:invalid, field, value, expected} | errors]

  defp require_text(errors, field, value, max) do
    maybe_error(
      errors,
      not is_binary(value) or String.trim(value) == "" or String.length(value) > max,
      {:invalid_text, field, max}
    )
  end

  defp require_list(errors, _field, value) when is_list(value), do: errors
  defp require_list(errors, field, _), do: [{:missing_or_invalid, field} | errors]
  defp maybe_error(errors, true, error), do: [error | errors]
  defp maybe_error(errors, false, _error), do: errors
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_, _), do: nil
  defp doc_text(%{"en" => text}) when is_binary(text), do: text
  defp doc_text(%{"zh" => text}) when is_binary(text), do: text
  defp doc_text({_format, text}) when is_binary(text), do: text
  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_), do: ""
end
