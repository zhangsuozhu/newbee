defmodule Newbee.SpillTest do
  use ExUnit.Case, async: true

  alias Newbee.Spill

  # 每个用例用唯一内容，避免同套件内内容寻址对象互相干扰。
  defp uniq(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp body(prefix, lines \\ 40) do
    Enum.map_join(1..lines, "\n", fn i -> "#{prefix} line #{i}" end) <> "\n"
  end

  # 按固定字节切块：保证所有字节都被 push（不丢换行、不重复）。
  defp chunks(text, size), do: do_chunks(text, size, [])

  defp do_chunks("", _size, acc), do: Enum.reverse(acc)
  defp do_chunks(bin, size, acc) when byte_size(bin) <= size, do: Enum.reverse([bin | acc])

  defp do_chunks(bin, size, acc) do
    head = binary_part(bin, 0, size)
    rest = binary_part(bin, size, byte_size(bin) - size)
    do_chunks(rest, size, [head | acc])
  end

  describe "store/2 与内容寻址" do
    test "落盘后可读回，id 即 sha256" do
      text = uniq("store-roundtrip") <> "\nhello\n"

      assert {:ok, info} = Spill.store(text, source: "test")
      assert info.id == :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      assert info.bytes == byte_size(text)
      assert info.stored == byte_size(text)
      refute info.partial
      assert File.regular?(info.path)

      assert {:ok, page} = Spill.read(info.id)
      assert page.text == text
      assert page.eof
      assert page.total_bytes == byte_size(text)
    end

    test "同内容二次落盘命中同一对象且完整性复核通过" do
      text = uniq("store-dedup") <> "\n"

      assert {:ok, first} = Spill.store(text)
      assert {:ok, second} = Spill.store(text)
      assert first.id == second.id
      assert first.path == second.path
    end

    test "同名对象字节不符 = 完整性失败，不是缓存命中" do
      text = uniq("store-integrity") <> "\n"
      assert {:ok, info} = Spill.store(text)

      # 篡改对象文件（长度不变），再落同一内容：必须报错而不是静默复用
      File.write!(info.path, String.duplicate("x", byte_size(text)))

      assert {:error, {:spill_integrity, _path}} = Spill.store(text)
    end

    test "超过单对象上限时停写但继续统计真实字节数（partial）" do
      text = String.duplicate("abcdefghij", 100)

      assert {:ok, info} = Spill.store(text, max_object_bytes: 64)
      assert info.partial
      assert info.bytes == 1000
      assert info.stored == 64

      assert {:ok, page} = Spill.read(info.id)
      assert page.total_bytes == 64
    end

    test "失败一律 fail-open：不合法 id / 不存在的对象" do
      assert {:error, {:bad_spill_id, "nope"}} = Spill.read("nope")
      assert {:error, {:bad_spill_id, nil}} = Spill.read(nil)
      assert {:error, :spill_not_found} = Spill.read(String.duplicate("a", 64))
    end
  end

  describe "流式写入" do
    test "open/push/finish 与一次性 store 得到同一 id（按字节切块）" do
      text = body(uniq("stream"))
      parts = chunks(text, 17)

      assert {:ok, handle} = Spill.open_stream(source: "test")
      handle = Enum.reduce(parts, handle, &Spill.push(&2, &1))
      assert {:ok, info} = Spill.finish(handle)

      assert IO.iodata_to_binary(parts) == text
      assert info.id == Spill.id_for(text)
      assert info.bytes == byte_size(text)

      assert {:ok, stored} = Spill.read(info.id)
      assert stored.text == text
    end

    test "流式统计与一次性统计等价" do
      text = String.duplicate("chunky\n", 500) <> "末尾无换行"
      parts = chunks(text, 7)

      assert {:ok, handle} = Spill.open_stream()
      handle = Enum.reduce(parts, handle, &Spill.push(&2, &1))
      assert {:ok, info} = Spill.finish(handle)

      assert info.bytes == byte_size(text)
      assert info.lines == Spill.count_lines(text)
      assert info.id == Spill.id_for(text)
    end

    test "abort 不留对象" do
      assert {:ok, handle} = Spill.open_stream()
      handle = Spill.push(handle, "discard me")
      tmp = handle.tmp
      assert File.regular?(tmp)

      assert :ok = Spill.abort(handle)
      refute File.exists?(tmp)
    end

    test "push 在超过上限后仍继续统计真实字节数" do
      assert {:ok, handle} = Spill.open_stream(max_object_bytes: 10)
      handle = Spill.push(handle, String.duplicate("a", 100))
      assert {:ok, info} = Spill.finish(handle)

      assert info.bytes == 100
      assert info.stored == 10
      assert info.partial
    end
  end

  describe "分页回读" do
    test "offset/next_offset/eof 串联可读回全文" do
      text = body(uniq("paging"), 400)
      assert {:ok, info} = Spill.store(text)

      {chunks, last} =
        Enum.reduce_while(1..50, {[], 0}, fn _i, {acc, offset} ->
          assert {:ok, page} = Spill.read(info.id, offset: offset, max_bytes: 1_024)
          acc = [page.text | acc]

          if page.eof do
            {:halt, {acc, page}}
          else
            assert page.next_offset > offset
            {:cont, {acc, page.next_offset}}
          end
        end)

      assert last.eof
      assert IO.iodata_to_binary(Enum.reverse(chunks)) == text
    end

    test "分页在 UTF-8 边界收尾，不引入替换字符" do
      text = String.duplicate("错误行：编译失败\n", 300)
      assert {:ok, info} = Spill.store(text)

      assert {:ok, page} = Spill.read(info.id, max_bytes: 1_000)
      refute String.contains?(page.text, "\uFFFD")
      assert String.valid?(page.text)
      assert page.lines <= Spill.read_lines()
    end

    test "行预算生效" do
      text = body(uniq("linebudget"), 200)
      assert {:ok, info} = Spill.store(text)
      assert {:ok, page} = Spill.read(info.id, max_lines: 10)
      assert page.lines <= 10
      refute page.eof
    end

    test "偏移越界报错；读到末尾返回 eof" do
      text = uniq("bounds") <> "\n"
      assert {:ok, info} = Spill.store(text)

      assert {:error, {:offset_past_end, 999, _size}} = Spill.read(info.id, offset: 999)

      assert {:ok, page} = Spill.read(info.id, offset: byte_size(text))
      assert page.text == ""
      assert page.eof
    end
  end

  describe "工具函数" do
    test "handles_in 去重并保持出现顺序" do
      a = String.duplicate("a", 20)
      b = String.duplicate("b", 20)
      text = ~s|x spill://#{a} y spill://#{b} z spill://#{a}|

      assert Spill.handles_in(text) == [a, b]
      assert Spill.handles_in("no handle here") == []
    end

    test "count_lines 与历史口径一致（= split 行数）" do
      for text <- ["", "a", "a\n", "a\nb", "a\nb\n"] do
        assert Spill.count_lines(text) == length(String.split(text, "\n")),
               "mismatch for #{inspect(text)}"
      end
    end

    test "stat 只看元信息" do
      text = uniq("stat") <> "\n"
      assert {:ok, info} = Spill.store(text)
      assert {:ok, meta} = Spill.stat(info.id)
      assert meta.bytes == byte_size(text)
      assert {:error, :spill_not_found} = Spill.stat("zzzz")
    end

    test "object_path 对非法 id 返回 nil" do
      assert Spill.object_path("nothex") == nil
      assert Spill.object_path(String.duplicate("a", 64)) =~ "/spill/objects/aa/"
    end
  end
end
