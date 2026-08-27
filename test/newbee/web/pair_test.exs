defmodule Newbee.Web.PairTest do
  @moduledoc "扫码授权配对：状态机 + 配对码一次性 + token 一次性 + 过期 + 来源展示 + 路由集成。"
  use ExUnit.Case, async: false

  alias Newbee.Web.{Pair, Auth}

  @opts Newbee.Web.Router.init([])

  setup do
    sandbox = Newbee.TestSupport.WebTmpHome.enter("pair_test")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)

    Pair.create_table()
    if :ets.whereis(:newbee_web_pair) != :undefined, do: :ets.delete_all_objects(:newbee_web_pair)
    if :ets.whereis(:newbee_web_auth) != :undefined, do: :ets.delete_all_objects(:newbee_web_auth)
    on_exit(fn -> Newbee.Web.Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  describe "Pair 状态机" do
    test "完整流程 pending→scanned→approved，token 一次性" do
      {:ok, %{pairing_id: pid, code: code}} = Pair.create(%{ua: "Chrome", ip: "10.0.0.2"})
      assert pid != code
      assert {:ok, %{status: "pending"}} = Pair.status(pid)

      # 手机扫码消费配对码 → scanned + 展示信息
      {:ok, info} = Pair.consume_code(code)
      assert info.pairing_id == pid
      assert info.ua == "Chrome"
      assert info.ip == "10.0.0.2"
      assert {:ok, %{status: "scanned"}} = Pair.status(pid)

      # confirm → approved + token
      {:ok, %{approved: true}} = Pair.confirm(pid, %{ua: "iPhone Safari"})
      {:ok, fin} = Pair.status(pid)
      assert fin.status == "approved"
      assert is_binary(fin.token)
      assert :ok = Auth.check_token(fin.token)

      # token 一次性：再取即焚
      assert {:error, "not_found", _} = Pair.status(pid)
    end

    test "配对码一次性：二次消费即失效" do
      {:ok, %{code: code}} = Pair.create()
      {:ok, _} = Pair.consume_code(code)
      assert {:error, "not_found", _} = Pair.consume_code(code)
    end

    test "pending 态不能 confirm（手机还没扫码核对码）" do
      {:ok, %{pairing_id: pid}} = Pair.create()
      assert {:error, "bad_state", _} = Pair.confirm(pid)
    end

    test "无效配对码 / 无效 pairing_id" do
      assert {:error, "not_found", _} = Pair.consume_code("bogus")
      assert {:error, "not_found", _} = Pair.status("bogus")
      assert {:error, "not_found", _} = Pair.confirm("bogus")
    end

    test "deny 路径：手机拒绝 → 电脑轮询到 denied 并焚毁" do
      {:ok, %{pairing_id: pid, code: code}} = Pair.create()
      {:ok, _} = Pair.consume_code(code)
      {:ok, %{denied: true}} = Pair.deny(pid)
      assert {:ok, %{status: "denied"}} = Pair.status(pid)
      # denied 一次性：再查即焚
      assert {:error, "not_found", _} = Pair.status(pid)
    end

    test "过期配对：消费码提示过期" do
      {:ok, %{pairing_id: pid, code: code}} = Pair.create()
      # 手动把 expires 拨到过去
      [{k, p}] = :ets.lookup(:newbee_web_pair, {:pair, pid})
      :ets.insert(:newbee_web_pair, {k, %{p | expires: System.system_time(:millisecond) - 1000}})
      assert {:error, "expired", _} = Pair.consume_code(code)
      assert {:error, "not_found", _} = Pair.status(pid)
    end

    test "status 对 pending/scanned 不回 token" do
      {:ok, %{pairing_id: pid, code: code}} = Pair.create()
      {:ok, st} = Pair.status(pid)
      refute Map.has_key?(st, :token)
      {:ok, _} = Pair.consume_code(code)
      {:ok, st2} = Pair.status(pid)
      refute Map.has_key?(st2, :token)
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
        |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0 TestBrowser")

      conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn
      Newbee.Web.Router.call(conn, @opts)
    end

    test "pair.* 端点免 token（远程）也能调" do
      conn = post_rpc("pair.create", %{})
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"result" => %{"ok" => %{"pairing_id" => _, "code" => _}}} = body
    end

    test "GET /pair?c= 渲染授权页（含配对信息）" do
      %{"result" => %{"ok" => %{"code" => code}}} =
        post_rpc("pair.create", %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()

      conn = Plug.Test.conn(:get, "/pair?c=" <> code) |> Newbee.Web.Router.call(@opts)
      assert conn.status == 200
      assert conn.resp_body =~ "登录授权"
      assert conn.resp_body =~ "pair.confirm"
      # 授权页内嵌 pairing_id（JSON 字符串）
      assert conn.resp_body =~ "window.PAIRING_ID"
    end

    test "GET /pair 无效码渲染错误页" do
      conn = Plug.Test.conn(:get, "/pair?c=bogus-code") |> Newbee.Web.Router.call(@opts)
      assert conn.status == 200
      assert conn.resp_body =~ "无法完成授权"
    end

    test "GET /pair 免 token（手机扫码直达）" do
      conn = Plug.Test.conn(:get, "/pair?c=whatever") |> Newbee.Web.Router.call(@opts)
      refute conn.status == 401
    end

    test "全链路 HTTP：创建→扫码页→confirm→status 取 token" do
      # 电脑：创建配对
      %{"result" => %{"ok" => %{"pairing_id" => pid, "code" => code}}} =
        post_rpc("pair.create", %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()

      # 手机：扫码打开授权页（消费码 → scanned）
      page = Plug.Test.conn(:get, "/pair?c=" <> code) |> Newbee.Web.Router.call(@opts)
      assert page.resp_body =~ "登录授权"

      # 手机：复核 + 点允许
      assert %{"result" => %{"ok" => _}} =
               post_rpc("pair.phone_status", %{"pairing_id" => pid}) |> Map.fetch!(:resp_body) |> Jason.decode!()
      assert %{"result" => %{"ok" => %{"approved" => true}}} =
               post_rpc("pair.confirm", %{"pairing_id" => pid}) |> Map.fetch!(:resp_body) |> Jason.decode!()

      # 电脑：轮询取 token
      %{"result" => %{"ok" => %{"status" => "approved", "token" => tok}}} =
        post_rpc("pair.status", %{"pairing_id" => pid}) |> Map.fetch!(:resp_body) |> Jason.decode!()

      # 取到的 token 能访问受保护端点
      conn = post_rpc("session.list", %{"limit" => 1}, tok)
      assert conn.status == 200
    end
  end
end
