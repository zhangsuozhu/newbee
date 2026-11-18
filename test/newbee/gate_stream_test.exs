defmodule Newbee.GateStreamTest do
  @moduledoc """
  `Newbee.GateStream` 的契约：实时转发、完整捕获、退出码原样返回。

  为什么单测它：门禁与 `test.fast` 的全部判定都建立在"退出码 + 输出"上。R1 基线
  用 `System.cmd/3` 缓冲到结束，2000 s 的跑批期间日志一片空白（D8）。换成 Port 之后
  必须先证明它没有丢掉退出码，也没有把输出截断。
  """
  use ExUnit.Case, async: true

  test "退出码原样返回，输出完整捕获" do
    result = Newbee.GateStream.run(["bash", "-c", "echo alpha; echo beta >&2; exit 3"], io: io())

    assert result.exit == 3
    assert result.output =~ "alpha"
    assert result.output =~ "beta", "stderr 必须合并进 output"
    assert result.seconds >= 0
  end

  test "输出实时转发到给定的 io（不是跑完再吐）" do
    path = Path.join(System.tmp_dir!(), "stream-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, device} = File.open(path, [:write])

    try do
      result = Newbee.GateStream.run(["bash", "-c", "echo first; sleep 0.4; echo second"], io: device)
      assert result.exit == 0
      assert result.output == "first\nsecond\n"
    after
      File.close(device)
    end

    # 转发语义：写到 io 的内容与返回值一致（同一份字节）。
    assert File.read!(path) == "first\nsecond\n"
  end

  test "可执行文件不存在时返回 127 而不是抛异常" do
    result = Newbee.GateStream.run(["definitely-not-a-real-binary-newbee"], io: io())

    assert result.exit == 127
    assert result.output =~ "executable not found"
  end

  test "env 与 cd 生效" do
    result =
      Newbee.GateStream.run(["bash", "-c", "echo $NEWBEE_GATE_PROBE; pwd"],
        env: [{"NEWBEE_GATE_PROBE", "hello"}],
        io: io()
      )

    assert result.exit == 0
    assert result.output =~ "hello"

    elsewhere = Newbee.GateStream.run(["pwd"], cd: System.tmp_dir!(), io: io())
    assert String.trim(elsewhere.output) == String.trim(System.tmp_dir!())
  end

  defp io do
    {:ok, device} = StringIO.open("")
    device
  end
end
