defmodule Newbee.Web.AuthSecurityBoundaryTest do
  use ExUnit.Case, async: false
  alias Newbee.Web.{Auth, Router}

  @opts Router.init([])

  setup do
    sandbox = Newbee.TestSupport.WebTmpHome.enter("auth_security_boundary")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)
    Auth.create_table()
    if :ets.whereis(:newbee_web_auth) != :undefined, do: :ets.delete_all_objects(:newbee_web_auth)
    Router.set_bind_ip({0, 0, 0, 0})
    :ok = Auth.set_password("hunter22")
    on_exit(fn -> Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  defp rpc(method, payload, token \\ nil) do
    conn = Plug.Test.conn(:post, "/api/" <> method, Jason.encode!(%{rpcId: "t", method: method, payload: payload}))
    conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  test "session RPC rejects traversal ids" do
    {:ok, token} = Auth.issue_token()

    for method <- ["session.history", "session.resume", "session.delete"] do
      response = rpc(method, %{sessionId: "../../tmp/escape"}, token)
      assert response.status == 200
      error = Jason.decode!(response.resp_body)["result"]["error"]
      assert error["code"] in ["bad_request", "unknown_method"]
    end

    assert Jason.decode!(rpc("session.delete", %{sessionId: "../../tmp/escape"}, token).resp_body)["result"]["error"][
             "code"
           ] == "bad_request"
  end

  test "webauthn registration and deletion require host login" do
    {:ok, token} = Auth.issue_token()

    for method <- ["webauthn.register_challenge", "webauthn.register", "webauthn.delete"] do
      response = rpc(method, %{})
      assert response.status == 401 or Jason.decode!(response.resp_body)["result"]["error"]["code"] == "unauthorized"
    end

    assert Jason.decode!(rpc("webauthn.register_challenge", %{}, token).resp_body)["result"]["ok"]
  end

  test "locked password login is rejected before password verification" do
    ip = {10, 1, 2, 3}
    for _ <- 1..5, do: Auth.record_fail(ip)

    body = %{
      rpcId: "t",
      method: "auth.login",
      payload: %{password: "hunter22", captchaId: "x", captcha: "y", __remote_ip__: ip}
    }

    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(body) end
    assert {:error, _ms} = Auth.check_rate(ip)
  end
end
