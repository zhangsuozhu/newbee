defmodule Newbee.Tools.Mcp.Session do
  @moduledoc false
  # 一条 MCP stdio 会话：持有 Port、做 JSON-RPC 帧与请求配对。
  # MCP 状态（如 rea 已打开的二进制）属于这条连接；关闭即丢弃。

  use GenServer
  require Logger

  @protocol_version "2025-06-18"
  @default_init_timeout 60_000
  @default_list_timeout 60_000
  @buffer_limit 64 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts.via)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def list_tools(pid), do: GenServer.call(pid, :list_tools, @default_list_timeout + 10_000)

  def call_tool(pid, tool, arguments, timeout)
      when is_binary(tool) and is_map(arguments) and is_integer(timeout) and timeout > 0 do
    GenServer.call(pid, {:call_tool, tool, arguments, timeout}, timeout + 10_000)
  end

  def server_info(pid), do: GenServer.call(pid, :server_info, 5_000)

  # 关闭并等待进程真正退出，避免“关闭后立刻重连”落在半死会话上。
  def close(pid) do
    ref = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :close, 10_000)
      catch
        :exit, _reason -> :ok
      end

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end

    result
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, command} <- resolve_command(opts.config.command),
         {:ok, port} <- open_port(command, opts.config) do
      state = %{
        name: opts.name,
        port: port,
        config: opts.config,
        buffer: "",
        next_id: 1,
        pending: %{},
        queue: [],
        status: :initializing,
        tools: nil,
        server_info: %{}
      }

      {:ok, send_initialize(state)}
    else
      {:error, reason} -> {:stop, {:session_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}

  def handle_call(_request, _from, %{status: :failed} = state) do
    {:reply, {:error, %{reason: :not_initialized}}, state}
  end

  def handle_call(:list_tools, _from, %{status: :ready, tools: tools} = state)
      when is_list(tools) do
    {:reply, {:ok, tools}, state}
  end

  def handle_call(:list_tools, from, %{status: :ready} = state) do
    {:noreply, dispatch(state, from, "tools/list", %{}, @default_list_timeout)}
  end

  def handle_call(:list_tools, from, state), do: {:noreply, enqueue(state, {:list_tools, from})}

  def handle_call({:call_tool, tool, arguments, timeout}, from, %{status: :ready} = state) do
    {:noreply, dispatch(state, from, "tools/call", %{"name" => tool, "arguments" => arguments}, timeout)}
  end

  def handle_call({:call_tool, tool, arguments, timeout}, from, state) do
    {:noreply, enqueue(state, {:call_tool, from, tool, arguments, timeout})}
  end

  def handle_call(:server_info, _from, state), do: {:reply, state.server_info, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > @buffer_limit do
      state = fail_all(state, {:error, %{reason: :buffer_overflow, limit: @buffer_limit}})
      {:stop, :normal, state}
    else
      {lines, rest} = split_lines(buffer)
      state = %{state | buffer: rest}
      {:noreply, Enum.reduce(lines, state, &handle_line/2)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = fail_all(state, {:error, %{reason: :server_exit, status: status}})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    state = fail_all(state, {:error, %{reason: :server_exit, status: :exit}})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: nil} = _entry, pending} ->
        state = state |> Map.put(:pending, pending) |> Map.put(:status, :failed)
        state = fail_queue(state, {:error, %{reason: :initialize_timeout}})
        {:stop, :normal, state}

      {%{from: from} = _entry, pending} ->
        GenServer.reply(from, {:error, %{reason: :timeout}})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(:stop_failed, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: _port} = state) do
    fail_all(state, {:error, %{reason: :closed}})
    if state.port && Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------- initialize ----------

  defp send_initialize(state) do
    id = state.next_id
    timeout = state.config.init_timeout_ms || @default_init_timeout
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)

    state =
      state
      |> Map.merge(%{next_id: id + 1})
      |> put_pending(id, %{from: nil, method: "initialize", timer: timer})

    send_message(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "newbee", "version" => "1.0.0"}
      }
    })
  end

  # ---------- request dispatch ----------

  defp dispatch(state, from, method, params, timeout) do
    id = state.next_id
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)

    state =
      state
      |> Map.put(:next_id, id + 1)
      |> put_pending(id, %{from: from, method: method, timer: timer})

    send_message(state, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp put_pending(state, id, entry), do: %{state | pending: Map.put(state.pending, id, entry)}
  defp enqueue(state, item), do: %{state | queue: state.queue ++ [item]}

  defp flush_queue(state) do
    state.queue
    |> Enum.reduce(state, fn
      {:list_tools, from}, acc ->
        dispatch(acc, from, "tools/list", %{}, @default_list_timeout)

      {:call_tool, from, tool, arguments, timeout}, acc ->
        dispatch(acc, from, "tools/call", %{"name" => tool, "arguments" => arguments}, timeout)
    end)
    |> Map.put(:queue, [])
  end

  # ---------- inbound frames ----------

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [single] ->
        {[], single}

      parts ->
        {complete, [rest]} = Enum.split(parts, -1)
        {complete, rest}
    end
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = msg} when is_integer(id) or is_binary(id) ->
        if Map.has_key?(msg, "result") or Map.has_key?(msg, "error") do
          resolve(state, id, msg)
        else
          respond_method_not_found(state, id)
        end

      {:ok, _notification} ->
        state

      {:error, _reason} ->
        Logger.debug("MCP session #{state.name}: dropping unparsable line")
        state
    end
  end

  defp resolve(state, id, msg) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{from: from, method: method, timer: timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)
        state = %{state | pending: pending}
        reply = reply_for(msg)

        if method == "initialize" and state.status == :initializing do
          case reply do
            {:ok, result} when is_map(result) ->
              state = %{state | status: :ready, server_info: Map.get(result, "serverInfo", %{})}
              flush_queue(send_notification(state, "notifications/initialized"))

            {:ok, _unexpected} ->
              init_failed(state, :invalid_initialize_result)

            {:error, reason} ->
              init_failed(state, reason)
          end
        else
          state =
            case {method, reply} do
              {"tools/list", {:ok, %{"tools" => tools}}} when is_list(tools) ->
                %{state | tools: tools}

              _ ->
                state
            end

          if from, do: GenServer.reply(from, format_reply(method, reply))
          state
        end
    end
  end

  defp init_failed(state, reason) do
    state = %{state | status: :failed}
    state = fail_queue(state, {:error, %{reason: :initialize_failed, detail: reason}})
    send(self(), :stop_failed)
    state
  end

  defp reply_for(%{"error" => error}), do: {:error, %{reason: :rpc_error, error: error}}
  defp reply_for(%{"result" => result}), do: {:ok, result}
  defp reply_for(_msg), do: {:error, %{reason: :invalid_response}}

  defp format_reply("tools/list", {:ok, %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
  defp format_reply("tools/list", {:ok, _other}), do: {:error, %{reason: :invalid_response}}
  defp format_reply(_method, reply), do: reply

  defp respond_method_not_found(state, id) do
    send_message(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "method not supported by the newbee MCP client"}
    })
  end

  defp send_notification(state, method) do
    send_message(state, %{"jsonrpc" => "2.0", "method" => method})
  end

  # ---------- failure ----------

  defp fail_all(state, error) do
    state =
      Enum.reduce(state.pending, state, fn {_id, entry}, acc ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        if entry.from, do: GenServer.reply(entry.from, error)
        acc
      end)

    state = %{state | pending: %{}, buffer: ""}
    fail_queue(state, error)
  end

  defp fail_queue(state, error) do
    Enum.each(state.queue, fn
      {:list_tools, from} -> GenServer.reply(from, error)
      {:call_tool, from, _tool, _arguments, _timeout} -> GenServer.reply(from, error)
    end)

    %{state | queue: []}
  end

  # ---------- port ----------

  defp resolve_command(command) do
    cond do
      String.contains?(command, "/") ->
        if File.exists?(command), do: {:ok, command}, else: {:error, :command_not_found}

      true ->
        case System.find_executable(command) do
          nil -> {:error, :command_not_found}
          path -> {:ok, path}
        end
    end
  end

  defp open_port(command, config) do
    args = Enum.map(config.args, &String.to_charlist/1)

    port_options =
      [:binary, :exit_status, {:args, args}]
      |> maybe_env(config.env)

    try do
      {:ok, Port.open({:spawn_executable, String.to_charlist(command)}, port_options)}
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp maybe_env(options, env) when map_size(env) == 0, do: options

  defp maybe_env(options, env) do
    list = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    [{:env, list} | options]
  end

  defp send_message(%{port: port} = state, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
    state
  end
end
