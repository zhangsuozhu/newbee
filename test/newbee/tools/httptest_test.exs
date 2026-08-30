defmodule Newbee.Tools.HttpFinchBootstrapTest do
  use ExUnit.Case, async: false

  defmodule EchoPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      send_resp(conn, 200, "echo:#{conn.method}:#{conn.request_path}")
    end
  end

  setup do
    {:ok, pid} = Bandit.start_link(plug: EchoPlug, port: 0, scheme: :http)
    {:ok, {{0, 0, 0, 0}, port}} = ThousandIsland.listener_info(pid)

    on_exit(fn ->
      if pid && Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    {:ok, port: port}
  end

  test "Http.get 自举 Finch 后请求成功", %{port: port} do
    assert {:ok, %{status: 200, body: body}} =
             Newbee.Tools.Http.get("http://127.0.0.1:#{port}/hello")

    assert body == "echo:GET:/hello"
  end

  test "Http.post 自举 Finch 后请求成功", %{port: port} do
    assert {:ok, %{status: 200, body: body}} =
             Newbee.Tools.Http.post("http://127.0.0.1:#{port}/submit", %{a: 1})

    assert body == "echo:POST:/submit"
  end

  test "ensure_finch! 幂等可重复调用" do
    assert :ok = Newbee.Host.Shell.ensure_finch!()
    assert :ok = Newbee.Host.Shell.ensure_finch!()
    assert Process.whereis(Req.Finch)
  end
end
