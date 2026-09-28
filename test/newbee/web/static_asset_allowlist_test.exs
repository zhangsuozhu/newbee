defmodule Newbee.Web.StaticAssetAllowlistTest do
  @moduledoc """
  静态资产白名单：priv/web 下只有浏览器资产能被 GET 到。

  现场证据：Edit 工具残留的 priv/web/app.js.newbee-edit-backup-65218（443 KB）
  和服务端模板 priv/web/pair.html.eex 都曾以 HTTP 200 原样下发；静态路径不受
  认证约束，远程暴露时任何落进 priv/web 的文件都会被读走。
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Newbee.Web.Router

  @opts Router.init([])

  setup do
    sandbox = Newbee.TestSupport.WebTmpHome.enter("static_asset_test")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)
    on_exit(fn -> Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  defp get(path), do: Router.call(conn(:get, path), @opts)

  test "浏览器资产照常下发" do
    assert get("/theme.js").status == 200
    assert get("/index.html").status == 200
  end

  test "服务端模板 pair.html.eex 不下发" do
    assert get("/pair.html.eex").status == 403
  end

  test "编辑器/工具备份残留不下发" do
    dir = Path.join(to_string(:code.priv_dir(:newbee)), "web")
    residue = Path.join(dir, "residue-test.js.newbee-edit-backup-999")
    File.write!(residue, "worktree residue")
    on_exit(fn -> File.rm(residue) end)

    assert get("/residue-test.js.newbee-edit-backup-999").status == 403
  end

  test "未知路径仍走 SPA fallback 回 index.html" do
    conn = get("/some/client/route")
    assert conn.status == 200
    assert conn.resp_body =~ "newbee"
  end

  test "servable_static?/1 白名单边界" do
    assert Router.servable_static?("/x/app.js")
    assert Router.servable_static?("/x/style.css")
    assert Router.servable_static?("/x/favicon.svg")

    refute Router.servable_static?("/x/pair.html.eex")
    refute Router.servable_static?("/x/mix.exs")
    refute Router.servable_static?("/x/.env")
    refute Router.servable_static?("/x/app.js.newbee-edit-backup-12")
    refute Router.servable_static?("/x/notes")
  end
end
