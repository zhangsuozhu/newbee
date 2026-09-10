defmodule Newbee.EventLog do
  @moduledoc """
  事件溯源日志 (DESIGN §6.5) ⭐：订阅总线，把 durable 事件追加到
  `~/.newbee/events.jsonl`。日志是进化的审计网与反事实回放的数据源：
  任意时间点的环境状态可重建，adapter 的"证据"来自这里。

  订阅过滤：只落盘 durable 事实（turn/*、tool/*、user/*、assistant/*、
  audit、rule_hit、progress、goal_*），不落盘高频 live 流（:text/:reasoning
  的每个 delta——它们由 session transcript 记录）。
  """

  use GenServer

  @path Path.join(System.user_home!(), ".newbee/events.jsonl")
  @max_bytes 50_000_000

  @durable ~w(
    turn_end usage tool_start tool_result tool_error rule_hit prompt_injection audit
    goal_start goal_round goal_retry goal_done goal_ask goal_cancelled goal_limit
    progress progress_stall final_check interrupted error done ask
    evolution_published evolution_rejected snapshot_created snapshot_restored
  )a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  读取事件（新→旧，最多 n 条，默认 1000）。过滤: 按 topic 列表。

  只从文件尾部窗口读取（见 `Newbee.JsonlTail`）：全局日志会涨到几十 MB，
  全量读入 + 逐行解码不值得。带 topic 过滤时窗口内匹配可能不足 n 条，
  此时返回窗口内的全部匹配（需要更早的匹配请用 `query/1`）。
  """
  def read(n \\ 1000, topics \\ nil) do
    case Newbee.JsonlTail.read_lines(@path, max(n, 1), keep_partial: false) do
      {:ok, lines, _coverage} ->
        lines
        |> Enum.reverse()
        |> Enum.flat_map(&decode_event(&1, topics))
        |> Enum.take(n)

      _ ->
        []
    end
  end

  defp decode_event(line, topics) do
    case Jason.decode(line) do
      {:ok, %{"topic" => t} = ev} ->
        if topics == nil or t in topics, do: [ev], else: []

      _ ->
        []
    end
  end

  @doc "事件条数（只数行、不解析 JSON，供 status 等轻量指标使用）。"
  def count do
    case File.stat(@path) do
      {:ok, %{size: 0}} ->
        0

      {:ok, _} ->
        @path
        |> File.stream!([], :line)
        |> Enum.count(fn line -> line != "\n" end)

      _ ->
        0
    end
  end

  @doc "按谓词过滤事件（adapter 分析用）。"
  def query(pred) when is_function(pred, 1) do
    read(100_000) |> Enum.reverse() |> Enum.filter(pred)
  end

  @doc "事件文件大小（字节）。"
  def size do
    case File.stat(@path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  @impl true
  def init(_) do
    File.mkdir_p!(Path.dirname(@path))
    if Process.whereis(Newbee.Bus), do: Newbee.Bus.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:newbee_event, topic, event}, state) do
    if topic in @durable do
      line =
        Jason.encode_to_iodata!(%{
          topic: topic,
          event: encodable(event),
          at: local_iso()
        })

      File.write!(@path, [line, "\n"], [:append])
      trim()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # 事件常是元组（{:goal_start, "..."}、{:audit, :ok, actor, target, ring}）——
  # Jason 不能编码元组，转成可编码形态（元组 → [tag | args]，递归）
  defp encodable(v) when is_tuple(v) do
    v |> Tuple.to_list() |> Enum.map(&encodable/1)
  end

  defp encodable(v) when is_list(v), do: Enum.map(v, &encodable/1)

  defp encodable(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, encodable(val)} end)
  end

  defp encodable(v), do: v

  defp trim do
    case File.stat(@path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        case File.read(@path) do
          {:ok, body} ->
            keep = String.slice(body, -div(@max_bytes, 2)..-1//1)
            File.write!(@path, keep)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # 本地时间 ISO（事件日志与界面同源，避免 UTC 差 8 小时）
  defp local_iso do
    {{y, m, d}, {h, mi, s}} = :calendar.local_time()
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B", [y, m, d, h, mi, s]) |> IO.iodata_to_binary()
  end
end
