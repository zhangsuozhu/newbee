# 设计待办②「非成员实时未读」的两层修复：
#   服务端：组的读接口（group.get / group.activity.list / collab.message.list / group.status）
#           改为「组存在即可读」——本应用是单用户信任域（session.history/list 本就跨会话可读），
#           读也卡成员身份会让「切到非成员会话」时的未读追补必然失败（API 实测：非成员读 ok，
#           非成员写仍 not_member）；写（spawn / message.send / review / hive.task.*）保持成员校验。
#   客户端：在既有8 秒未读轮询旁挂10 秒的组活动追补（防重入、document.hidden 跳过），
#           浏览器轮次 R794/R795 实测：人在非成员会话时行徽标即点亮「1 未读」、mc-expand 亮起。
defmodule Newbee.Web.GroupReadRelaxTest do
  use ExUnit.Case, async: true

  @api "lib/newbee/web/api.ex"
  @js "priv/web/app.js"

  setup do
    %{
      api: File.read!(@api),
      js: File.read!(@js),
      coord: File.read!("lib/newbee/collaboration/coordinator.ex")
    }
  end

  test "四个读接口用 require_group_readable，写接口仍用 require_group_member", ctx do
    reads = [
      ~s(defp dispatch_rpc("group.get"),
      ~s(defp dispatch_rpc("group.activity.list"),
      ~s(defp dispatch_rpc("collab.message.list"),
      ~s(defp dispatch_rpc("group.status")
    ]

    for head <- reads do
      i = Enum.find_index(String.split(ctx.api, "\n"), &String.contains?(&1, head))
      assert i != nil, "找不到接口: #{head}"

      guard =
        ctx.api
        |> String.split("\n")
        |> Enum.drop(i)
        |> Enum.take(4)
        |> Enum.join("\n")

      assert guard =~ "require_group_readable(group_id, sid)", "#{head} 应放宽为组可读"
      refute guard =~ "require_group_member", "#{head} 不应再要求成员身份"
    end

    # 写接口必须仍是成员校验：
    #  · spawn 在 api.ex 层校验（多行 dispatch，用接口名行定位）
    #  · message.send 的校验在 Coordinator（ensure_member），api 层只做参数整理
    i = Enum.find_index(String.split(ctx.api, "\n"), &String.contains?(&1, ~s("group.member.spawn",)))
    assert i != nil, "找不到 group.member.spawn"

    guard =
      ctx.api
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(16)
      |> Enum.join("\n")

    assert guard =~ "require_group_member", "spawn 写操作必须仍要求成员身份"

    assert ctx.api =~ "Coordinator.send_message(group_id, attrs)"
    assert ctx.coord =~ "ensure_member(group, attrs[\"sender_session_id\"])"

    assert ctx.api =~ "defp require_group_readable(group_id, _session_id) do"
    assert ctx.api =~ "Coordinator.get(group_id)"
  end

  test "客户端有10 秒的组活动追补定时器（防重入、隐藏页跳过）", ctx do
    assert ctx.js =~ "window.__collabUnreadTimer = window.__collabUnreadTimer || setInterval"
    assert ctx.js =~ "syncCollabUnreadFromActivity(groupLoadSeq)"
    assert ctx.js =~ "if (document.hidden || collabSyncBusy) return;"
    assert ctx.js =~ "collabSyncBusy = true;"
    assert ctx.js =~ ".finally(() => { collabSyncBusy = false; });"
    # 间隔10 秒（10000）
    assert ctx.js =~ "}, 10000);"
  end
end
