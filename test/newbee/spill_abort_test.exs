defmodule Newbee.SpillAbortTest do
  use ExUnit.Case, async: true

  alias Newbee.Spill

  test "abort 对 finish 之后返回的 info map 安全（幂等）" do
    assert {:ok, info} = Spill.store("abort-after-finish\n")

    # info map 没有 :fd/:tmp；重复 abort 必须是无害的 no-op，而不是 KeyError
    assert :ok = Spill.abort(info)
    assert :ok = Spill.abort(info)

    # 对象仍在（abort 不该删掉已提交的内容）
    assert {:ok, meta} = Spill.stat(info.id)
    assert meta.bytes > 0
  end

  test "abort 对畸形输入安全" do
    assert :ok = Spill.abort(%{})
    assert :ok = Spill.abort(%{fd: nil, tmp: nil})
    assert :ok = Spill.abort(nil)
    assert :ok = Spill.abort(:nope)
    assert :ok = Spill.abort("string")
  end

  test "abort 关闭 fd 并删掉 tmp" do
    assert {:ok, handle} = Spill.open_stream()
    handle = Spill.push(handle, "discard\n")
    tmp = handle.tmp
    assert File.regular?(tmp)

    assert :ok = Spill.abort(handle)
    refute File.exists?(tmp)
    # 二次 abort 不炸
    assert :ok = Spill.abort(handle)
  end
end
