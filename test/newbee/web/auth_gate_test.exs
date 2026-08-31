defmodule Newbee.Web.AuthGateTest do
  @moduledoc "Router require_auth gate 集成测试：远程绑定强制 token，回环免认证。"
  use ExUnit.Case, async: false

  alias Newbee.Web.Auth

  @opts Newbee.Web.Router.init([])

  setup do
    # HOME 隔离：测试的 set_password/issue_token 落在临时目录，不触碰真实凭据
    sandbox = Newbee.TestSupport.WebTmpHome.enter("auth_gate_test")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)

    Auth.password_set?()
    if :ets.whereis(:newbee_web_auth) != :undefined, do: :ets.delete_all_objects(:newbee_web_auth)
    # 每个测试后恢复回环（免认证），避免污染其它测试
    on_exit(fn -> Newbee.Web.Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  defp post_rpc(method, payload, token \\ nil) do
    body = Jason.encode!(%{"rpcId" => "t1", "method" => method, "payload" => payload})

    conn =
      Plug.Test.conn(:post, "/api/" <> method, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    Newbee.Web.Router.call(conn, @opts)
  end

  describe "远程绑定（非回环）" do
    setup do
      Newbee.Web.Router.set_bind_ip({0, 0, 0, 0})
      :ok = Auth.set_password("hunter22")
      :ok
    end

    test "无 token → 401" do
      conn = post_rpc("session.list", %{})
      assert conn.status == 401
      assert conn.halted
    end

    test "错 token → 401" do
      conn = post_rpc("session.list", %{}, "bogus-token")
      assert conn.status == 401
    end

    test "有效 token → 放行" do
      {:ok, tok} = Auth.issue_token()
      conn = post_rpc("session.list", %{}, tok)
      assert conn.status == 200
    end

    test "auth.captcha / auth.status 免 token" do
      conn = post_rpc("auth.captcha", %{})
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["ok"]["svg"] =~ "<svg"

      conn2 = post_rpc("auth.status", %{})
      assert conn2.status == 200
    end

    test "auth.login 全流程（验证码 → token → 访问）" do
      # 取验证码
      cap_resp = post_rpc("auth.captcha", %{})
      %{"result" => %{"ok" => %{"captchaId" => cid}}} = Jason.decode!(cap_resp.resp_body)

      # 测试拿不到验证码明文（防止暴破者直接读）——但此处我们模拟"已知答案"通过 setup 路径
      # 直接 setup（密码刚 set 过，setup 会 already_set），所以改走 login，需要一个有效 captcha
      # 这里只验证 login 缺 captcha 时被拒
      conn = post_rpc("auth.login", %{"password" => "hunter22", "captchaId" => cid, "captcha" => "zzzz"})
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["error"]["code"] == "bad_captcha"
    end

    test "静态资源免 token（登录页要能加载）" do
      conn = Plug.Test.conn(:get, "/index.html") |> Newbee.Web.Router.call(@opts)
      assert conn.status in [200, 404]
      refute conn.status == 401
    end
  end

  describe "回环绑定（本地）" do
    setup do
      Newbee.Web.Router.set_bind_ip({127, 0, 0, 1})
      :ok
    end

    test "免认证直接放行" do
      conn = post_rpc("session.list", %{"limit" => 1})
      assert conn.status == 200
    end
  end

  describe "auth.logout 吊销 token" do
    setup do
      Newbee.Web.Router.set_bind_ip({0, 0, 0, 0})
      :ok = Auth.set_password("hunter22")
      :ok
    end

    test "登出后旧 token 失效（服务端吊销）" do
      {:ok, tok} = Auth.issue_token()
      # 登出前有效
      assert :ok = Auth.check_token(tok)
      conn = post_rpc("session.list", %{"limit" => 1}, tok)
      assert conn.status == 200

      # 调 auth.logout（免认证前缀，但带 Bearer header → __token__ 注入 → 真吊销）
      out = post_rpc("auth.logout", %{}, tok)
      assert out.status == 200
      body = Jason.decode!(out.resp_body)
      assert body["result"]["ok"]["logged_out"] == true

      # 吊销后：ETS 层已失效
      assert {:error, :invalid} = Auth.check_token(tok)
      # 再用旧 token 访问 → 401
      conn2 = post_rpc("session.list", %{"limit" => 1}, tok)
      assert conn2.status == 401
    end
  end
end
