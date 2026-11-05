defmodule Newbee.Web.TerminalCdScopeTest do
  # 真 PTY，串行跑：`cd:` 必须只作用于本次调用，不能漂到后续调用或手动终端。
  use ExUnit.Case, async: false

  alias Newbee.Web

  @timeout 60_000

  setup do
    sid = "test-cd-" <> Integer.to_string(System.unique_integer([:positive]))
    base = System.tmp_dir!()
    other = Path.join(base, "newbee-cd-scope-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(other)
    {:ok, _pid} = Web.Terminal.ensure(sid, base)
    assert {:ok, _info} = Web.Terminal.open(sid, base)

    on_exit(fn ->
      Web.Terminal.close(sid)
      File.rm_rf(other)
    end)

    %{sid: sid, base: Path.expand(base), other: Path.expand(other)}
  end

  test "dir 只在本次调用生效，结束后回到原目录", %{sid: sid, base: base, other: other} do
    assert %{exit: 0, output: out} = Web.Terminal.exec(sid, base, "pwd", @timeout, other)
    assert String.trim(out) == other

    # 下一次不传 dir：不能停在 other
    assert %{exit: 0, output: again} = Web.Terminal.exec(sid, base, "pwd", @timeout)
    assert String.trim(again) == base
  end

  test "dir 不存在时命令不执行且退出码非零", %{sid: sid, base: base} do
    marker = Path.join(base, "newbee-cd-marker-" <> Integer.to_string(System.unique_integer([:positive])))
    result = Web.Terminal.exec(sid, base, "touch " <> marker, @timeout, "/no/such/dir/here")

    assert result.exit != 0
    assert result.output =~ "cannot enter"
    refute File.exists?(marker)

    # 失败之后原目录仍然可用
    assert %{exit: 0, output: out} = Web.Terminal.exec(sid, base, "pwd", @timeout)
    assert String.trim(out) == base
  end
end
