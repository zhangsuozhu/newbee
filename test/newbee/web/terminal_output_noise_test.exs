defmodule Newbee.Web.TerminalOutputNoiseTest do
  # 真 PTY，串行跑。这一组只钉「模型可见的命令结果里还剩什么」——
  # 回显、哨兵行、提示符、ANSI/退格/回车都必须消失。
  use ExUnit.Case, async: false

  alias Newbee.{Spill, Web}

  @timeout 60_000

  defp start_terminal(cwd) do
    sid = "test-noise-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _pid} = Web.Terminal.ensure(sid, cwd)
    assert {:ok, _info} = Web.Terminal.open(sid, cwd)
    sid
  end

  # 一个只有三次提交的临时仓库：内容与字节数都可控。
  defp init_repo do
    dir = Path.join(System.tmp_dir!(), "newbee-noise-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(dir)

    git = fn args ->
      {out, 0} =
        System.cmd("git", args,
          cd: dir,
          stderr_to_stdout: true,
          env: [
            {"GIT_AUTHOR_NAME", "t"},
            {"GIT_AUTHOR_EMAIL", "t@e"},
            {"GIT_COMMITTER_NAME", "t"},
            {"GIT_COMMITTER_EMAIL", "t@e"}
          ]
        )

      out
    end

    git.(["init", "-q"])

    for n <- 1..3 do
      File.write!(Path.join(dir, "f.txt"), "x#{n}")
      git.(["add", "f.txt"])
      git.(["commit", "-q", "-m", "c#{n}"])
    end

    dir
  end

  setup do
    dir = init_repo()
    sid = start_terminal(dir)
    on_exit(fn -> Web.Terminal.close(sid) end)
    %{sid: sid, cwd: dir}
  end

  test "git log --oneline -3 不含任何噪音，且不超过 400 字节", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "git log --oneline -3", @timeout)

    assert result.exit == 0
    assert byte_size(result.output) <= 400

    # 三类转义/控制字节：ESC、退格、回车
    refute :binary.match(result.output, <<27>>) != :nomatch
    refute :binary.match(result.output, <<8>>) != :nomatch
    refute :binary.match(result.output, <<13>>) != :nomatch

    # 哨兵、提示符、命令回显
    refute result.output =~ "newbee-done"
    refute result.output =~ "newbee-start"
    refute result.output =~ "bash-5.0$"
    refute result.output =~ "git log"

    # 三次提交都在（内容没被误删）
    assert result.output =~ "c3"
    assert result.output =~ "c1"
  end

  test "带色命令只回填 RED，不留 CSI 序列", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "printf '\\033[31mRED\\033[0m\\n'", @timeout)

    assert result.exit == 0
    assert result.output == "RED\n"
    refute :binary.match(result.output, <<27>>) != :nomatch
  end

  test "短命令无截断标记、不产生 spill 文件", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "printf 'hello\\nworld\\n'", @timeout)

    assert result.exit == 0
    assert result.output == "hello\nworld\n"
    refute result.output =~ "截断"
    refute result.output =~ "spill://"
    assert Spill.handles_in(result.output) == []
  end

  test "超预算输出：标记自报原文字节数与 spill 全文长度一致", %{sid: sid, cwd: cwd} do
    result = Web.Terminal.exec(sid, cwd, "seq 1 20000", @timeout)

    assert result.exit == 0
    assert result.output =~ "截断: 省略 "

    [_, stated] = Regex.run(~r/原文 (\d+) bytes/, result.output)
    stated = String.to_integer(stated)

    [id] = Spill.handles_in(result.output)
    {:ok, meta} = Spill.stat(id)

    assert meta.bytes == stated
    assert byte_size(read_all(id)) == stated

    # 原文里也不该混进哨兵或提示符
    full = read_all(id)
    refute full =~ "newbee-done"
    refute full =~ "bash-5.0$"
    refute :binary.match(full, <<27>>) != :nomatch
  end

  defp read_all(id), do: do_read_all(id, 0, [])

  defp do_read_all(id, offset, acc) do
    {:ok, page} = Spill.read(id, offset: offset, max_bytes: 4_096)
    acc = [page.text | acc]
    if page.eof, do: IO.iodata_to_binary(Enum.reverse(acc)), else: do_read_all(id, page.next_offset, acc)
  end
end
