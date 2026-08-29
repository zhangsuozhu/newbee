defmodule Newbee.CheckpointTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  setup do
    # 隔离沙箱：checkpoint RPC 的 git 副作用落在临时仓库，绝不污染工程仓库
    tmp = Path.join(System.tmp_dir!(), "nb_checkpoint_" <> Integer.to_string(:rand.uniform(999_999_999)))
    File.mkdir_p!(tmp)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.email", "cp-test@test"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.name", "cp-test"], cd: tmp)
    File.write!(Path.join(tmp, "a.txt"), "base")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: tmp)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

    original = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      # File.cwd! 是 VM 全局：后续用例可能已 cd 走，只有当前 cwd 仍是本用例 tmp 时才回退
      if File.cwd!() == tmp do
        File.cd!(original)
      end

      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp post_rpc(method, payload \\ %{}) do
    body = Jason.encode!(%{"rpcId" => "t", "method" => method, "payload" => payload})

    conn =
      Plug.Test.conn(:post, "/api/" <> method, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Newbee.Web.Router.call(conn, @opts)
  end

  defp parse(conn) do
    case Jason.decode(conn.resp_body || "{}") do
      {:ok, j} -> j["result"]
      _ -> nil
    end
  end

  test "checkpoint.list 返回列表结构" do
    conn = post_rpc("git.checkpoint.list")
    assert conn.status == 200

    case parse(conn) do
      %{"ok" => ok} -> assert is_list(ok["checkpoints"])
      _ -> flunk("unexpected response")
    end
  end

  test "checkpoint.create 有变更时提交，无变更时报错" do
    # 干净工作区 → nothing_to_checkpoint
    conn = post_rpc("git.checkpoint.create", %{"description" => "test"})
    assert conn.status == 200

    case parse(conn) do
      %{"ok" => _} -> flunk("干净工作区不应创建 checkpoint")
      %{"error" => err} -> assert is_map(err)
      _ -> flunk("unexpected response")
    end

    # 制造未提交变更 → committed，消息为 [checkpoint] test
    File.write!(Path.join(File.cwd!(), "a.txt"), "changed")
    conn2 = post_rpc("git.checkpoint.create", %{"description" => "test"})
    assert conn2.status == 200

    case parse(conn2) do
      %{"ok" => ok} ->
        assert ok["committed"] == true
        assert ok["message"] == "[checkpoint] test"

      %{"error" => err} ->
        flunk("有变更时应创建 checkpoint，got: " <> inspect(err))

      _ ->
        flunk("unexpected response")
    end

    # 提交后工作区干净 → 回到 nothing_to_checkpoint
    conn3 = post_rpc("git.checkpoint.create", %{"description" => "test"})
    assert conn3.status == 200

    case parse(conn3) do
      %{"ok" => _} -> flunk("提交后工作区干净，不应创建 checkpoint")
      %{"error" => err} -> assert is_map(err)
      _ -> flunk("unexpected response")
    end
  end

  test "checkpoint.create 的提交落在沙箱" do
    File.write!(Path.join(File.cwd!(), "a.txt"), "more")
    conn = post_rpc("git.checkpoint.create", %{"description" => "iso"})
    assert conn.status == 200

    case parse(conn) do
      %{"ok" => ok} -> assert ok["committed"] == true
      _ -> flunk("沙箱里应能创建 checkpoint")
    end

    {log, 0} = System.cmd("git", ["log", "--oneline", "--grep=[checkpoint]"], stderr_to_stdout: true)
    assert log =~ "[checkpoint] iso"
  end
end
