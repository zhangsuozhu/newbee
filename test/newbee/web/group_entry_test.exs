# 「组成工作组」入口必须随选中会话出现，否则整条工作组/协作链路在 UI 上不可达。
#
# 现场证据（浏览器轮次 R627/R628 修复前、R630/R634-R636 修复后）：按钮 HTML 自带
# class="hidden" 与 hidden 属性，而 app.js 只切 disabled、从不移除 hidden，配合
# `.hidden { display: none !important }` 导致入口永不可见；openGroupModal 唯一绑定就在该按钮上，
# 于是组队/协作（MC 协作输入依赖 state.activeGroup）全程碰不到。选中2 个会话后实测
# hidden 仍为 true、点击超时。
defmodule Newbee.Web.GroupEntryTest do
  use ExUnit.Case, async: true

  @index "priv/web/index.html"
  @workspace "priv/web/workspace.html"
  @js "priv/web/app.js"

  setup do
    %{index: File.read!(@index), workspace: File.read!(@workspace), js: File.read!(@js)}
  end

  test "入口按钮不自带 hidden（由选中状态控制）", ctx do
    for html <- [ctx.index, ctx.workspace] do
      line =
        html
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "id=\"new-group\""))

      assert line, "缺少 new-group 按钮"
      refute line =~ "hidden", "按钮自带 hidden 会让入口永不可见: " <> String.trim(line)
      assert line =~ "disabled", "未选中时应为 disabled（由 JS 控制显隐）"
    end
  end

  test "选中状态同时驱动 disabled 与 hidden", ctx do
    assert ctx.js =~ "groupBtn.disabled = n === 0;"
    assert ctx.js =~ "groupBtn.hidden = n === 0;"
    assert ctx.js =~ "groupBtn.classList.toggle(\"hidden\", n === 0);"
    assert ctx.js =~ "bind(\"new-group\", openGroupModal);"
  end
end
