defmodule Newbee.Spill do
  @moduledoc """
  无损溢出存储（DESIGN §6.2「长输出写文件回路径+行数摘要」的运行时落位）。

  截断本身保留——上下文必须省；但被截掉的原文一律先按内容寻址落盘，
  标记里回一个**可执行的**回读句柄 `spill://<id>`（`Newbee.read/1` 分页服务）。
  于是「省 token」与「不丢证据」不再互斥。

  ```text
  <global_root>/spill/
  ├── objects/<aa>/<sha256>.txt   # 内容寻址原文（只写不改）
  ├── tmp/<uniq>.part             # 流式写入中间态，finish 后 rename
  └── ledger.jsonl                # 追加审计（fail-open，坏行忽略）
  ```

  五条纪律（与 `Newbee.Archive` 同族）：

  - **内容寻址**：id = sha256(**存下来的**字节)。命中同名文件时按字节重算校验，
    不符 = **完整性失败**（不是缓存命中），必须报错而不是静默复用；
  - **原子落盘**：先写 tmp 再 rename；崩在中途只留无主 `.part`，永不产生半个对象；
  - **上限守护**：单对象超过 `max_object_bytes` 后停写，但仍**继续统计真实字节数**，
    返回 `partial: true`——宁可标注"只存了前 N 字节"，也不谎称完整；
  - **O(1) 内存**：`open_stream/1` + `push/2` + `finish/1` 供流式生产者使用
    （跑几小时的构建也不会把整份输出读进内存）；
  - **fail-open**：任何异常返回 `{:error, reason}`，调用方保持原有截断行为，
    绝不让"省 token 的优化"变成"工具调用失败"。

  与 `Newbee.Truncate` 的分工：本模块只管**存与取**，不做任何展示决策；
  预览切割与标记渲染在 `Newbee.Truncate`（依赖方向单一）。
  """

  @objects "objects"
  @tmp "tmp"
  @ledger "ledger.jsonl"

  @id_re ~r|^[a-f0-9]{16,64}$|
  @handle_re ~r|spill://([a-f0-9]{16,64})|

  # 单对象上限：超过后停写但继续计数，避免跑飞的进程把磁盘写满。
  @max_object_bytes 64 * 1024 * 1024

  # 分页回读预算（表头预留算在预算内，避免"读了 16KB 却返回 16KB+表头"）。
  @read_bytes 16 * 1024
  @read_lines 500
  @read_reserve 256

  def max_object_bytes, do: @max_object_bytes
  def read_bytes, do: @read_bytes
  def read_lines, do: @read_lines

  # ── 路径与形状 ──

  @doc "Spill 根目录（测试可经 `:global_root_override` 重定向）。"
  def root, do: Path.join(Newbee.GlobalStore.root(), "spill")

  @doc "内容寻址 id 形状校验（小写 hex 16..64）。"
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_re, id)

  @doc "内容寻址对象路径；id 非法返回 nil。"
  def object_path(id) when is_binary(id), do: object_path_or_nil(id)

  def object_path(_), do: nil

  defp object_path_or_nil(id) do
    if valid_id?(id) do
      Path.join([root(), @objects, String.slice(id, 0, 2), id <> ".txt"])
    end
  end

  @doc "内容寻址 id（sha256 小写 hex）。"
  def id_for(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc "行数口径：换行符数 + 1（与 `DEE.Result` 历史口径一致）。"
  def count_lines(bin) when is_binary(bin), do: newline_count(bin) + 1

  @doc "提取文本里出现的 spill 句柄（去重，保持出现顺序）。"
  def handles_in(text) when is_binary(text) do
    @handle_re
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  def handles_in(_), do: []

  # ── 写入 ──

  @doc """
  落盘一段已在内存中的文本。返回 `{:ok, info}`，`info` 形如
  `%{id:, path:, bytes:, stored:, partial:}`；失败返回 `{:error, reason}`。
  """
  def store(text, opts \\ []) when is_binary(text) do
    case open_stream(opts) do
      {:ok, handle} -> handle |> push(text) |> finish()
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:spill_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:spill_failed, {kind, reason}}}
  end

  @doc """
  开始一次流式落盘（O(1) 内存）。返回 handle 交给 `push/2`；
  必须以 `finish/1` 或 `abort/1` 收尾。
  """
  def open_stream(opts \\ []) do
    tmp = tmp_path()
    max_bytes = Keyword.get(opts, :max_object_bytes, @max_object_bytes)

    with :ok <- mkdir(Path.dirname(tmp)),
         {:ok, fd} <- open_tmp(tmp) do
      {:ok,
       %{
         fd: fd,
         tmp: tmp,
         hash: :crypto.hash_init(:sha256),
         bytes: 0,
         stored: 0,
         # 口径：行数 = 换行符数 + 1（空文档也算 1 行），与 count_lines/1 一致，
         # 这样流式累加的 lines 与「拼接后一次性 count_lines」逐字节等价。
         lines: 1,
         max_bytes: max_bytes,
         opts: opts,
         failed: nil
       }}
    end
  rescue
    e -> {:error, {:spill_open_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:spill_open_failed, {kind, reason}}}
  end

  @doc "推入一块数据。即使已失败/已达上限，也继续统计真实字节数与行数。"
  def push(handle, data) when is_binary(data) do
    handle = %{
      handle
      | bytes: handle.bytes + byte_size(data),
        lines: handle.lines + newline_count(data)
    }

    cond do
      handle.failed != nil -> handle
      handle.stored >= handle.max_bytes -> handle
      true -> write_chunk(handle, data)
    end
  rescue
    e -> %{handle | failed: Exception.message(e)}
  catch
    kind, reason -> %{handle | failed: {kind, reason}}
  end

  @doc "结束流：sync + close + promote 到内容地址。返回 `{:ok, info}` | `{:error, reason}`。"
  def finish(%{failed: reason} = handle) when not is_nil(reason) do
    cleanup(handle)
    {:error, {:spill_stream_failed, reason}}
  end

  def finish(handle) do
    case :file.sync(handle.fd) do
      :ok ->
        case :file.close(handle.fd) do
          :ok ->
            promote(handle)

          {:error, reason} ->
            cleanup(handle, false)
            {:error, {:spill_close_failed, reason}}
        end

      {:error, reason} ->
        cleanup(handle)
        {:error, {:spill_sync_failed, reason}}
    end
  rescue
    e ->
      cleanup(handle)
      {:error, {:spill_finish_failed, Exception.message(e)}}
  catch
    kind, reason ->
      cleanup(handle)
      {:error, {:spill_finish_failed, {kind, reason}}}
  end

  @doc """
  放弃一次流式写入（关 fd、删 tmp、不留对象）。

  幂等且对畸形 handle 安全：`finish/1` 之后返回的 info map 没有 `:fd`，
  重复 abort 必须是无害的 no-op，而不是抛 KeyError。
  """
  def abort(handle) when is_map(handle) do
    close_fd(Map.get(handle, :fd))
    rm_tmp(Map.get(handle, :tmp))
    :ok
  end

  def abort(_handle), do: :ok

  # ── 读取 ──

  @doc """
  分页回读。`opts[:offset]` 字节偏移（默认 0）。

  返回 `{:ok, %{text:, offset:, next_offset:, bytes:, lines:, eof:, total_bytes:}}`
  或 `{:error, reason}`。切割按整行优先、并在 UTF-8 边界收尾，
  返回值永不含切割本身引入的替换字符。
  """
  def read(id, opts \\ []) do
    if valid_id?(id) do
      do_read(object_path(id), opts)
    else
      {:error, {:bad_spill_id, id}}
    end
  rescue
    e -> {:error, {:spill_read_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:spill_read_failed, {kind, reason}}}
  end

  @doc "对象元信息（只看 stat，不读内容）。"
  def stat(id) do
    with true <- valid_id?(id),
         path when is_binary(path) <- object_path(id),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path) do
      {:ok, %{id: id, path: path, bytes: size}}
    else
      _ -> {:error, :spill_not_found}
    end
  end

  @doc """
  完整性复核：对象文件名即内容 sha256，命中同名文件时按字节重算校验。

  字节不符 = 完整性失败（不是缓存命中），必须报错——这是"落盘可信"的前提。
  """
  def verify_object(path, id) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        if hash_file(path) == id, do: :ok, else: {:error, {:spill_integrity, path}}

      {:ok, %{type: type}} ->
        {:error, {:spill_object_not_regular, path, type}}

      {:error, reason} ->
        {:error, {:spill_object_unreadable, path, reason}}
    end
  end

  # ── 内部：写入 ──

  defp open_tmp(tmp) do
    case :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]) do
      {:ok, fd} -> {:ok, fd}
      {:error, reason} -> {:error, {:spill_tmp_failed, reason}}
    end
  end

  defp write_chunk(handle, data) do
    room = handle.max_bytes - handle.stored
    chunk = if byte_size(data) <= room, do: data, else: binary_part(data, 0, room)

    case :file.write(handle.fd, chunk) do
      :ok ->
        %{
          handle
          | hash: :crypto.hash_update(handle.hash, chunk),
            stored: handle.stored + byte_size(chunk)
        }

      {:error, reason} ->
        %{handle | failed: reason}
    end
  rescue
    e -> %{handle | failed: Exception.message(e)}
  end

  defp promote(handle) do
    id = :crypto.hash_final(handle.hash) |> Base.encode16(case: :lower)
    path = object_path(id)

    with {:ok, path} <- ensure_object_path(path),
         :ok <- settle(handle.tmp, path, id) do
      info = %{
        id: id,
        path: path,
        bytes: handle.bytes,
        stored: handle.stored,
        lines: handle.lines,
        partial: handle.stored < handle.bytes
      }

      log_ledger(info, handle.opts)
      {:ok, info}
    else
      {:error, reason} ->
        cleanup(handle, false)
        {:error, reason}
    end
  end

  defp ensure_object_path(nil), do: {:error, :spill_bad_object_path}
  defp ensure_object_path(path), do: mkdir(Path.dirname(path)) |> ok_then(path)

  defp ok_then(:ok, path), do: {:ok, path}
  defp ok_then({:error, reason}, _path), do: {:error, reason}

  defp settle(tmp, path, id) do
    if File.regular?(path) do
      discard(tmp, path, id)
    else
      case File.rename(tmp, path) do
        :ok -> :ok
        {:error, reason} -> settle_failed_rename(tmp, path, id, reason)
      end
    end
  end

  # 并发下同名对象可能刚被别人建好：按完整性复核处理，通过则丢弃自己的 tmp。
  defp settle_failed_rename(tmp, path, id, reason) do
    if File.regular?(path) do
      discard(tmp, path, id)
    else
      {:error, {:spill_promote_failed, path, reason}}
    end
  end

  defp discard(tmp, path, id) do
    case verify_object(path, id) do
      :ok ->
        _ = File.rm(tmp)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup(handle), do: cleanup(handle, true)

  defp cleanup(handle, close?) do
    if close?, do: close_fd(Map.get(handle, :fd))
    rm_tmp(Map.get(handle, :tmp))
    :ok
  end

  defp close_fd(fd) when is_port(fd) or is_tuple(fd), do: _ = :file.close(fd)
  defp close_fd(_fd), do: :ok

  defp rm_tmp(path) when is_binary(path), do: _ = File.rm(path)
  defp rm_tmp(_path), do: :ok

  defp tmp_path do
    name =
      "spill-" <>
        Integer.to_string(System.unique_integer([:positive, :monotonic])) <>
        "-" <> System.pid() <> ".part"

    Path.join(Path.join(root(), @tmp), name)
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:spill_dir_failed, dir, reason}}
    end
  end

  # ── 内部：读取 ──

  defp do_read(path, opts) do
    offset = opts |> Keyword.get(:offset, 0) |> to_offset()
    budget = max(Keyword.get(opts, :max_bytes, @read_bytes) - @read_reserve, 1)
    line_budget = max(Keyword.get(opts, :max_lines, @read_lines) - 2, 1)

    case safe_size(path) do
      {:ok, size} when offset > size ->
        {:error, {:offset_past_end, offset, size}}

      {:ok, size} ->
        case read_chunk(path, offset, min(budget, size - offset), line_budget) do
          {:ok, chunk} -> {:ok, Map.put(chunk, :total_bytes, size)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_size(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} -> {:ok, size}
      {:ok, %{type: type}} -> {:error, {:spill_object_not_regular, path, type}}
      {:error, :enoent} -> {:error, :spill_not_found}
      {:error, reason} -> {:error, {:spill_object_unreadable, path, reason}}
    end
  end

  defp read_chunk(_path, _offset, 0, _line_budget), do: {:ok, empty_chunk(0)}

  defp read_chunk(path, offset, want, line_budget) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          take_chunk(fd, path, offset, want, line_budget)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, {:spill_object_unreadable, path, reason}}
    end
  end

  defp take_chunk(fd, path, offset, want, line_budget) do
    case :file.pread(fd, offset, want) do
      {:ok, data} ->
        kept = data |> cap_lines(line_budget) |> utf8_prefix() |> snap_line()
        next = offset + byte_size(kept)

        {:ok,
         %{
           text: kept,
           offset: offset,
           next_offset: next,
           bytes: byte_size(kept),
           lines: count_lines(kept),
           eof: next >= file_size(path)
         }}

      :eof ->
        {:ok, empty_chunk(offset)}

      {:error, reason} ->
        {:error, {:spill_object_unreadable, path, reason}}
    end
  end

  defp empty_chunk(offset) do
    %{text: "", offset: offset, next_offset: offset, bytes: 0, lines: 0, eof: true}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # 截到第 line_budget 个换行符之后，保证一次回读不超行预算。
  defp cap_lines(data, line_budget) do
    case data |> :binary.matches("\n") |> Enum.at(line_budget - 1) do
      {pos, 1} -> binary_part(data, 0, pos + 1)
      _ -> data
    end
  end

  # 尽量在整行收尾；只有当行边界落在后半段时才对齐，避免超长行把分页切碎。
  defp snap_line(""), do: ""

  defp snap_line(data) do
    case data |> :binary.matches("\n") |> List.last() do
      {pos, 1} ->
        if pos + 1 >= div(byte_size(data), 2), do: binary_part(data, 0, pos + 1), else: data

      _ ->
        data
    end
  end

  # 回退最多 3 字节以避开被切碎的多字节字符；源本身非法 UTF-8 时保持原样
  # （不把"二进制输出"误判成"空"）。
  defp utf8_prefix(""), do: ""

  defp utf8_prefix(data) do
    size = byte_size(data)
    limit = min(3, size)

    case Enum.find(0..limit, fn back -> String.valid?(prefix_of(data, size - back)) end) do
      nil -> data
      back -> prefix_of(data, size - back)
    end
  end

  defp prefix_of(_data, len) when len <= 0, do: ""
  defp prefix_of(data, len), do: binary_part(data, 0, len)

  defp to_offset(value) when is_integer(value) and value >= 0, do: value
  defp to_offset(_), do: 0

  # ── 内部：杂项 ──

  defp newline_count(<<>>), do: 0
  defp newline_count(bin), do: bin |> :binary.matches("\n") |> length()

  defp hash_file(path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          hash_fd(fd, :crypto.hash_init(:sha256))
        after
          :file.close(fd)
        end

      {:error, _reason} ->
        nil
    end
  end

  defp hash_fd(fd, ctx) do
    case :file.read(fd, 1_048_576) do
      {:ok, data} -> hash_fd(fd, :crypto.hash_update(ctx, data))
      :eof -> :crypto.hash_final(ctx) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  # 账本只是审计线索，绝不因为写账本失败影响溢出本身。
  defp log_ledger(info, opts) do
    path = Path.join(root(), @ledger)
    line = Jason.encode_to_iodata!(ledger_entry(info, opts))

    with :ok <- mkdir(Path.dirname(path)),
         {:ok, fd} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      :file.write(fd, [line, "\n"])
      :file.close(fd)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp ledger_entry(info, opts) do
    %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "id" => info.id,
      "bytes" => info.bytes,
      "stored" => info.stored,
      "lines" => info.lines,
      "partial" => info.partial,
      "source" => to_string(Keyword.get(opts, :source, "unknown"))
    }
  end
end
