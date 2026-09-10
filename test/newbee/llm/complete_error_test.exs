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
end
