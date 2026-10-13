# Minimal MCP stdio server used by Newbee.Tools.Mcp tests.
# Reads newline-delimited JSON-RPC on stdin, writes newline-delimited JSON on stdout.
# Uses only OTP built-ins so it can run as a bare `elixir script.exs` child process.
defmodule FakeMcpServer do
  def run, do: loop(0)

  defp loop(count) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        case decode_line(line) do
          nil -> loop(count)
          message -> loop(handle(message, count))
        end
    end
  end

  defp decode_line(line) do
    :json.decode(String.trim(line))
  rescue
    _ -> nil
  end

  defp handle(%{"method" => "initialize", "id" => id}, count) do
    respond(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "fake", "version" => "9.9.9"}
      }
    })

    count
  end

  defp handle(%{"method" => "notifications/initialized"}, count), do: count

  defp handle(%{"method" => "tools/list", "id" => id}, count) do
    respond(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => [
          %{"name" => "echo", "description" => "Echo arguments", "inputSchema" => %{"type" => "object"}},
          %{"name" => "state_set", "description" => "Set session state", "inputSchema" => %{"type" => "object"}},
          %{"name" => "state_get", "description" => "Read session state", "inputSchema" => %{"type" => "object"}},
          %{"name" => "fail", "description" => "Fail as a tool error", "inputSchema" => %{"type" => "object"}},
          %{"name" => "sleep", "description" => "Sleep then reply", "inputSchema" => %{"type" => "object"}}
        ]
      }
    })

    count
  end

  defp handle(%{"method" => "tools/call", "id" => id, "params" => params}, count) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    case name do
      "echo" ->
        respond(ok(id, %{"echo" => arguments}))
        count

      "state_set" ->
        respond(ok(id, %{"value" => arguments["value"]}))
        arguments["value"]

      "state_get" ->
        respond(ok(id, %{"value" => count}))
        count

      "fail" ->
        respond(ok(id, %{"error" => "boom"}, true))
        count

      "sleep" ->
        Process.sleep(arguments["ms"] || 100)
        respond(ok(id, %{"slept" => true}))
        count

      other ->
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "unknown tool: #{inspect(other)}"}
        })

        count
    end
  end

  defp handle(_other, count), do: count

  defp ok(id, data, is_error \\ false) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => encode(data)}],
        "isError" => is_error
      }
    }
  end

  defp encode(term) do
    term |> :json.encode() |> IO.iodata_to_binary()
  end

  defp respond(message), do: IO.binwrite(:stdio, [:json.encode(message), "\n"])
end

FakeMcpServer.run()
