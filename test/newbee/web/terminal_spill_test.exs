defmodule Newbee.Web.TerminalSpillTest do
  # 真 PTY，串行跑；只走 GenServer API，不依赖 WS。
  use ExUnit.Case, async: false

  alias Newbee.{Spill, Web}

  @timeout 60_000
  # head 32KB + tail 32KB；PTY 会把每行变成 \r\n 并回显命令，
  # 所以同样的行数在 PTY 里比裸 stdout 更占字节。
  @keep_bytes 64_000

  defp start_terminal do
    sid = "test-spill-" <> Integer.to_string(System.unique_integer([:positive]))
    cwd = System.tmp_dir!()
    {:ok, _pid} = Web.Terminal.ensure(sid, cwd)
    assert {:ok, _info} = Web.Terminal.open(sid, cwd)
    sid
  end

  defp read_all(id), do: do_read_all(id, 0, [])

  defp do_read_all(id, offset, acc) do
    {:ok, page} = Spill.read(id, offset: offset, max_bytes: 4_096)
    acc = [page.text | acc]
    if page.eof, do: IO.iodata_to_binary(Enum.reverse(acc)), else: do_read_all(id, page.next_offset, acc)
  end

  defp stated_original(output) do
    [_, stated] = Regex.run(~r/原文 (\d+) bytes/, output)
    String.to_integer(stated)
  end

  setup do
    sid = start_terminal()
    on_exit(fn -> Web.Terminal.close(sid) end)
    %{sid: sid, cwd: System.tmp_dir!()}
  end

  test "短输出原样返回，不加标记", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "printf 'hello\\nworld\\n'", @timeout)

    assert result.exit == 0
    assert result.output =~ "hello"
    assert result.output =~ "world"
    refute result.output =~ "截断"
    refute result.output =~ "spill://"
  end

  test "输出落在预算内时既不报截断也不产生 spill 文件", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "seq 1 3000", @timeout)

    assert result.exit == 0
    assert byte_size(result.output) < @keep_bytes
    # 旧的 dropped 计数会把 20KB 输出谎报成"省略 N bytes"
    refute result.output =~ "截断"
    refute result.output =~ "spill://"
  end

  test "超预算时截断但给出句柄；标记自报量与对象字节数一致且对象非空", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "seq 1 20000", @timeout)

    assert result.exit == 0
    assert result.output =~ "截断: 省略 "
    assert byte_size(result.output) < @keep_bytes + 1_000

    [id] = Spill.handles_in(result.output)
    {:ok, meta} = Spill.stat(id)

    # 句柄必须指向真实内容（曾经的 bug：标记声称有原文，对象却是空的）
    assert meta.bytes > 0
    assert meta.bytes == stated_original(result.output)

    recovered = read_all(id)
    assert byte_size(recovered) == meta.bytes

    # 保留下来的头尾确实来自这份原文
    assert recovered =~ "1\r\n"
    assert recovered =~ "20000"
  end

  test "退出码仍然正确传递", %{sid: sid, cwd: cwd} do
    assert Web.Terminal.exec(sid, cwd, "sh -c 'exit 7'", @timeout).exit == 7
    assert Web.Terminal.exec(sid, cwd, "true", @timeout).exit == 0
    assert Web.Terminal.exec(sid, cwd, "false", @timeout).exit == 1
  end

  test "失败命令的 exit 与大输出的句柄可同时拿到（中段内容只在原文里）", %{sid: sid, cwd: cwd} do
    # 中段标记由 shell 运行时生成：命令回显里只有字面量 $T，不是值。
    # 否则"预览里看不到"会被命令回显污染成假命题（PTY 会回显整条命令）。
    #
    # 用子 shell（圆括号）承载 exit 2：在持久 PTY 里直接 exit 会连 shell 一起结束。
    script =
      ~S|( for i in $(seq 1 1500); do echo "Compiling mod_$i.ex ... ok"; done; | <>
        ~S|T=$(date +%s%N); echo "MIDDLE-$T-END"; | <>
        ~S|for i in $(seq 1 3000); do echo "Compiling mod_$i.ex ... ok"; done; exit 2 )|

    result = Web.Terminal.exec(sid, cwd, script, @timeout)

    assert result.exit == 2
    # 头尾预览看不到中段（这正是要修的病）
    refute Regex.match?(~r/MIDDLE-\d+-END/, result.output)

    # 但句柄读回完整原文，中段在里面
    [id] = Spill.handles_in(result.output)
    recovered = read_all(id)

    assert Regex.match?(~r/MIDDLE-\d+-END/, recovered)
    assert byte_size(recovered) == stated_original(result.output)
  end

  test "在持久 PTY 里跑失败命令不会把 shell 一起结束", %{sid: sid, cwd: cwd} do
    assert Web.Terminal.exec(sid, cwd, "( exit 3 )", @timeout).exit == 3
    assert Web.Terminal.exec(sid, cwd, "echo alive", @timeout).output =~ "alive"
  end

  # ── 手动终端上下文（另一条捕获路径）────────────────────────────────
  #
  # 手动上下文有 500ms 静默后自动 flush 的定时器；测试必须在输出仍在流动时
  # 取走它，否则定时器会先把它写进 session。故用「有界但持续」的输出：
  # 每轮之间只停 50ms（<< 500ms），定时器不会触发，取走是确定性的。
  @tag :slow
  test "手动上下文的句柄同样指向非空对象", %{sid: sid} do
    Web.Terminal.input(sid, "for i in $(seq 1 40); do seq 1 3000; sleep 0.05; done\n")
    Process.sleep(1_500)

    {:ok, context} = Web.Terminal.take_context(sid)
    Web.Terminal.interrupt(sid)

    assert context =~ "手动终端上下文"
    assert context =~ "截断: 省略 "
    assert byte_size(context) < 17_000

    [id] = Spill.handles_in(context)
    {:ok, meta} = Spill.stat(id)

    assert meta.bytes > 0, "句柄指向了空对象（标记在撒谎）"
    assert meta.bytes == stated_original(context)

    {:ok, page} = Spill.read(id, offset: 0, max_bytes: 200)
    assert byte_size(page.text) > 0
  end
end
