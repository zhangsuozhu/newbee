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
  - 幂等：重复事件按 `event_id` / payload 内 `message_id` 去重（见 Agent.Protocol）。

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
            subscribers: []

  @flush_ms 200

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

  @doc "从 from_id（不含）开始重放事件流（按 id 升序）。坏帧截断后续读取。"
  def replay(path, from_id \\ 0) do
    path
    |> read_frames()
    |> Enum.filter(&(&1["id"] > from_id))
    |> Enum.map(fn f -> %{id: f["id"], topic: String.to_atom(f["topic"]), data: f["data"], at: f["at"]} end)
  end

  @doc "读取全部帧（含校验）；首个坏帧之后的全部丢弃（崩溃截断恢复）。"
  def read_frames(path) do
    path
    |> read_frames_with_offsets()
    |> Enum.map(&elem(&1, 0))
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

    # 恢复 next_id：读文件末行（坏帧截断）
    frames_with_offsets = read_frames_with_offsets(path)

    next_id =
      case List.last(frames_with_offsets) do
        nil -> 1
        {frame, _} -> frame["id"] + 1
      end

    # 崩溃遗留半帧：截断到最后一个好帧
    truncate_to_valid(path, frames_with_offsets)

    {:ok, io} = File.open(path, [:append, :raw])

    state = %__MODULE__{
      path: path,
      io: io,
      next_id: next_id,
      durability: durability,
      batch_size: Keyword.get(opts, :batch_size, 16)
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

    state = %{state | next_id: state.next_id + 1, pending: state.pending + 1}

    state =
      case state.durability do
        :event -> fsync(state)
        :batch -> if(state.pending >= state.batch_size, do: fsync(state), else: state)
        :os -> state
      end

    for pid <- state.subscribers, do: send(pid, {:event_store_appended, event})

    {:reply, {:ok, event}, state}
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
