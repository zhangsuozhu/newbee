defmodule Newbee.Tools.HttpJsonBodyTest do
  use ExUnit.Case, async: false

  defmodule JsonPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/json-map" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true, "saw_body" => body}))

      "/json-list" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!([1, 2, 3]))

      "/echo" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          ct = List.first(Plug.Conn.get_req_header(conn, "content-type"), "none")
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ct" => ct, "body" => body}))

      _ ->
          send_resp(conn, 204, "")
      end
    end
  end

  setup do
    {:ok, pid} = Bandit.start_link(plug: JsonPlug, port: 0, scheme: :http)
    {:ok, {{0, 0, 0, 0}, port}} = ThousandIsland.listener_info(pid)

    on_exit(fn ->
      if pid && Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    {:ok, port: port}
  end

  @base "http://127.0.0.1"

  test "GET application/json 响应返回原始 JSON 文本（不吞 body）", %{port: port} do
    assert {:ok, %{status: 200, body: body}} = Newbee.Tools.Http.get("#{@base}:#{port}/json-map")
    assert body == ~s({"ok":true,"saw_body":""})
  end

  test "GET JSON 数组响应返回原始文本", %{port: port} do
    assert {:ok, %{status: 200, body: body}} = Newbee.Tools.Http.get("#{@base}:#{port}/json-list")
    assert body == "[1,2,3]"
  end

  test "POST map 走 JSON 编码并带 application/json 头", %{port: port} do
    assert {:ok, %{status: 200, body: body}} =
             Newbee.Tools.Http.post("#{@base}:#{port}/echo", %{"a" => 1})

    assert %{"ct" => ct, "body" => echoed} = Jason.decode!(body)
    assert String.contains?(ct, "application/json")
    assert echoed == ~s({"a":1})
  end

  test "POST JSON 字符串原样发送并带 application/json 头", %{port: port} do
    assert {:ok, %{status: 200, body: body}} =
             Newbee.Tools.Http.post("#{@base}:#{port}/echo", ~s({"a": 1}))

    assert %{"ct" => ct, "body" => echoed} = Jason.decode!(body)
    assert String.contains?(ct, "application/json")
    assert echoed == ~s({"a": 1})
  end

  test "POST 字符串且用户已提供 content-type 时尊重用户头", %{port: port} do
    assert {:ok, %{status: 200, body: body}} =
             Newbee.Tools.Http.post("#{@base}:#{port}/echo", ~s({"a": 1}), [{"content-type", "text/plain"}])

    assert %{"ct" => ct} = Jason.decode!(body)
    assert String.contains?(ct, "text/plain")
  end
end
