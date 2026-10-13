defmodule Newbee.Tools.McpTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 240_000

  alias Newbee.Tools.Mcp

  @fixture Path.expand("../../fixtures/mcp/fake_server.exs", __DIR__)

  setup do
    path = Path.join(System.tmp_dir!(), "newbee-mcp-test-#{System.unique_integer([:positive])}.json")
    write_config(path, %{"fake" => %{"command" => System.find_executable("elixir"), "args" => [@fixture]}})
    Application.put_env(:newbee, :mcp_config_path, path)

    on_exit(fn ->
      Mcp.close("fake")
      Mcp.close("bad")
      Application.delete_env(:newbee, :mcp_config_path)
      File.rm(path)
    end)

    :ok
  end

  defp write_config(path, servers) do
    File.write!(path, Jason.encode!(%{"mcpServers" => servers}))
  end

  test "servers/0 reports configured servers without starting sessions" do
    assert {:ok, [%{name: "fake", command: command, connected: false}]} = Mcp.servers()
    assert is_binary(command)
  end

  test "tools/1 lists tools and reports the live session" do
    assert {:ok, tools} = Mcp.tools("fake")
    assert Enum.any?(tools, &(&1["name"] == "echo"))
    assert {:ok, [%{name: "fake", connected: true}]} = Mcp.servers()
  end

  test "call/4 round-trips and keeps MCP session state across calls" do
    assert {:ok, %{"content" => [%{"text" => text}]}} = Mcp.call("fake", "echo", %{"x" => 1})
    assert Jason.decode!(text) == %{"echo" => %{"x" => 1}}

    assert {:ok, _result} = Mcp.call("fake", "state_set", %{"value" => 42})
    assert {:ok, %{"content" => [%{"text" => text2}]}} = Mcp.call("fake", "state_get", %{})
    assert Jason.decode!(text2) == %{"value" => 42}

    :ok = Mcp.close("fake")
    assert {:ok, %{"content" => [%{"text" => text3}]}} = Mcp.call("fake", "state_get", %{})
    assert Jason.decode!(text3) == %{"value" => 0}
  end

  test "tool-level failures arrive inside an isError result" do
    assert {:ok, %{"isError" => true}} = Mcp.call("fake", "fail", %{})
  end

  test "unknown tool is an rpc error value" do
    assert {:error, %{reason: :rpc_error}} = Mcp.call("fake", "nope", %{})
  end

  test "timeout is a value and the session stays usable" do
    assert {:error, %{reason: :timeout}} = Mcp.call("fake", "sleep", %{"ms" => 1_500}, timeout: 250)
    assert {:ok, _result} = Mcp.call("fake", "echo", %{"after" => "timeout"})
  end

  test "unknown server and invalid arguments are values" do
    assert {:error, %{reason: :unknown_server}} = Mcp.call("nosuch", "x", %{})
    assert {:error, %{reason: :invalid_argument}} = Mcp.call("fake", "", %{})
    assert {:error, %{reason: :invalid_argument}} = Mcp.call("fake", "echo", :not_a_map)
  end

  test "malformed config is a value" do
    File.write!(Application.get_env(:newbee, :mcp_config_path), "{not json")
    assert {:error, %{reason: :invalid_config}} = Mcp.servers()
  end

  test "unstartable server command is a value" do
    path = Application.get_env(:newbee, :mcp_config_path)
    write_config(path, %{"bad" => %{"command" => "/nonexistent/newbee-mcp-test-binary"}})
    assert {:error, %{reason: :session_start_failed, server: "bad"}} = Mcp.tools("bad")
  end
end
