defmodule Newbee.Web.ApiIntegrationTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  defp post_rpc(method, payload \\ %{}) do
    body =
      Jason.encode!(%{
        "rpcId" => "test-1",
        "method" => method,
        "payload" => payload
      })

    conn =
      Plug.Test.conn(:post, "/api/" <> method, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Newbee.Web.Router.call(conn, @opts)
  end

  defp parse_body(conn) do
    case conn.resp_body do
      nil ->
        %{}

      body ->
        case Jason.decode(body) do
          {:ok, json} -> json
          _ -> %{}
        end
    end
  end

  describe "git.diffStat" do
    test "返回文件列表结构" do
      conn = post_rpc("git.diffStat")
      assert conn.status == 200

      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "files")
          assert is_list(ok["files"])

        %{"error" => err} ->
          assert is_binary(err["code"])
      end
    end
  end

  describe "git.impact" do
    test "返回影响分析结构" do
      conn = post_rpc("git.impact")
      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "files") or Map.has_key?(ok, "summary")
          if Map.has_key?(ok, "summary"), do: assert(is_map(ok["summary"]))

        %{"error" => _} ->
          :ok
      end
    end
  end

  describe "env.health" do
    test "返回环境健康数据" do
      conn = post_rpc("env.health")
      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "rules")
          assert Map.has_key?(ok, "antibodies")

        %{"error" => _} ->
          :ok
      end
    end
  end

  describe "files.search" do
    test "搜索文件返回列表" do
      conn = post_rpc("files.search", %{"q" => "api"})
      resp = parse_body(conn)
      result = resp["result"]

      case result do
        %{"ok" => ok} ->
          assert Map.has_key?(ok, "files")
          assert is_list(ok["files"])

        %{"error" => _} ->
          :ok
      end
    end
  end

  describe "files.read" do
    setup do
      root = Path.join(System.tmp_dir!(), "newbee-file-preview-#{System.unique_integer([:positive])}")
      sid = "file-preview-#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join(root, "docs"))
      File.write!(Path.join(root, "docs/readme.md"), "# Preview\n\nHello")
      File.write!(Path.join(root, "binary.bin"), <<0, 1, 2>>)
      File.ln_s!(System.user_home!(), Path.join(root, "escape"))
      Newbee.Session.set_cwd(sid, root)

      on_exit(fn ->
        File.rm_rf!(root)
        File.rm_rf!(Path.join([System.user_home!(), ".newbee/session-artifacts", sid]))
      end)

      %{sid: sid}
    end

    test "读取工作区内 Markdown 并返回预览元数据", %{sid: sid} do
      response = post_rpc("files.read", %{"sessionId" => sid, "path" => "docs/readme.md"}) |> parse_body()
      assert %{"ok" => file} = response["result"]
      assert file["path"] == "docs/readme.md"
      assert file["content"] == "# Preview\n\nHello"
      assert file["markdown"] == true
      assert file["language"] == "markdown"
    end

    test "拒绝相对路径和符号链接逃逸", %{sid: sid} do
      for path <- ["../outside.md", "escape/.profile"] do
        response = post_rpc("files.read", %{"sessionId" => sid, "path" => path}) |> parse_body()
        assert %{"error" => %{"code" => code}} = response["result"]
        assert code in ["file_forbidden", "file_not_found"]
      end
    end

    test "拒绝二进制文件", %{sid: sid} do
      response = post_rpc("files.read", %{"sessionId" => sid, "path" => "binary.bin"}) |> parse_body()
      assert %{"error" => %{"code" => "file_forbidden"}} = response["result"]
    end
  end

  describe "未知方法" do
    test "返回 unknown_method 错误" do
      conn = post_rpc("nonexistent.method")
      resp = parse_body(conn)
      result = resp["result"]
      assert %{"error" => err} = result
      assert err["code"] == "unknown_method"
    end
  end
end
