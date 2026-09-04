defmodule Newbee.Web.ApiDebugTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  defp post_rpc(method, payload \\ %{}) do
    body =
      Jason.encode!(%{
        "rpcId" => "test-debug",
        "method" => method,
        "payload" => payload
      })

    conn =
      Plug.Test.conn(:post, "/api/" <> method, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Newbee.Web.Router.call(conn, @opts)
  end

  defp ok!(conn) do
    assert conn.status == 200
    %{"result" => %{"ok" => ok}} = Jason.decode!(conn.resp_body)
    ok
  end

  setup do
    prev = Newbee.LLM.HttpDebug.enabled?()
    Newbee.LLM.HttpDebug.clear()

    on_exit(fn ->
      Newbee.LLM.HttpDebug.clear()
      Newbee.LLM.HttpDebug.set_enabled(prev)
    end)

    :ok
  end

  test "debug.status returns enabled flag" do
    ok = ok!(post_rpc("debug.status"))
    assert Map.has_key?(ok, "enabled")
    assert Map.has_key?(ok, "count")
  end

  test "debug.setEnabled toggles recording" do
    %{"enabled" => true} = ok!(post_rpc("debug.setEnabled", %{"enabled" => true}))
    assert Newbee.LLM.HttpDebug.enabled?()
    %{"enabled" => false} = ok!(post_rpc("debug.setEnabled", %{"enabled" => false}))
    refute Newbee.LLM.HttpDebug.enabled?()
  end

  test "debug.list and debug.get roundtrip then clear" do
    ok!(post_rpc("debug.setEnabled", %{"enabled" => true}))

    id =
      Newbee.LLM.HttpDebug.start_exchange(%{
        session_id: "rpc-test",
        model: "m",
        base_url: "https://x",
        endpoint: "/chat/completions",
        method: "POST",
        url: "https://x/chat",
        api: "chat",
        req_headers: [{"authorization", "Bearer sk-abcdef1234567890"}],
        req_body: %{hello: "world"}
      })

    Newbee.LLM.HttpDebug.finish_current({:ok, %{"content" => "hi"}, %{}})

    %{"entries" => entries} = ok!(post_rpc("debug.list", %{"limit" => 10, "since" => 0}))
    assert Enum.any?(entries, &(&1["id"] == id))

    %{"entry" => entry} = ok!(post_rpc("debug.get", %{"id" => id}))
    assert entry["req_body"] =~ "world"
    [[_, auth]] = Enum.filter(entry["req_headers"], fn [h, _] -> h == "authorization" end)
    refute auth =~ "abcdef1234567890"

    %{"cleared" => true} = ok!(post_rpc("debug.clear"))
    %{"entries" => []} = ok!(post_rpc("debug.list", %{"limit" => 10, "since" => 0}))

    ok!(post_rpc("debug.setEnabled", %{"enabled" => false}))
  end

  test "debug.get unknown id returns not_found" do
    conn = post_rpc("debug.get", %{"id" => 9_999_999_999})
    assert conn.status == 200
    %{"result" => %{"error" => err}} = Jason.decode!(conn.resp_body)
    assert err["code"] == "not_found"
  end
end
