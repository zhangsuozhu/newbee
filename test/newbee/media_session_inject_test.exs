defmodule Newbee.MediaSessionInjectTest do
  use ExUnit.Case, async: false

  @moduledoc """
  媒体会话能力链测试：Agent.Loop 签发 capability，EvalWorker 只在当前
  cell 进程临时暴露令牌，Tools.Media 回主节点校验令牌并解析真实会话。
  """

  test "media capability 只在单个 cell 进程内可见" do
    {result, _binding, _count} =
      Newbee.DEE.EvalWorker.run_cell(
        "Process.get({Newbee.Tools.Media, :capability})",
        [],
        5_000,
        0,
        media_capability: "cell-capability"
      )

    assert result.status == :ok
    assert result.value == ~s("cell-capability")

    {probe, _binding, _count} =
      Newbee.DEE.EvalWorker.run_cell(
        "Process.get({Newbee.Tools.Media, :capability})",
        [],
        5_000,
        1,
        []
      )

    assert probe.status == :ok
    assert probe.value == "nil"
  end

  test "Tools.Media 用已签发 capability 定位当前会话，不读 stale global" do
    suffix = System.unique_integer([:positive])
    sid = "media-capability-test-#{suffix}"
    stale_sid = "stale-global-#{suffix}"
    tmp = Path.join(System.tmp_dir!(), "newbee-media-capability-#{suffix}.txt")
    File.write!(tmp, "capability session test")

    assert :ok = Newbee.Collaboration.Capability.register(self(), sid, File.cwd!())
    assert {:ok, token} = Newbee.Collaboration.Capability.issue(self())
    Newbee.Session.set_current(stale_sid)

    on_exit(fn ->
      Newbee.Collaboration.Capability.revoke(token)
      Newbee.Session.set_current(nil)
      Newbee.Session.delete(sid)
      Newbee.Session.delete(stale_sid)
      File.rm(tmp)
    end)

    code = "Newbee.Tools.Media.show(" <> inspect(tmp) <> ", caption: \"capability test\")"

    {result, _binding, _count} =
      Newbee.DEE.EvalWorker.run_cell(code, [], 5_000, 0, media_capability: token)

    assert result.status == :ok
    assert result.value =~ sid
    refute result.value =~ stale_sid

    {:ok, current_items} = Newbee.Media.list(sid)
    assert Enum.any?(current_items, &(&1["name"] == Path.basename(tmp)))
    {:ok, stale_items} = Newbee.Media.list(stale_sid)
    refute Enum.any?(stale_items, &(&1["name"] == Path.basename(tmp)))
  end

  test "无效 capability 不回退到 stale global" do
    suffix = System.unique_integer([:positive])
    stale_sid = "stale-invalid-cap-#{suffix}"
    tmp = Path.join(System.tmp_dir!(), "newbee-media-invalid-cap-#{suffix}.txt")
    File.write!(tmp, "invalid capability test")
    Newbee.Session.set_current(stale_sid)

    on_exit(fn ->
      Newbee.Session.set_current(nil)
      Newbee.Session.delete(stale_sid)
      Newbee.Session.delete("unknown")
      File.rm(tmp)
    end)

    code = "Newbee.Tools.Media.show(" <> inspect(tmp) <> ", caption: \"invalid capability test\")"

    {result, _binding, _count} =
      Newbee.DEE.EvalWorker.run_cell(code, [], 5_000, 0, media_capability: "not-a-valid-token")

    assert result.status == :ok
    assert result.value =~ "invalid_context"
    refute result.value =~ stale_sid
  end
end

