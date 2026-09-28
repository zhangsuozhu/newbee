# 组队失败路径必须自愈：刷新列表（幽灵会话消失）+ 剔除已消失的勾选 +「会话不存在」时收起弹窗。
#
# 现场证据（浏览器轮次 R654/R655/R659/R660 修复前、R663/R667/R671/R674 修复后）：
# 服务端会后台清扫超过1 小时的空会话（sweep_stale_empty(3600)），侧栏在下一次刷新前仍显示它们，
# 用户拿这些「幽灵会话」组队必然报「会话不存在」，而原实现两个失败分支都不刷新列表、
# 弹窗也不关，导致反复重试必然再失败（R654 实测 modal_still_open=true、selected sid 在服务端 missing）。
defmodule Newbee.Web.GroupGhostSelfHealTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "建组提交前先对齐服务端列表并剔除幽灵勾选", ctx do
    # 同步必须发生在捕获 pendingGroupMembers 之前（否则 prune 换了数组、ids 仍是旧引用）
    i_sync = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "pruneGroupSelectionToLoaded();"))
    i_ids = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "const ids = state.pendingGroupMembers"))
    assert i_sync != nil and i_ids != nil and i_sync < i_ids, "提交前同步必须在捕获 ids 之前"
    assert ctx.js =~ "function pruneGroupSelectionToLoaded()"
    assert ctx.js =~ "state.pendingGroupMembers.filter((id) => have.has(id))"
  end

  test "两个失败分支都会刷新列表；「会话不存在」时收起弹窗并给出可操作提示", ctx do
    assert ctx.js =~ "组成工作组失败，已清理半成品组: \" + e.message + \"（已刷新会话列表，请重新勾选仍存在的会话后重试）\""
    assert ctx.js =~ "组成工作组失败: \" + e.message + \"（已刷新会话列表，请重新勾选仍存在的会话后重试）\""
    assert ctx.js =~ "pruneGroupSelectionToLoaded();"
    # 失败分支必须调用 loadSessions 让幽灵会话从列表消失
    assert length(String.split(ctx.js, "await loadSessions()")) >= 3
  end
end
