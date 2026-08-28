defmodule Newbee.Environment.ToolGovernanceIntegrationTest do
  use ExUnit.Case, async: false

  alias Newbee.Agent.Adapter
  alias Newbee.Environment.{PluginManager, Release, ToolContract, Verifier}

  defp bad_source do
    """
    defmodule Demo.GovernanceBad do
      @behaviour Newbee.Environment.PluginContract
      def id, do: "tool.governance_bad"
      def version, do: "1.0.0"
      def dependencies, do: []
      def describe, do: %{kind: :tool}
      def run(input), do: input
    end
    """
  end

  test "Adapter rejects malformed tool proposal before candidate lifecycle" do
    proposal = %{
      "type" => "tool",
      "id" => "governance_bad",
      "name" => "GovernanceBad",
      "source" => bad_source()
    }

    assert {:error, {:contract_violation, reasons}} = Adapter.proposal_to_release(proposal)
    assert inspect(reasons) =~ "tool_contract"
  end

  test "valid Adapter proposal carries governance metadata into release attrs" do
    source = ToolContract.template(Demo.GovernanceGood, "tool.governance_good")

    proposal = %{
      "type" => "tool",
      "id" => "governance_good",
      "name" => "GovernanceGood",
      "source" => source
    }

    assert {:ok, attrs} = Adapter.proposal_to_release(proposal)
    assert attrs.kind == :tool
    assert attrs.usage == "one-line purpose"
    assert attrs.capabilities == []
    assert attrs.effects == []
  end

  test "PluginManager rejects a bad tool release even when Adapter is bypassed" do
    release =
      Release.new(%{
        plugin_id: "tool.governance_bad",
        kind: :tool,
        source_files: %{"bad.ex" => bad_source()}
      })

    assert {:error, {:contract_violation, errors}} = PluginManager.static_validate(release)
    assert inspect(errors) =~ "tool_contract"
  end

  test "Verifier static layer cannot vote around a bad tool contract" do
    release =
      Release.new(%{
        plugin_id: "tool.governance_bad",
        kind: :tool,
        source_files: %{"bad.ex" => bad_source()}
      })

    result = Verifier.static_layer(release)
    refute result.passed
    assert result.reason =~ "tool_contract"
  end

  test "builtin gate passes the current registry" do
    assert :ok = ToolContract.validate_builtins()
  end
end
