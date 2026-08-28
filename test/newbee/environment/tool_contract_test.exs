defmodule Newbee.Environment.ToolContractTest do
  use ExUnit.Case, async: false

  alias Newbee.Environment.{PluginContract, ToolContract}

  defp valid_source(module \\ Demo.GeneratedTool) do
    """
    defmodule #{inspect(module)} do
      @behaviour Newbee.Environment.PluginContract
      @moduledoc "Echo input.\n\n## 可跑示例\n    #{inspect(module)}.run(input)"

      def id, do: "tool.generated"
      def version, do: "1.0.0"
      def dependencies, do: []

      def describe do
        %{
          kind: :tool,
          summary: "Echo input",
          when_to_use: "when a deterministic echo is required",
          avoid_when: "do not use for file, shell, or network work",
          capabilities: [],
          effects: [],
          error_contract: %{recoverable: :error_tuple, unexpected: :raise},
          api: [%{name: :run, arity: 1, returns: "{:ok, value}", errors: "none"}],
          examples: ["#{inspect(module)}.run(input)"]
        }
      end

      @doc "Echo input."
      def run(input), do: {:ok, input}
    end
    """
  end

  test "valid dynamic tool passes machine contract" do
    source = valid_source()
    assert {:ok, %{module: module, envelope: envelope}} = PluginContract.validate_source(source, :tool)
    assert :ok = ToolContract.validate_module(module, envelope, source)
  end

  test "missing selection boundary, error contract, API and examples is rejected" do
    source = """
    defmodule Demo.BadTool do
      @behaviour Newbee.Environment.PluginContract
      def id, do: "tool.bad"
      def version, do: "1.0.0"
      def dependencies, do: []
      def describe, do: %{kind: :tool, summary: "bad", capabilities: [], effects: []}
      def run(input), do: input
    end
    """

    assert {:error, [{:tool_contract, errors}]} = PluginContract.validate_source(source, :tool)
    assert Enum.any?(errors, &match?({:invalid_text, :when_to_use, _}, &1))
    assert {:missing_or_invalid, :error_contract} in errors
    assert {:missing_or_invalid, :api} in errors
    assert {:missing_or_invalid, :examples} in errors
  end

  test "declared API must exactly match non-contract public exports" do
    source =
      String.replace(
        valid_source(Demo.ApiMismatch),
        "def run(input), do: {:ok, input}",
        "def run(input), do: {:ok, input}\n      def leaked_helper, do: :oops"
      )

    assert {:error, [{:tool_contract, errors}]} = PluginContract.validate_source(source, :tool)
    assert Enum.any?(errors, &match?({:api_mismatch, _, _}, &1))
  end

  test "builtin tools satisfy the equivalent documentation contract" do
    assert :ok = ToolContract.validate_builtins()
  end

  test "api entry without matching example is rejected" do
    # add extra/0: real function + @doc + moduledoc example, but NOT in describe.examples
    source =
      valid_source()
      |> String.replace(
        "api: [%{name: :run, arity: 1, returns: \"{:ok, value}\", errors: \"none\"}]",
        "api: [%{name: :run, arity: 1, returns: \"{:ok, value}\", errors: \"none\"}, %{name: :extra, arity: 0, returns: \":extra\", errors: \"none\"}]"
      )
      |> String.replace(
        "@doc \"Echo input.\"\n      def run(input), do: {:ok, input}",
        "@doc \"Echo input.\"\n      def run(input), do: {:ok, input}\n\n      @doc \"Return :extra.\"\n      def extra, do: :extra"
      )
      |> String.replace(
        "## 可跑示例\\n    Demo.GeneratedTool.run(input)",
        "## 可跑示例\\n    Demo.GeneratedTool.run(input)\\n    Demo.GeneratedTool.extra()"
      )

    assert {:error, reasons} = PluginContract.validate_source(source, :tool)
    assert inspect(reasons) =~ "api_without_examples"
  end

  test "template compiles and satisfies both contracts" do
    source = ToolContract.template(Demo.TemplateTool, "tool.template")
    assert {:ok, %{module: module, envelope: envelope}} = PluginContract.validate_source(source, :tool)
    assert :ok = ToolContract.validate_module(module, envelope, source)
  end
end
