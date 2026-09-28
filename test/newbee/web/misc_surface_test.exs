# 三个新场景（R866-R868 首跑全绿）对应的源码结构断言：
#   fileviewer：document 级 .file-ref[data-path] 点击 → openFileViewer（自然入口要等 agent 消息，
#               本环境用注入 span 取证；modal 类名含 modal，Esc 走 FIX#20 链关闭）
#   dirapply：  #dir-confirm → session.cwd RPC → updateCwdLabel + notice 行（实测标签/面包屑/复原全对）
#   attach：    隐藏 file input 喂文件与合成 paste 事件都进 addAttachment；chip 为 .attach-item，
#               .attach-remove 先 splice 再 deleteAttachment，删空后预览区 hidden
defmodule Newbee.Web.MiscSurfaceTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"
  @html "priv/web/index.html"

  setup do
    %{js: File.read!(@js), html: File.read!(@html)}
  end

  test "file-ref 全局点击打开文件查看器", ctx do
    assert ctx.js =~ "e.target.closest(\".file-ref\")"
    assert ctx.js =~ "openFileViewer(ref.dataset.path)"
    assert ctx.js =~ "async function openFileViewer(path)"
    assert ctx.html =~ ~s(id="file-viewer")
    assert ctx.html =~ ~s(id="file-viewer-close")
  end

  test "目录确认走 session.cwd 并更新标签与提示", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, ~s[$("dir-confirm").addEventListener]))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(16)
      |> Enum.join("\n")

    assert body =~ "rpc(\"session.cwd\","
    assert body =~ "updateCwdLabel(state.cwd)"
    assert body =~ "当前会话工作目录已切换为"
    assert ctx.html =~ ~s(id="dir-confirm")
  end

  test "粘贴文件与 chip 增删路径完整", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, ~s[input.addEventListener("paste",]))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(14)
      |> Enum.join("\n")

    assert body =~ "it.kind === \"file\""
    assert body =~ "addAttachment(f)"
    assert body =~ "e.preventDefault()"
    # chip 渲染与删除
    assert ctx.js =~ "rm.className = \"attach-remove\""
    assert ctx.js =~ "state.attachments.splice(i, 1)"
    assert ctx.js =~ "deleteAttachment(removed)"
    assert ctx.html =~ ~s(id="attach-preview")
    assert ctx.html =~ ~s(id="file-input")
  end
end
