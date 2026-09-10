defmodule Newbee.EventStore do
  @moduledoc """
  Event Store (DESIGN §4.6 / §11.1 P1) ⭐：**唯一同步事实写入**。

  - 追加写 JSONL + checksum frame：每行 `{"id","topic","data","at","crc"}`，
    crc 覆盖除自身外的全部字段，崩溃写一半的行在读取时被识别并截断；
  - 单调 `event_id`：由进程内原子计数 + 文件末行恢复，重启不回退；
  - durability 档位：`:event`（逐事件 fsync）| `:batch`（有界批量 fsync，默认）| `:os`（信任 OS）；
  - 一切状态变化先追加事件，落盘成功才算发生；Project Store 的
    manifest / projections 全部是事件流的派生快照，各自记录 checkpoint
    （已应用的事件水位）；恢复 = 从 checkpoint 重放；
  - 幂等：重复事件按 `event_id` / payload 内 `message_id` 去重（见 Agent.Protocol）；
  - 分段轮转：活动文件超过 `max_active_bytes`（默认 64 MB）即封段成
    `.newbee/events/seg-<seq>-<last_id>.jsonl.gz`，活动文件重新开始；封段只搬运
    整行事件（先 rename 再压缩，进程崩溃最多留下未压缩段，读取端两种都认），
    因此「事件流是唯一权威」不因轮转失效：`replay/2` 依旧按 id 升序读全量。

  每条总线两个域（§4.6）：durable 事实进本模块落盘；live 拦截点只走 Bus 不落盘。
  """

  use GenServer
  require Logger

  defstruct path: nil,
            io: nil,
            next_id: 1,
            durability: :batch,
            pending: 0,
            batch_size: 16,
            subscribers: [],
            dir: nil,
            seq: 0,
            bytes: 0,
            max_bytes: nil,
            max_segments: nil

  @flush_ms 200
  # 活动文件超过阈值即封段归档（gzip）：只限制「活动文件」大小，全部事件仍可从存档段重放。
  @default_max_active_bytes 64 * 1024 * 1024
  @gzip_chunk 1_048_576

  # ── API ──

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "追加事件。落盘（按 durability 档位）成功后返回 {:ok, event}。"
  def append(store, topic, data) when is_atom(topic) and is_map(data) do
    GenServer.call(store, {:append, topic, data})
  end

  @doc "当前水位（最后一条事件 id，空流为 0）。"
  def watermark(store), do: GenServer.call(store, :watermark)

  @doc """
  把内存状态与磁盘对齐（运维/恢复用）：重新读水位、重开活动文件句柄。

  用于**人工干预磁盘之后**：例如手工重编号活动文件、删除崩溃残留段、
  或在库重启前修好状态。只做「以磁盘为准」，不修改任何事件。
  """
  def resync(store), do: GenServer.call(store, :resync, 30_000)

  @doc """
  从 from_id（不含）开始重放事件流（按 id 升序）。坏帧截断后续读取。

  跨存档段：先读更旧的段再读活动文件；段名里带该段最后一条的事件 id，
  因此 `from_id` 已经越过整段时可以整段跳过（checkpoint 恢复不必读全量）。
  """
  def replay(path, from_id \\ 0) do
    segment_frames =
      path
      |> segments()
      |> Enum.reject(fn seg ->
        last = segment_last_id(seg)
        last > 0 and last <= from_id
      end)
      |> Enum.flat_map(&segment_frames/1)

    active_frames = path |> read_frames_with_offsets() |> Enum.map(&elem(&1, 0))

    (segment_frames ++ active_frames)
    |> Enum.filter(&(&1["id"] > from_id))
    |> Enum.map(&to_event/1)
  end

  @doc """
  只重放**末尾 n 条**事件（`replay/2 |> Enum.take(-n)` 的等值快路径）。

  大事件流（>100MB）下 `replay/2` 需要整文件读入 + 逐行解码，n 再小也躲不掉；
  本函数改用尾部窗口读取（见 `Newbee.JsonlTail`），代价只与 n 相关。

  语义：
  - 窗口内非末尾出现坏帧（真实损坏）→ 退回 `replay/2`，保持「首个坏帧之后全部丢弃」；
  - 末尾坏帧（崩溃半帧）→ 丢弃该行，与前向扫描一致；
  - 尾部窗口不足 n 条完整帧 → 退回 `replay/2`。
  """
  def replay_tail(path, n) when is_integer(n) and n > 0 do
    # 多取一行：崩溃半帧占位时仍能凑够 n 条
    case Newbee.JsonlTail.read_lines(path, n + 1, keep_partial: true) do
      {:ok, _lines, :whole} ->
        # 整个流都在窗口里：走全量语义
        replay(path) |> Enum.take(-n)

      {:ok, lines, :partial} ->
        case decode_lines(lines, n) do
          {:ok, frames} -> frames
          :short -> tail_across_segments(path, lines, n)
          :corrupt -> replay(path) |> Enum.take(-n)
        end

      {:error, reason} ->
        read_failure(path, reason)
    end
  end

  # 活动文件里凑不满 n 条（刚轮转完、或 n 很大）→ 向更旧的存档段继续取，顺序仍是旧→新。
  defp tail_across_segments(path, active_lines, n) do
    target = n + 1

    lines =
      path
      |> segments()
      |> Enum.reverse()
      |> Enum.reduce_while(active_lines, fn seg, acc ->
        if length(acc) >= target do
          {:halt, acc}
        else
          case segment_tail_lines(seg, target - length(acc) + 1) do
            {:ok, older} ->
              {:cont, older ++ acc}

            {:error, reason} ->
              Logger.warning("event store segment read failed #{seg}: #{inspect(reason)}")
              {:halt, acc}
          end
        end
      end)

    case decode_lines(lines, n) do
      {:ok, frames} -> frames
      _ -> replay(path) |> Enum.take(-n)
    end
  end

  # 解码窗口内的行：末尾坏帧丢弃（崩溃半帧），中间坏帧视为损坏；不足 n 条返回 :short。
  defp decode_lines(lines, n) do
    last = length(lines) - 1

    case Enum.reduce_while(Enum.with_index(lines), [], fn {line, idx}, acc ->
           case decode_frame(line) do
             {:ok, frame} -> {:cont, [frame | acc]}
             # 末尾坏帧 = 崩溃写一半：丢弃该行
             :bad when idx == last -> {:cont, acc}
             :bad -> {:halt, :corrupt}
           end
         end) do
      :corrupt ->
        :corrupt

      frames when length(frames) >= n ->
        {:ok, frames |> Enum.reverse() |> Enum.take(-n) |> Enum.map(&to_event/1)}

      _short ->
        :short
    end
  end

  # :enoent 是「还没建流」的正常情况（与 read_frames/1 一致，不打日志）
  defp read_failure(_path, :enoent), do: []

  defp read_failure(path, reason) do
    Logger.warning("event store read failed #{path}: #{inspect(reason)}")
    []
  end

  defp to_event(frame) do
    %{id: frame["id"], topic: String.to_atom(frame["topic"]), data: frame["data"], at: frame["at"]}
  end
  @doc "读取全部帧（含校验）：存档段（旧 → 新）+ 活动文件；每段内首个坏帧之后丢弃。"
  def read_frames(path) do
    (segments(path) |> Enum.flat_map(&segment_frames/1)) ++
      (path |> read_frames_with_offsets() |> Enum.map(&elem(&1, 0)))
  end

  # ── 存档段（轮转产物） ──

  @doc """
  存档段文件路径（旧 → 新）。同一段同时存在 `.gz` 与 `.jsonl` 时只取 `.gz`
  （压缩成功后才会删除源文件；崩溃最多留下未压缩段）。

  gzip 在途的 `*.tmp.*` 文件不是段（崩溃残留需人工清理），一律不参与读取。
  """
  def segments(path) do
    dir = segments_dir(path)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.contains?(&1, ".tmp."))
        |> Enum.filter(&String.starts_with?(&1, "seg-"))
        |> Enum.group_by(&segment_stem/1)
        |> Enum.map(fn {_stem, files} ->
          gz = Enum.find(files, &String.ends_with?(&1, ".gz"))
          Path.join(dir, gz || hd(files))
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end


  defp segments_dir(path), do: Path.join(Path.dirname(path), "events")

  defp segment_stem(name), do: name |> String.replace_suffix(".gz", "") |> Path.rootname()

  # 段名 seg-<seq>-<last_id>.jsonl[.gz]：用于整段跳过
  defp segment_last_id(path) do
    case Regex.run(~r/-(\d+)\.jsonl/, Path.basename(path)) do
      [_, id] -> String.to_integer(id)
      _ -> 0
    end
  end

  defp segment_frames(seg) do
    case read_segment_body(seg) do
      {:ok, body} ->
        body |> scan_lines(0, []) |> Enum.map(&elem(&1, 0))

      {:error, reason} ->
        Logger.warning("event store segment read failed #{seg}: #{inspect(reason)}")
        []
    end
  end

  defp read_segment_body(seg) do
    if String.ends_with?(seg, ".gz") do
      case File.read(seg) do
        {:ok, gz} ->
          try do
            {:ok, :zlib.gunzip(gz)}
          rescue
            e -> {:error, e}
          end

        err ->
          err
      end
    else
      File.read(seg)
    end
  end

  # ── 段内尾部读取（跨段取尾时用） ──

  # 取段末尾 k 行：.jsonl 走 JsonlTail，.gz 走流式解压（不整段解压进内存）。
  defp segment_tail_lines(seg, k) do
    if String.ends_with?(seg, ".gz") do
      gz_tail_lines(seg, k)
    else
      case Newbee.JsonlTail.read_lines(seg, k, keep_partial: true) do
        {:ok, lines, _coverage} -> {:ok, lines}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp gz_tail_lines(seg, k) do
    z = :zlib.open()

    try do
      # 31 = gzip 容器（不是裸 deflate）
      :ok = :zlib.inflateInit(z, 31)

      case :file.open(seg, [:read, :raw, :binary]) do
        {:ok, fd} ->
          try do
            gz_collect_tail(z, fd, <<>>, k, [])
          after
            :file.close(fd)
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, e}
    after
      _ =
        try do
          :zlib.inflateEnd(z)
        rescue
          _ -> :ok
        end

      :zlib.close(z)
    end
  end

  # acc 为新 → 旧的最后 k 行；pending 是尚未遇到换行的尾巴。
  defp gz_collect_tail(z, fd, pending, k, acc) do
    case :file.read(fd, @gzip_chunk) do
      {:ok, chunk} ->
        {acc, pending} = absorb_tail_lines(z, chunk, pending, k, acc)
        gz_collect_tail(z, fd, pending, k, acc)

      :eof ->
        acc = if pending == "", do: acc, else: Enum.take([pending | acc], k)
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp absorb_tail_lines(z, chunk, pending, k, acc) do
    data = pending <> :zlib.inflate(z, chunk)
    parts = :binary.split(data, "\n", [:global])
    pending = if List.last(parts) == "", do: "", else: List.last(parts)
    complete = Enum.drop(parts, -1)
    {Enum.take(Enum.reverse(complete) ++ acc, k), pending}
  end

  # 返回 [{frame, end_offset}]：end_offset 为该帧（含换行）之后的字节位置。
  # 逐行扫描同时累计偏移——崩溃写一半的尾行（无换行或 crc 坏）终止扫描。
  defp read_frames_with_offsets(path) do
    case File.read(path) do
      {:ok, body} ->
        scan_lines(body, 0, [])

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("event store read failed #{path}: #{inspect(reason)}")
        []
    end
  end

  defp scan_lines(<<>>, _offset, acc), do: Enum.reverse(acc)

  defp scan_lines(body, offset, acc) do
    case :binary.split(body, "\n") do
      [line, rest] ->
        case decode_frame(line) do
          {:ok, frame} ->
            line_bytes = byte_size(line) + 1
            scan_lines(rest, offset + line_bytes, [{frame, offset + line_bytes} | acc])

          :bad ->
            Enum.reverse(acc)
        end

      # 尾行无换行：只有完整帧才算数（崩溃半帧直接丢弃）
      [line] ->
        case decode_frame(line) do
          {:ok, frame} ->
            end_offset = offset + byte_size(line)
            Enum.reverse([{frame, end_offset} | acc])

          :bad ->
            Enum.reverse(acc)
        end
    end
  end

  @doc "订阅追加事件（进程收到 {:event_store_appended, event}）。"
  def subscribe(store), do: GenServer.call(store, {:subscribe, self()})

  # ── GenServer ──
  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    durability = Keyword.get(opts, :durability, :batch)

    # 恢复 next_id：优先活动文件末行；活动文件为空（刚轮转完/崩溃）时从最新存档段续，
    # 否则 id 会从 1 重来（会破坏 checkpoint 与幂等去重）。
    frames_with_offsets = read_frames_with_offsets(path)

    next_id =
      case List.last(frames_with_offsets) do
        {frame, _} -> frame["id"] + 1
        nil -> last_segment_id(path) + 1
      end

    # 崩溃遗留半帧：截断到最后一个好帧
    truncate_to_valid(path, frames_with_offsets)

    {:ok, io} = File.open(path, [:append, :raw])

    state = %__MODULE__{
      path: path,
      io: io,
      next_id: next_id,
      durability: durability,
      batch_size: Keyword.get(opts, :batch_size, 16),
      dir: segments_dir(path),
      seq: next_segment_seq(path),
      bytes: active_bytes(path),
      max_bytes: normalize_max_bytes(config(opts, :max_active_bytes, @default_max_active_bytes)),
      max_segments: config(opts, :max_segments, nil)
    }

    if durability == :batch, do: Process.send_after(self(), :flush, @flush_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:append, topic, data}, _from, state) do
    event = %{
      id: state.next_id,
      topic: topic,
      data: data,
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    line = encode_frame(event)
    :ok = :file.write(state.io, [line, "\n"])

    state = %{
      state
      | next_id: state.next_id + 1,
        pending: state.pending + 1,
        bytes: state.bytes + IO.iodata_length([line, "\n"])
    }

    state =
      case state.durability do
        :event -> fsync(state)
        :batch -> if(state.pending >= state.batch_size, do: fsync(state), else: state)
        :os -> state
      end

    # 超过阈值就把整个活动文件封段（只在写完整行之后做，段内永远是完整帧）。
    state = maybe_rotate(state)

    for pid <- state.subscribers, do: send(pid, {:event_store_appended, event})

    {:reply, {:ok, event}, state}
  end
  # 以磁盘为准对齐内存状态：人工干预（重编号/清理残留）之后调用。
  # 水位取「活动文件末条」与「最新存档段末条」的较大者——并发追加期间做修复也不会回退。
  def handle_call(:resync, _from, state) do
    state = fsync(state)
    if state.io, do: :file.close(state.io)

    frames_with_offsets = read_frames_with_offsets(state.path)

    file_last_id =
      case List.last(frames_with_offsets) do
        {frame, _} -> frame["id"]
        nil -> 0
      end

    next_id = max(file_last_id, last_segment_id(state.path)) + 1

    {:ok, io} = File.open(state.path, [:append, :raw])

    {:reply, {:ok, next_id - 1},
     %{state | io: io, next_id: next_id, pending: 0, bytes: active_bytes(state.path)}}
  end


  def handle_call(:watermark, _from, state), do: {:reply, state.next_id - 1, state}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info(:flush, state) do
    state = fsync(state)
    if state.durability == :batch, do: Process.send_after(self(), :flush, @flush_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.io, do: fsync(state)
    :ok
  end

  # ── frame codec ──

  defp encode_frame(%{id: id, topic: topic, data: data, at: at}) do
    payload = %{"id" => id, "topic" => to_string(topic), "data" => encodable(data), "at" => at}
    crc = frame_crc(payload)
    Jason.encode_to_iodata!(Map.put(payload, "crc", crc))
  end

  defp decode_frame(line) do
    with {:ok, %{"id" => id, "topic" => t, "data" => d, "at" => at, "crc" => crc} = f} <-
           Jason.decode(line),
         true <- is_integer(id),
         ^crc <- frame_crc(Map.delete(f, "crc")) do
      {:ok, %{"id" => id, "topic" => t, "data" => d, "at" => at}}
    else
      _ -> :bad
    end
  end

  defp frame_crc(payload_without_crc) do
    :erlang.crc32(Jason.encode_to_iodata!(payload_without_crc))
  end

  # 事件 data 常含元组/原子——递归转 JSON 可编码形态
  defp encodable(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&encodable/1)
  defp encodable(v) when is_list(v), do: Enum.map(v, &encodable/1)

  defp encodable(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {to_string(k), encodable(val)} end)
  end

  defp encodable(v) when is_atom(v), do: to_string(v)
  defp encodable(v), do: v

  # ── 轮转 / 保留 ──

  defp config(opts, key, default) do
    Keyword.get(opts, key) ||
      (Application.get_env(:newbee, __MODULE__, []) |> Keyword.get(key)) ||
      default
  end

  defp normalize_max_bytes(nil), do: @default_max_active_bytes
  defp normalize_max_bytes(0), do: :infinity
  defp normalize_max_bytes(:infinity), do: :infinity
  defp normalize_max_bytes(n) when is_integer(n) and n > 0, do: n

  defp active_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp maybe_rotate(%{max_bytes: :infinity} = state), do: state

  defp maybe_rotate(%{bytes: bytes, max_bytes: max} = state)
       when is_integer(max) and bytes >= max,
       do: rotate(state)

  defp maybe_rotate(state), do: state

  # 封段：fsync → 关闭 → 原子 rename 成段文件 → gzip → 重开活动文件。
  # 顺序保证崩溃安全：rename 之后活动文件不存在（重启时新建，历史都在段里）；
  # gzip 失败就保留未压缩段（读取端 .jsonl/.gz 都认）。
  # 封段：fsync → 关闭 → 原子 rename 成段文件 → gzip → 重开活动文件。
  # 顺序保证崩溃安全：rename 之后活动文件不存在（重启时新建，历史都在段里）；
  # gzip 失败就保留未压缩段（读取端 .jsonl/.gz 都认）。
  # 任何异常都不许冒泡：轮转失败只该降级，不该让事件库进程崩溃（init 会读不到水位）。
  defp rotate(state) do
    last_id = state.next_id - 1

    if last_id < 1 do
      %{state | bytes: 0}
    else
      try do
        state = fsync(state)
        :ok = :file.close(state.io)
        File.mkdir_p!(state.dir)

        seg = Path.join(state.dir, "seg-#{pad_seq(state.seq)}-#{last_id}.jsonl")

        case File.rename(state.path, seg) do
          :ok ->
            gzip_segment(seg)
            fsync_dir(state.dir)
            state = reopen(state)
            Logger.info("event store rotated #{state.path} -> #{seg} (watermark #{last_id})")
            prune_segments(state)
            %{state | seq: state.seq + 1, bytes: 0}

          {:error, reason} ->
            Logger.warning("event store rotate failed: #{inspect(reason)}")
            state = reopen(state)
            %{state | bytes: 0}
        end
      rescue
        e ->
          Logger.error("event store rotate crashed: #{Exception.message(e)}")
          reopen(state)
      end
    end
  end


  defp reopen(state) do
    {:ok, io} = File.open(state.path, [:append, :raw])
    %{state | io: io}
  end

  defp pad_seq(seq), do: seq |> Integer.to_string() |> String.pad_leading(6, "0")

  defp next_segment_seq(path) do
    path
    |> segments()
    |> Enum.map(fn seg ->
      case Regex.run(~r/seg-(\\d+)-/, Path.basename(seg)) do
        [_, seq] -> String.to_integer(seq)
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  # 活动文件为空时的水位来源：最新存档段（轮转后崩溃/刚启动都靠它续 id）
  defp last_segment_id(path) do
    case path |> segments() |> List.last() do
      nil ->
        0

      seg ->
        case segment_tail_lines(seg, 4) do
          {:ok, lines} ->
            lines
            |> Enum.reverse()
            |> Enum.find_value(0, fn line ->
              case decode_frame(line) do
                {:ok, frame} -> frame["id"]
                :bad -> nil
              end
            end)

          {:error, _} ->
            0
        end
    end
  end

  # gzip 段文件（流式，避免整段进内存）；失败一律清理临时文件并保留 .jsonl 原文件。
  defp gzip_segment(seg) do
    gz = seg <> ".gz"
    tmp = seg <> ".tmp.gz"

    result =
      try do
        with {:ok, out} <- :file.open(tmp, [:write, :raw, :binary]) do
          stream =
            try do
              stream_gzip(seg, out)
            after
              :file.close(out)
            end

          with :ok <- stream,
               :ok <- File.rename(tmp, gz),
               :ok <- File.rm(seg) do
            :ok
          end
        end
      rescue
        e -> {:error, e}
      end

    if result != :ok do
      Logger.warning("event store segment gzip failed (keep plain segment): #{inspect(result)}")
      File.rm(tmp)
    end

    :ok
  end


  defp stream_gzip(seg, out) do
    z = :zlib.open()

    try do
      # 31 = gzip 容器
      :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

      case :file.open(seg, [:read, :raw, :binary]) do
        {:ok, fd} ->
          try do
            gzip_chunks(z, fd, out)
          after
            :file.close(fd)
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, e}
    after
      _ =
        try do
          :zlib.deflateEnd(z)
        rescue
          _ -> :ok
        end

      :zlib.close(z)
    end
  end

  defp gzip_chunks(z, fd, out) do
    case :file.read(fd, @gzip_chunk) do
      {:ok, chunk} ->
        case :file.write(out, :zlib.deflate(z, chunk, :none)) do
          :ok -> gzip_chunks(z, fd, out)
          err -> err
        end

      :eof ->
        :file.write(out, :zlib.deflate(z, <<>>, :finish))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 可选保留策略：只保留最新的 max_segments 个存档段（默认 nil = 全部保留）。
  defp prune_segments(%{max_segments: nil}), do: :ok

  defp prune_segments(%{max_segments: max} = state) when is_integer(max) and max >= 0 do
    archived = segments(state.path)

    if length(archived) > max do
      archived
      |> Enum.take(length(archived) - max)
      |> Enum.each(fn seg ->
        Logger.warning("event store pruning oldest segment #{seg}")
        File.rm(seg)
      end)
    end

    :ok
  end

  defp prune_segments(_state), do: :ok

  defp fsync_dir(dir) do
    case File.open(dir, [:read]) do
      {:ok, io} ->
        _ = :file.sync(io)
        File.close(io)

      _ ->
        :ok
    end
  end

  defp fsync(%{pending: 0} = state), do: state

  defp fsync(state) do
    :ok = :file.sync(state.io)
    %{state | pending: 0}
  end

  # 崩溃写了一半的帧：按字节截断到最后一个好帧末尾
  defp truncate_to_valid(path, frames_with_offsets) do
    valid_bytes =
      case List.last(frames_with_offsets) do
        nil -> 0
        {_frame, end_offset} -> end_offset
      end

    case File.stat(path) do
      {:ok, %{size: size}} when size > valid_bytes and valid_bytes >= 0 ->
        {:ok, io} = File.open(path, [:read, :write, :raw])
        {:ok, _} = :file.position(io, valid_bytes)
        :ok = :file.truncate(io)
        File.close(io)

      _ ->
        :ok
    end
  end
end
