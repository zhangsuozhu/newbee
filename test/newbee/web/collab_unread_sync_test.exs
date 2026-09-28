# 协作未读的三处修正（均由浏览器轮次取证）：
#   ① syncCollabUnreadFromActivity：服务端只把 group_event 下发给「绑定会话是组成员」的 socket
#      （socket.ex:170 sid in session_ids 才推帧）、group.activity.list 也要求成员身份，
#      所以离开期间（socket 绑到非成员会话）错过的动态必须回来后按 collabSeen 追补，
#      否则行徽标与 #mc-expand.has-unread 永远不亮（R687/R688 复现）。
#   ② renderCollaborationPane 里 markCollabSeen 加 viewingCollabNow() 守卫：
#      原先无条件记已读，会把「刚切回、还没打开协作」的未读立刻清掉（R689/R691 实测本组行徽标恒 nil）。
#   ③ markCollabSeen 里补 renderSessionList()：行徽标是渲染进 HTML 的，
#      只调 updateCollabBadges 徽标会挂到下一次列表重绘（R697 实测看完协作后仍显示「1 未读」）。
defmodule Newbee.Web.CollabUnreadSyncTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "① loadGroups 后按 collabSeen 并发追补未读", ctx do
    assert ctx.js =~ "async function syncCollabUnreadFromActivity(seq)"
    assert ctx.js =~ "await syncCollabUnreadFromActivity(seq);"
    assert ctx.js =~ "rpc(\"group.activity.list\""
    assert ctx.js =~ "sinceEventId: since"
    # 并发（历史组多时串行会晚几秒才亮，R702-704 稳定失败、改并发后 R708-710 三连绿）
    assert ctx.js =~ "await Promise.all(groups.map(async (g) => {"
    # 非成员无查询权限时必须忽略而不是抛错
    assert ctx.js =~ "_memberErr"
  end

  test "② 只有正在看协作才记已读", ctx do
    assert ctx.js =~ "if (viewingCollabNow()) markCollabSeen(group.group_id);"
    refute ctx.js =~ "    markCollabSeen(group.group_id);"
    assert ctx.js =~ "function viewingCollabNow() {"
  end

  test "③ 记已读后重绘会话列表（行徽标才会消失）", ctx do
    i_seen = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "function markCollabSeen"))
    assert i_seen != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i_seen)
      |> Enum.take(14)
      |> Enum.join("\n")

    assert body =~ "delete state.collabUnread[groupId]"
    assert body =~ "updateCollabBadges();"
    assert body =~ "if (typeof renderSessionList === \"function\") renderSessionList();"
  end
end
