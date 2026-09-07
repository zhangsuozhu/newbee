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

  test "session and per-action budgets are validated before launching anything" do
    assert {:error, %{reason: :invalid_session}} = Browser.run(%{session: true})
    assert {:error, %{reason: :invalid_session}} = Browser.run(%{session: "new", backend: "screen"})
    assert {:error, %{reason: :invalid_action_timeout}} = Browser.run(%{action_timeout: 0})
    assert {:error, %{reason: :invalid_action_timeout}} = Browser.run(%{action_timeout: "1000"})
  end

  test "sessions reject absent identity, foreign roots, and expired handles" do
    assert {:error, %{reason: :invalid_context}} = Browser.run(%{session: "new"})
    root = File.cwd!()
    :ok = Newbee.Collaboration.Capability.register(self(), "browser-contract", root)
    {:ok, token} = Newbee.Collaboration.Capability.issue(self())
    Process.put({Newbee.Tools.Media, :capability}, token)
    assert {:error, %{reason: :session_expired}} = Browser.run(%{session: "expired-handle"})

    assert {:error, %{reason: :invalid_context}} =
             Newbee.Browser.run(token, Path.join(root, "other"), %{"session" => "new"})
  end

  test "global worker count is bounded before starting another browser" do
    root = File.cwd!()
    :ok = Newbee.Collaboration.Capability.register(self(), "browser-limit", root)
    {:ok, token} = Newbee.Collaboration.Capability.issue(self())
    Process.put({Newbee.Tools.Media, :capability}, token)

    pids =
      for _ <- 1..4 do
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Newbee.Browser.Sessions,
            {Newbee.Browser.Session, [root: root, runner: Path.expand("test/fixtures/browser_session.py")]}
          )

        pid
      end

    try do
      assert {:error, %{reason: :session_limit}} = Browser.run(%{session: "new"})
    after
      Enum.each(pids, &DynamicSupervisor.terminate_child(Newbee.Browser.Sessions, &1))
    end
  end

  test "idle_timeout is validated before launching anything" do
    assert {:error, %{reason: :invalid_idle_timeout}} =
             Browser.run(%{session: "new", idle_timeout: 5_000})

    assert {:error, %{reason: :invalid_idle_timeout}} =
             Browser.run(%{session: "new", idle_timeout: 3_600_000})

    assert {:error, %{reason: :invalid_idle_timeout}} =
             Browser.run(%{session: "new", idle_timeout: "60000"})
  end
end
