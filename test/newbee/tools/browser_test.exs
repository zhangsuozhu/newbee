defmodule Newbee.Tools.BrowserTest do
  use ExUnit.Case, async: false

  alias Newbee.Environment.{PluginContract, ToolContract}
  alias Newbee.Tools.Browser

  test "browser is registered as a governed builtin tool" do
    assert Newbee.Plugins.module_for_plugin_id("tool.browser") == Browser
    assert %{capabilities: capabilities} = Newbee.Plugins.builtin("tool.browser")
    assert :browser in capabilities
    assert PluginContract.valid_static?(Browser)
    assert :ok = ToolContract.validate_builtin(Browser)
  end

  test "invalid backend and timeout fail before starting a browser" do
    assert {:error, %{reason: :invalid_backend}} = Browser.run(%{backend: "unknown"})
    assert {:error, %{reason: :invalid_timeout}} = Browser.run(%{timeout: 100})
    assert {:error, %{reason: :invalid_request}} = Browser.run(:not_a_request)
  end

  test "non JSON request values return a recoverable error" do
    assert {:error, %{reason: :invalid_request, hint: hint}} =
             Browser.run(%{actions: [%{action: {:not_json, 1}}]})

    assert hint =~ "JSON"
  end
end
