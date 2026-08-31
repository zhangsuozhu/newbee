defmodule Newbee.Web.QuickAccessTest do
  @moduledoc "手机免登录扫码：一次性码 + 换 token + 过期 + API 集成（免认证 redeem）。"
  use ExUnit.Case, async: false

  alias Newbee.Web.{QuickAccess, Auth}

  @opts Newbee.Web.Router.init([])

  setup do
    sandbox = Newbee.TestSupport.WebTmpHome.enter("quick_access_test")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)

    QuickAccess.create_table()
    if :ets.whereis(:newbee_web_quick_access) != :undefined, do: :ets.delete_all_objects(:newbee_web_quick_access)
    if :ets.whereis(:newbee_web_auth) != :undefined, do: :ets.delete_all_objects(:newbee_web_auth)
    on_exit(fn -> Newbee.Web.Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  describe "QuickAccess 状态机" do
    test "完整流程：发码 → 兑换 token，码一次性" do
      {:ok, %{code: code, ttl_ms: ttl}} = QuickAccess.create(%{ip: "9.9.9.9"})
      assert is_binary(code) and byte_size(code) > 10
      assert ttl == QuickAccess.ttl_ms()

      {:ok, token} = QuickAccess.redeem(code)
      assert is_binary(token)
      assert :ok = Auth.check_token(token)

      # 一次性：再兑即失效
      assert {:error, "not_found", _} = QuickAccess.redeem(code)
    end

    test "无效码 / 已用码" do
      assert {:error, "not_found", _} = QuickAccess.redeem("bogus")
      {:ok, %{code: code}} = QuickAccess.create()
      {:ok, _} = QuickAccess.redeem(code)
      assert {:error, "not_found", _} = QuickAccess.redeem(code)
    end

    test "过期码" do
      {:ok, %{code: code}} = QuickAccess.create()
      # 手动拨过期
      [{k, rec}] = :ets.lookup(:newbee_web_quick_access, {:qk, code})
      :ets.insert(:newbee_web_quick_access, {k, %{rec | expires: System.system_time(:millisecond) - 1000}})
      assert {:error, "expired", _} = QuickAccess.redeem(code)
      # 过期码焚毁后不可再用
      assert {:error, "not_found", _} = QuickAccess.redeem(code)
    end
  end

  describe "路由集成（远程绑定强制认证）" do
    setup do
      Newbee.Web.Router.set_bind_ip({0, 0, 0, 0})
      :ok = Auth.set_password("hunter22")
      :ok
    end

    defp post_rpc(method, payload, token \\ nil) do
      body = Jason.encode!(%{"rpcId" => "t1", "method" => method, "payload" => payload})

      conn =
        Plug.Test.conn(:post, "/api/" <> method, body)
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn
      Newbee.Web.Router.call(conn, @opts)
    end

    test "redeem 免 token（远程）可用，换到合法 token" do
      {:ok, %{code: code}} = QuickAccess.create()
      conn = post_rpc("quick_access.redeem", %{code: code})
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["ok"]["token"] != nil
      assert :ok = Auth.check_token(body["result"]["ok"]["token"])
    end

    test "create 需要登录（远程）" do
      conn = post_rpc("quick_access.create", %{})
      assert conn.status == 401
    end

    test "create 带 token 成功" do
      {:ok, tok} = Auth.issue_token()
      conn = post_rpc("quick_access.create", %{}, tok)
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["ok"]["code"] != nil
      assert is_integer(body["result"]["ok"]["ttl_ms"])
    end

    test "redeem 失效码报错" do
      conn = post_rpc("quick_access.redeem", %{code: "no-such-code"})
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["error"]["code"] == "not_found"
    end
  end
end
