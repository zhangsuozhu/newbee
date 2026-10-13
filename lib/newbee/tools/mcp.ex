defmodule Newbee.Tools.Mcp do
  @moduledoc """
  MCP client: call tools on configured stdio MCP servers (e.g., rea).

  Declare servers in `~/.newbee/mcp.json` (override the path with the `NEWBEE_MCP_CONFIG`
  environment variable):

      {"mcpServers": {"rea": {"command": "/home/me/.local/bin/rea", "args": ["mcp"], "env": {"GHIDRA_INSTALL_DIR": "/opt/ghidra"}}}}

  A server entry takes `command` (required), `args`, `env`, plus optional `timeout_ms`
  (default call timeout) and `initialize_timeout_ms`. Sessions are kept per server name
  until `close/1` or application restart. MCP session state — for example a binary
  opened in rea — lives in that connection, so keep related calls on the same live
  session and use `close/1` to discard it deliberately.

  ## Functions
  - `servers()` — configured servers with their live-session flag.
  - `tools(name)` — `tools/list` for one server (starts its session when needed).
  - `call(name, tool, arguments, opts \\\\ [])` — `tools/call`; opts: `timeout: ms`. MCP tool-level failures arrive inside `{:ok, result}` as `%{"isError" => true}`.
  - `close(name)` — close one server session; drops its MCP state.

  ## Runnable example
      {:ok, servers} = Newbee.Tools.Mcp.servers()
      {:ok, tools} = Newbee.Tools.Mcp.tools("rea")
      {:ok, result} = Newbee.Tools.Mcp.call("rea", "analyze", %{"path" => "/bin/true"}, timeout: 240_000)
      :ok = Newbee.Tools.Mcp.close("rea")
  """

  @registry Newbee.Tools.Mcp.Registry
  @session_sup Newbee.Tools.Mcp.SessionSup
  @default_call_timeout 300_000

  alias Newbee.Tools.Mcp.Session

  @doc "Configured MCP servers: `{:ok, [%{name: name, command: command, connected: boolean}]}`."
  def servers do
    with {:ok, servers} <- load_config() do
      {:ok,
       Enum.map(servers, fn {name, config} ->
         %{name: name, command: config.command, connected: session_pid(name) != nil}
       end)}
    end
  end

  @doc "List one server's MCP tools. Starts the server session on first use."
  def tools(name) when is_binary(name) do
    with {:ok, config} <- fetch_server(name) do
      with_session(name, config, &Session.list_tools/1)
    end
  end

  @doc "Call one MCP tool. `opts: [timeout: ms]`; tool-level failures stay inside `{:ok, result}` with `\"isError\" => true`."
  def call(name, tool, arguments, opts \\ []) do
    with :ok <- validate_call(name, tool, arguments),
         {:ok, config} <- fetch_server(name) do
      timeout = Keyword.get(opts, :timeout) || config.timeout_ms || @default_call_timeout
      with_session(name, config, fn pid -> Session.call_tool(pid, tool, arguments, timeout) end)
    end
  end

  @doc "Close one server session (drops its MCP session state). `:ok` even when no session is open."
  def close(name) when is_binary(name) do
    case session_pid(name) do
      nil -> :ok
      pid -> Session.close(pid)
    end
  end

  # :noproc 表示请求从未送达（无副作用），可安全地换一条新会话重试一次。
  defp with_session(name, config, fun, retry? \\ true) do
    case ensure_session(name, config) do
      {:ok, pid} ->
        try do
          fun.(pid)
        catch
          :exit, {:noproc, _reason} when retry? ->
            with_session(name, config, fun, false)

          :exit, reason ->
            {:error, %{reason: :session_exit, detail: inspect(reason)}}
        end

      error ->
        error
    end
  end

  defp validate_call(name, tool, arguments) do
    cond do
      not is_binary(name) or name == "" ->
        {:error, %{reason: :invalid_argument, argument: :name, detail: "server name is required"}}

      not is_binary(tool) or tool == "" ->
        {:error, %{reason: :invalid_argument, argument: :tool, detail: "tool name is required"}}

      not is_map(arguments) ->
        {:error, %{reason: :invalid_argument, argument: :arguments, detail: "arguments must be an object"}}

      true ->
        :ok
    end
  end

  # ---------- config ----------

  defp load_config do
    path = config_path()

    case File.read(path) do
      {:ok, content} ->
        with {:ok, json} <- decode_config(content, path),
             {:ok, servers} <- validate_servers(json, path) do
          {:ok, servers}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, %{reason: :config_unreadable, path: path, detail: inspect(reason)}}
    end
  end

  defp config_path do
    Application.get_env(:newbee, :mcp_config_path) ||
      System.get_env("NEWBEE_MCP_CONFIG") ||
      Path.join(System.user_home!(), ".newbee/mcp.json")
  end

  defp decode_config(content, path) do
    case Jason.decode(content) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, %{reason: :invalid_config, path: path, detail: Exception.message(error)}}
    end
  end

  defp validate_servers(%{"mcpServers" => servers}, _path) when is_map(servers) do
    Enum.reduce_while(servers, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case validate_server(name, spec) do
        {:ok, config} -> {:cont, {:ok, Map.put(acc, name, config)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_servers(_json, path) do
    {:error, %{reason: :invalid_config, path: path, detail: "expected an object with an mcpServers table"}}
  end

  defp validate_server(name, %{} = spec) do
    command = Map.get(spec, "command")
    args = Map.get(spec, "args", [])
    env = Map.get(spec, "env", %{})
    timeout_ms = Map.get(spec, "timeout_ms")
    init_timeout_ms = Map.get(spec, "initialize_timeout_ms")

    cond do
      not is_binary(command) or command == "" ->
        {:error, %{reason: :invalid_config, server: name, detail: "command must be a non-empty string"}}

      not (is_list(args) and Enum.all?(args, &is_binary/1)) ->
        {:error, %{reason: :invalid_config, server: name, detail: "args must be a list of strings"}}

      not (is_map(env) and Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end)) ->
        {:error, %{reason: :invalid_config, server: name, detail: "env must map strings to strings"}}

      not (is_nil(timeout_ms) or (is_integer(timeout_ms) and timeout_ms > 0)) ->
        {:error, %{reason: :invalid_config, server: name, detail: "timeout_ms must be a positive integer"}}

      not (is_nil(init_timeout_ms) or (is_integer(init_timeout_ms) and init_timeout_ms > 0)) ->
        {:error, %{reason: :invalid_config, server: name, detail: "initialize_timeout_ms must be a positive integer"}}

      true ->
        {:ok,
         %{
           name: name,
           command: command,
           args: args,
           env: env,
           timeout_ms: timeout_ms,
           init_timeout_ms: init_timeout_ms
         }}
    end
  end

  defp validate_server(name, _spec) do
    {:error, %{reason: :invalid_config, server: name, detail: "server entry must be an object"}}
  end

  defp fetch_server(name) do
    with {:ok, servers} <- load_config() do
      case Map.fetch(servers, name) do
        {:ok, config} ->
          {:ok, config}

        :error ->
          {:error, %{reason: :unknown_server, name: name, configured: Map.keys(servers) |> Enum.sort()}}
      end
    end
  end

  # ---------- session lifecycle ----------

  defp ensure_session(name, config) do
    case session_pid(name) do
      nil ->
        spec = {Session, %{name: name, config: config, via: {:via, Registry, {@registry, name}}}}

        case DynamicSupervisor.start_child(@session_sup, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, {:session_start_failed, reason}} ->
            {:error, %{reason: :session_start_failed, server: name, detail: reason}}

          {:error, reason} ->
            {:error, %{reason: :session_start_failed, server: name, detail: inspect(reason)}}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp session_pid(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      _ -> nil
    end
  end
end
