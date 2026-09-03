defmodule Newbee.Web.EvolutionExplainTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Coordinator

  @opts Newbee.Web.Router.init([])

  setup do
    coordinator = start_coordinator!()
    {:ok, coordinator: coordinator}
  end

  test "evolution.status 透出 brief；explain 回退模板也不崩", %{coordinator: coordinator} do
    {:ok, change} =
      Coordinator.propose_change(coordinator, %{
        reason: "adapter: distill-stream-chat-hotpath",
        evidence: [%{proposal: "distill-stream-chat-hotpath", type: "tool"}],
        author_agent: :adapter
      })

    status = post_rpc("evolution.status", %{}) |> ok!()
    card = Enum.find(status["changes"], &(&1["change_id"] == change.change_id))
    assert is_map(card["brief"])
    assert is_binary(card["brief"]["title"])
    refute card["brief"]["title"] =~ "distill"

    # 无 LLM 凭据时 explain 走模板回退，但接口成功且落盘
    explained = post_rpc("evolution.explain", %{"changeId" => change.change_id}) |> ok!()
    assert explained["change_id"] == change.change_id
    assert is_binary(explained["brief"]["found"])
    assert explained["brief"]["fallback"] == true

    assert %{"result" => %{"error" => %{"code" => "unknown_change"}}} =
             post_rpc("evolution.explain", %{"changeId" => "chg_missing"})

    assert %{"result" => %{"error" => %{"code" => "invalid_change"}}} =
             post_rpc("evolution.explain", %{})
  end

  defp post_rpc(method, payload) do
    body = Jason.encode!(%{"rpcId" => "test", "method" => method, "payload" => payload})

    Plug.Test.conn(:post, "/api/" <> method, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Newbee.Web.Router.call(@opts)
    |> then(fn conn -> Jason.decode!(conn.resp_body) end)
  end

  defp ok!(%{"result" => %{"ok" => value}}), do: value
end
