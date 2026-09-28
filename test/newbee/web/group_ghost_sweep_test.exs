# FIX#14：后台清扫与组成员的一致性。
#
# 现场（全量回归 R741/R742 判失败、R746 诊断）：DOM63 行里20 行是「已删会话」且全部在组内——
# 后台 sweep_stale_empty(3600) 直接 Newbee.Session.delete，绕过了 session.delete RPC 里的
# remove_session_from_groups，于是 group.members 留下悬空成员；前端照渲成幽灵组员行，
# 用户点它做批量/菜单删除必然报「会话不存在」。
# 修法：①清扫跳过组内会话（in_any_group?）②group.list 按会话是否真实存在过滤展示（filter_ghost_members）。
defmodule Newbee.Web.GroupGhostSweepTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.Coordinator
  alias Newbee.Web
  alias Newbee.Web.Api

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-sweep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    start_supervised!({Newbee.Collaboration.Coordinator, path: Path.join(root, "events.jsonl"), durability: :event})

    :ok
  end

  defp transcript(id), do: Path.join([Newbee.GlobalStore.root(), "sessions", id <> ".jsonl"])

  defp mark_old(id) do
    assert :ok = Newbee.Session.mark_created(id)
    # 同时改文件 mtime 与索引 mtime：merged_index 优先取索引条目的 mtime
    # （mark_created 写的是「现在」，只 touch 文件测不出 stale）
    File.touch(transcript(id), {{2020, 1, 1}, {0, 0, 0}})

    idx = Path.join([Newbee.GlobalStore.root(), "sessions", ".index.json"])

    entries =
      case File.read(idx) do
        {:ok, body} -> Jason.decode!(body)
        _ -> []
      end

    entries =
      Enum.map(entries, fn e ->
        if e["id"] == id, do: Map.put(e, "mtime", 1_577_836_800), else: e
      end)

    File.write!(idx, Jason.encode!(entries))
  end

  test "清扫不删除组内会话，但会删除组外的陈旧空会话" do
    coord = "sweepcoord_#{System.unique_integer([:positive])}"
    drop = "sweepdrop_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Enum.each([coord, drop], fn id ->
        if File.regular?(transcript(id)), do: File.rm(transcript(id))
      end)
    end)

    mark_old(coord)
    mark_old(drop)

    {:ok, group} =
      Coordinator.create_group(%{
        "session_id" => coord,
        "title" => "sweep 测试组",
        "goal" => "验证清扫跳过组内会话",
        "group_id" => "grp-sweeptest-#{System.unique_integer([:positive])}"
      })

    swept = Web.Session.sweep_stale_empty(3600)

    refute coord in swept, "组内会话被后台清扫了，会留下悬空组成员"
    assert File.regular?(transcript(coord)), "组内陈旧空会话应被保留"
    assert drop in swept, "组外的陈旧空会话应照常回收"
    refute File.regular?(transcript(drop))

    assert Enum.any?(Coordinator.list(), &(&1["group_id"] == group["group_id"]))
  end

  test "group.list 过滤指向已删会话的成员，组长已删则整组不返回" do
    alive = "alive_#{System.unique_integer([:positive])}"
    assert :ok = Newbee.Session.mark_created(alive)
    on_exit(fn -> if File.regular?(transcript(alive)), do: File.rm(transcript(alive)) end)

    groups = [
      %{
        "group_id" => "g1",
        "coordinator_session_id" => alive,
        "members" => [%{"session_id" => alive}, %{"session_id" => "ghost-member"}]
      },
      %{
        "group_id" => "g2",
        "coordinator_session_id" => "ghost-coordinator",
        "members" => [%{"session_id" => alive}]
      },
      %{
        "group_id" => "g3",
        "coordinator_session_id" => alive,
        "members" => [%{"session_id" => alive}]
      }
    ]

    out = Api.filter_ghost_members(groups)
    ids = Enum.map(out, & &1["group_id"])

    assert "g3" in ids
    assert "g2" not in ids, "组长会话已不存在的组不应再展示"
    g1 = Enum.find(out, &(&1["group_id"] == "g1"))
    assert Enum.map(g1["members"], & &1["session_id"]) == [alive]
  end
end
