defmodule Newbee.Tools.ToolDocumentationContractTest do
  use ExUnit.Case, async: false

  @codec_budget 1_500
  @plugin_section_budget 1_800
  @tool_doc_budget 3_500

  test "常驻工具提示短小且没有已删除 API" do
    schema = Jason.encode!(Newbee.Codec.tools())
    section = Newbee.Plugins.prompt_section()

    assert byte_size(schema) <= @codec_budget
    assert byte_size(section) <= @plugin_section_budget
    assert Enum.map(Newbee.Codec.tools(), & &1.function.name) |> Enum.sort() == ["ask", "done", "run_elixir"]

    for stale <- ["Edit.V2", "edit/v2", "sh_long", "django_test", "Scaffold.compile", "Scaffold.test"] do
      refute schema =~ stale
      refute section =~ stale
    end

    assert section =~ "prefer `Newbee.read/1` for reads"
    assert section =~ "plain-GET bodies via `Newbee.read/1`"
    assert section =~ "prefer higher-level tools"
    assert section =~ "compile/test via `Run`"
  end

  test "每个模型可见能力的公开函数都有 @doc 和可运行示例" do
    for %{name: name} <- Newbee.Plugins.list() do
      module = name |> String.trim_leading("Elixir.") |> then(&Module.concat([&1]))
      assert {:docs_v1, _, _, _, module_doc, _, docs} = Code.fetch_docs(module)
      doc = doc_text(module_doc)
      invalid_default = <<32, 92, 32>>

      refute :binary.match(doc, invalid_default) != :nomatch,
             "模块文档默认参数必须写成双反斜线：" <> inspect(module)

      example = example_section(doc)

      public_docs =
        Enum.filter(docs, fn
          {{:function, function, _arity}, _, _, function_doc, _} ->
            function not in [:__info__, :module_info] and doc_text(function_doc) != ""

          _ ->
            false
        end)

      documented = public_docs |> Enum.flat_map(&documented_arities/1) |> MapSet.new()

      hidden =
        docs
        |> Enum.filter(fn
          {{:function, _, _}, _, _, :hidden, _} -> true
          _ -> false
        end)
        |> Enum.flat_map(&documented_arities/1)
        |> MapSet.new()

      exported = module.__info__(:functions) |> MapSet.new() |> MapSet.difference(hidden)

      assert MapSet.subset?(exported, documented),
             "#{inspect(module)} 缺少 @doc: #{inspect(MapSet.difference(exported, documented))}"

      for {{:function, function, _arity}, _, _, _, _} <- public_docs do
        assert example =~ ".#{function}(", "#{inspect(module)}.#{function} 缺少调用示例"
      end
    end
  end

  test "tool scheme 只展示一次真实签名且受上下文预算约束" do
    for %{name: name} <- Newbee.Plugins.list() do
      module_name = String.trim_leading(name, "Elixir.")
      assert {:ok, rendered} = Newbee.read("tool://#{module_name}")

      assert byte_size(rendered) <= @tool_doc_budget,
             "#{module_name} 文档过大: #{byte_size(rendered)} bytes"

      assert rendered =~ "## Real function signatures"
      refute rendered =~ "## Functions"
    end
  end

  defp documented_arities({{:function, function, arity}, _, signatures, _doc, _metadata}) do
    defaults =
      case signatures do
        [signature | _] -> length(Regex.scan(~r/\\/, signature))
        _ -> 0
      end

    Enum.map((arity - defaults)..arity, &{function, &1})
  end

  defp example_section(doc) do
    case String.split(doc, "## Runnable example", parts: 2) do
      [_, tail] -> String.split(tail, "## ", parts: 2) |> hd()
      _ ->
        case String.split(doc, "## 可跑示例", parts: 2) do
          [_, tail] -> String.split(tail, "## ", parts: 2) |> hd()
          _ -> ""
        end
    end
  end

  defp doc_text(%{"en" => text}) when is_binary(text), do: text
  defp doc_text(%{"zh" => text}) when is_binary(text), do: text
  defp doc_text({_format, text}) when is_binary(text), do: text
  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_), do: ""
end
