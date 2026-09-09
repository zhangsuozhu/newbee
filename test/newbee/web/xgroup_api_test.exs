defmodule Newbee.Web.XGroupApiTest do
  use ExUnit.Case, async: false
  @opts Newbee.Web.Router.init([])
  defmodule FakeConnections do
    def join(base_url, group_id, password, fingerprint, display, opts) do
      send(self(), {:remote_join, base_url, group_id, password, fingerprint, display, opts})
      {:ok, %{"group" => %{"id" => group_id}, "device" => %{"id" => "remote-device"}}}
    end
  end

  setup do
    Newbee.Collaboration.CrossHost.Store.clear()
    :ok
  end

  test "create join task preview page" do
    created = post_rpc("xgroup.create", %{"serverUrl" => "192.168.0.20"}) |> ok!()
    gid = created["group"]["id"]
    fp = created["serverFp"]
    code = created["code"]
    assert gid != nil
    assert created["group"]["name"] != nil
    assert fp != nil
    {:ok, cert_fp} = Newbee.Web.Cert.fingerprint()
    assert fp == cert_fp
    assert String.starts_with?(code, "XG1.")
    assert get_in(created, ["group", "password"]) == nil
    parsed = post_rpc("xgroup.code.parse", %{"code" => code}) |> ok!()
    plain = parsed["password"]
    assert parsed["groupId"] == gid
    assert is_binary(plain) and plain != ""
    assert parsed["baseUrl"] == "https://192.168.0.20:4173"

    joined =
      post_rpc("xgroup.join", %{"groupId" => gid, "password" => plain, "fingerprint" => fp, "display" => "dev-8"})
      |> ok!()

    assert Map.get(joined, "member_id") != nil
    assert get_in(joined, ["device", "plain"]) != nil

    bad =
      post_rpc("xgroup.join", %{"groupId" => gid, "password" => "wrong-pass-123", "fingerprint" => fp, "display" => "x"})

    assert match?(%{"result" => %{"error" => _}}, bad)

    fake =
      post_rpc("xgroup.join", %{
        "groupId" => gid,
        "password" => plain,
        "fingerprint" => "fp-abcdef-87654321",
        "display" => "x"
      })

    assert match?(%{"result" => %{"error" => _}}, fake)
    listed = post_rpc("xgroup.list", %{}) |> ok!()
    assert Enum.any?(listed["groups"], fn g -> g["id"] == gid end)
    got = post_rpc("xgroup.get", %{"groupId" => gid}) |> ok!()
    assert get_in(got, ["group", "id"]) == gid

    task =
      post_rpc("xgroup.task.create", %{
        "groupId" => gid,
        "idempotencyKey" => "k-web-1",
        "description" => "OPENAI_API_KEY=must-not-leak"
      })
      |> ok!()

    assert Map.get(task, "id") != nil
    assert Map.get(task, "description") == "[REDACTED]"
    tasks = post_rpc("xgroup.task.list", %{"groupId" => gid}) |> ok!()
    assert length(tasks["tasks"]) == 1
    tr = post_rpc("xgroup.task.transition", %{"taskId" => Map.get(task, "id"), "event" => "start"}) |> ok!()
    assert Map.get(tr, "status") == "running"

    cancelled =
      post_rpc("xgroup.task.create", %{
        "groupId" => gid,
        "idempotencyKey" => "k-web-cancel",
        "description" => "待取消"
      })
      |> ok!()

    cx = post_rpc("xgroup.task.transition", %{"taskId" => Map.get(cancelled, "id"), "event" => "cancel"}) |> ok!()
    assert Map.get(cx, "status") == "failed"
    bad_cx = post_rpc("xgroup.task.transition", %{"taskId" => Map.get(task, "id"), "event" => "cancel"})
    assert match?(%{"result" => %{"error" => _}}, bad_cx)

    pv = post_rpc("xgroup.preview.attach", %{"bind" => "127.0.0.1", "port" => 4001}) |> ok!()
    assert get_in(pv, ["preview", "bind"]) == "127.0.0.1"
    badpv = post_rpc("xgroup.preview.attach", %{"bind" => "0.0.0.0", "port" => 3000})
    assert match?(%{"result" => %{"error" => _}}, badpv)
    plan = post_rpc("xgroup.firewall.plan", %{"hubIp" => "192.168.0.20", "lan" => true}) |> ok!()
    assert get_in(plan, ["hub_inbound", Access.at(0), "port"]) == 8443
    _ = post_rpc("xgroup.code", %{"groupId" => gid}) |> ok!()
    code2 = post_rpc("xgroup.code", %{"groupId" => gid}) |> ok!()
    assert String.starts_with?(code2["code"], "XG1.")
    parsed2 = post_rpc("xgroup.code.parse", %{"code" => code2["code"]}) |> ok!()
    assert parsed2["groupId"] == gid
    did = get_in(joined, ["device", "id"])
    _bound = post_rpc("xgroup.session.bind", %{"groupId" => gid, "sessionId" => "sess-1", "deviceId" => did}) |> ok!()
    sl = post_rpc("xgroup.session.list", %{"groupId" => gid}) |> ok!()
    assert length(sl["sessions"]) == 1
    st = post_rpc("xgroup.device.status", %{"groupId" => gid}) |> ok!()
    assert [%{"id" => ^did, "state" => state, "hint" => hint}] = st["devices"]
    assert state in ["online", "paused", "offline"]
    assert is_binary(hint) and hint != ""
    assert get_in(hd(st["devices"]), ["token_hash"]) == nil
    bad_st = post_rpc("xgroup.device.status", %{})
    assert match?(%{"result" => %{"error" => _}}, bad_st)

    _ = post_rpc("xgroup.session.unbind", %{"groupId" => gid, "sessionId" => "sess-1"}) |> ok!()
    sl2 = post_rpc("xgroup.session.list", %{"groupId" => gid}) |> ok!()
    assert sl2["sessions"] == []
    sid = "shared-api-#{System.unique_integer([:positive])}"
    _ = post_rpc("session.create", %{"sessionId" => sid}) |> ok!()
    _ = post_rpc("xgroup.session.bind", %{"groupId" => gid, "sessionId" => sid, "deviceId" => did}) |> ok!()

    shared_board =
      post_rpc("collab.shared.read", %{"sessionId" => sid, "groupId" => gid, "resource" => "board"}) |> ok!()

    assert shared_board["kind"] == "shared_board"

    assert is_map(
             post_rpc("collab.shared.publish", %{
               "sessionId" => sid,
               "groupId" => gid,
               "title" => "约定",
               "body" => "API_KEY=must-be-redacted",
               "commandId" => "api-knowledge-1"
             })
             |> ok!()
           )

    shared_knowledge = post_rpc("collab.shared.read", %{"sessionId" => sid, "path" => gid <> "/knowledge"}) |> ok!()
    assert [%{"body" => "[REDACTED]"}] = shared_knowledge["entries"]
    _ = post_rpc("xgroup.session.unbind", %{"groupId" => gid, "sessionId" => sid}) |> ok!()
    :ok = Newbee.Web.Session.destroy(sid)

    _ = post_rpc("xgroup.delete", %{"groupId" => gid}) |> ok!()
    gone = post_rpc("xgroup.get", %{"groupId" => gid})
    assert match?(%{"result" => %{"error" => _}}, gone)
  end

  test "remote join delegates to the outbound connector" do
    previous = Application.get_env(:newbee, :cross_host_connections)
    Application.put_env(:newbee, :cross_host_connections, FakeConnections)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:newbee, :cross_host_connections, previous),
        else: Application.delete_env(:newbee, :cross_host_connections)
    end)

    fingerprint = "sha256:" <> String.duplicate("b", 64)

    joined =
      post_rpc("xgroup.remote.join", %{
        "baseUrl" => "192.168.0.20",
        "groupId" => "remote-group",
        "password" => "join-secret",
        "fingerprint" => fingerprint,
        "display" => "dev-8",
        "fullControl" => true
      })
      |> ok!()

    assert get_in(joined, ["device", "id"]) == "remote-device"
    assert_receive {:remote_join, "192.168.0.20", "remote-group", "join-secret", ^fingerprint, "dev-8", opts}
    assert opts[:allow_full_control] == true
  end

  defp post_rpc(method, payload) do
    body = Jason.encode!(%{"rpcId" => "test", "method" => method, "payload" => payload})

    Plug.Test.conn(:post, "/api/" <> method, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Newbee.Web.Router.call(@opts)
    |> then(fn conn -> Jason.decode!(conn.resp_body) end)
  end

  defp ok!(%{"result" => %{"ok" => v}}), do: v
end
