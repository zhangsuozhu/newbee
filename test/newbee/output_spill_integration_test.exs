defmodule Newbee.OutputSpillIntegrationTest do
  use ExUnit.Case, async: false

  alias Newbee.Spill

  # 复现原始病案：500 行正常 + ERROR 行 + 900 行正常，真实走 Run.sh。
  @err "ERROR: undefined function foo/1 (lib/core.ex:142)"

  defp failing_build_script do
    ~s"""
    { for i in $(seq 1 500); do echo "Compiling mod_$i.ex ... ok"; done
      echo "#{@err}"
      echo "make: *** [Makefile:12: build] Error 1"
      for i in $(seq 1 900); do echo "Compiling mod_$i.ex ... ok"; done
      exit 2; }
    """
  end

  defp read_all(id), do: do_read_all(id, 0, [])

  defp do_read_all(id, offset, acc) do
    {:ok, page} = Spill.read(id, offset: offset, max_bytes: 4_096)
    acc = [page.text | acc]
    if page.eof, do: IO.iodata_to_binary(Enum.reverse(acc)), else: do_read_all(id, page.next_offset, acc)
  end

  # 独立 oracle：直接问 shell 这条命令的 stdout 有多少字节。
  # 不依赖被测代码自报的任何数字。
  defp shell_byte_count(cmd) do
    %{output: out} = Newbee.Tools.Run.sh(cmd <> " | wc -c", shared_terminal: false)
    out |> String.trim() |> String.to_integer()
  end

  defp stated_original_bytes(rendered) do
    [_, stated] = Regex.run(~r/原文 (\d+) bytes/, rendered)
    String.to_integer(stated)
  end

  describe "端到端：真实规模" do
    test "标记自报的原文量 == shell 实测字节数 == 句柄对象字节数（三者一致）" do
      cmd = "seq 1 20000"
      true_size = shell_byte_count(cmd)

      %{exit: 0, output: output} = Newbee.Tools.Run.sh(cmd, shared_terminal: false)
      rendered = Newbee.DEE.Result.render(%{status: :ok, value: "", output: output})

      [id] = Spill.handles_in(rendered)
      {:ok, meta} = Spill.stat(id)

      assert meta.bytes == true_size
      assert stated_original_bytes(rendered) == true_size

      # 上下文确实省了（一个数量级）
      assert byte_size(rendered) < 9_000
      assert byte_size(rendered) * 10 < true_size
    end

    test "句柄指向最完整的原文，而不是上一层已截断的预览" do
      cmd = "seq 1 20000"
      true_size = shell_byte_count(cmd)

      %{output: output} = Newbee.Tools.Run.sh(cmd, shared_terminal: false)
      assert byte_size(output) < true_size

      rendered = Newbee.DEE.Result.render(%{status: :ok, value: "", output: output})
      [id] = Spill.handles_in(rendered)

      # 两层给出同一个句柄，一次跳转即可拿到全文
      assert Spill.handles_in(output) == [id]
      assert byte_size(read_all(id)) == true_size
    end

    test "旧标记的误导性措辞已消失" do
      %{output: output} = Newbee.Tools.Run.sh("seq 1 20000", shared_terminal: false)
      rendered = Newbee.DEE.Result.render(%{status: :ok, value: "", output: output})

      refute rendered =~ "用 binding 变量或写文件后再局部读取"
      refute rendered =~ "compressed:"
      refute rendered =~ "输出截断"
    end
  end

  describe "端到端：真实失败构建" do
    test "exit 仍然可见，且中段 ERROR 可经句柄逐字节读回" do
      %{exit: exit, output: output} = Newbee.Tools.Run.sh(failing_build_script(), shared_terminal: false)
      assert exit == 2
      assert output =~ "undefined function foo/1"

      rendered = Newbee.DEE.Result.render(%{status: :ok, value: "exit=#{exit}", output: output})

      # 头尾预览里依然看不到（截断本身没变，上下文该省还是省）
      refute rendered =~ "undefined function foo/1"

      # 但句柄读回的是完整原文，含那条唯一的 ERROR
      [id] = Spill.handles_in(rendered)
      recovered = read_all(id)
      assert recovered =~ @err
      assert recovered =~ "Error 1"

      # 预览是原文的真前缀 + 真后缀（不是凭空拼出来的）
      refute recovered == output
      assert byte_size(recovered) > byte_size(output)
    end
  end

  describe "端到端：Newbee.read(\"spill://…\")" do
    test "模型侧用统一接口读回原文，且带不可信信封" do
      %{output: output} = Newbee.Tools.Run.sh(failing_build_script(), shared_terminal: false)
      rendered = Newbee.DEE.Result.render(%{status: :ok, value: "", output: output})
      [id] = Spill.handles_in(rendered)

      assert {:ok, body} = Newbee.read("spill://" <> id)
      assert body =~ "trust=\"untrusted\""
      assert body =~ "origin=\"spill:"
      assert body =~ "total_bytes="
      assert body =~ "id=#{id}"
    end

    test "分页参数可用，且能一路读到 eof" do
      %{output: output} = Newbee.Tools.Run.sh("seq 1 20000", shared_terminal: false)
      rendered = Newbee.DEE.Result.render(%{status: :ok, value: "", output: output})
      [id] = Spill.handles_in(rendered)
      {:ok, meta} = Spill.stat(id)

      assert {:ok, first} = Newbee.read("spill://#{id}?offset=0&bytes=2048")
      assert first =~ "offset=0"
      assert first =~ "next_offset="
      refute first =~ "已到末尾"

      assert {:ok, last} = Newbee.read("spill://#{id}?offset=#{meta.bytes - 10}")
      assert last =~ "已到末尾"
    end

    test "不存在的 id 与裸 spill:// 都不炸" do
      assert {:error, {:spill_not_found, _}} = Newbee.read("spill://" <> String.duplicate("a", 64))
      assert {:ok, usage} = Newbee.read("spill://")
      assert usage =~ "spill://<id>"
    end
  end

  describe "fail-open" do
    test "落盘不可用时仍返回截断预览，并明说无法回读" do
      original = Application.get_env(:newbee, :global_root_override)
      Application.put_env(:newbee, :global_root_override, "/proc/self/mem/cannot-write")

      try do
        text = String.duplicate("line\n", 5_000)
        result = Newbee.Truncate.head_tail(text, max_bytes: 8_000)

        assert result.truncated
        assert result.handle == nil
        assert result.text =~ "原文已丢弃，无法回读"
        assert byte_size(result.text) < 8_500
      after
        if original,
          do: Application.put_env(:newbee, :global_root_override, original),
          else: Application.delete_env(:newbee, :global_root_override)
      end
    end
  end
end
