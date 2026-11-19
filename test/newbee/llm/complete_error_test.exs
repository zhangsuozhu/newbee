defmodule Newbee.LLM.CompleteErrorTest do
  use ExUnit.Case, async: true
  alias Newbee.LLM.Client

  test "provider 4xx responses are errors, not uncaught case clauses" do
    for status <- [400, 401, 403, 404, 422] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(%{error: "model unavailable"}))
      end)

      client =
        Client.new(
          provider: "fixture",
          model: "fixture",
          api_key: "fixture-only",
          base_url: "http://fixture.invalid",
          context_window: 32000,
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert {:error, {:http_error, ^status, _}} = Client.complete(client, [%{role: "user", content: "test"}])
    end
  end

  test "clients created before the tls field keep the default transport" do
    for api <- ["openai-completions", "openai-responses", "anthropic"] do
      client =
        Client.new(
          api: api,
          api_key: "fixture-only",
          base_url: "http://fixture.invalid",
          req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end]
        )
        |> legacy_client()

      assert Client.req_transport(client) == Client.req_transport(Client.new())
      assert Client.tls_finch_opt(client) == []
      assert {:error, {:http_error, 401, _}} = Client.complete(client, [%{role: "user", content: "test"}])
      assert {:error, reason} = Client.stream_chat(client, [%{role: "user", content: "test"}])
      refute match?({:stream_error, _, _}, reason)
    end
  end

  test "worker function clause errors never print argument values from old Client maps" do
    key = "fixture-secret-for-legacy-client"
    client = Client.new(api_key: key, base_url: "http://fixture.invalid") |> legacy_client()
    plug = fn _conn -> raise FunctionClauseError, module: __MODULE__, function: :fixture, arity: 1, args: [client] end
    client = Map.put(client, :req_options, plug: plug)

    assert {:error, {:stream_error, text, ""}} = Client.stream_chat(client, [%{role: "user", content: "test"}])
    assert text =~ "FunctionClauseError"
    refute text =~ key
    refute text =~ "api_key:"
  end

  test "worker exception messages redact the active API key" do
    key = "fixture-secret-for-error-message"

    client =
      Client.new(
        api_key: key,
        base_url: "http://fixture.invalid",
        req_options: [plug: fn _ -> raise "provider failure: " <> key end]
      )

    assert {:error, {:stream_error, text, ""}} = Client.stream_chat(client, [%{role: "user", content: "test"}])
    assert text =~ "[REDACTED]"
    assert text =~ "RuntimeError"
    refute text =~ key
  end

  # Simulate a Client retained in memory or restored from an older serialized term.
  defp legacy_client(client) do
    client |> Map.delete(:tls) |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end
end
