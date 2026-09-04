defmodule Newbee.LLM.HttpDebug do
  @moduledoc """
  大模型 HTTP 调试追踪（WebUI 右栏 Debug Tab 用）。

  记录与大模型交互的完整 HTTP 往返：请求头与请求体、回包头与回包体
  （含流式 SSE 原始流截断），存环形缓冲（默认保留最近 100 条）。
  前端点开始后轮询拉取，点停止即停拉并且后端停止记录，双向省带宽与算力。

  - 默认关闭：关闭时 start 相关调用直接返回 nil，基本零开销。
  - 开启后每个逻辑 LLM 调用一条记录：先 start_exchange（请求即时可见，
    phase 为 inflight），流式块经 append_raw 追加（实时刷新），
    结束经 finish_current 落盘最终态。
  - Authorization 等敏感头只存脱敏后，原始 key 永不进缓冲；
    图片 data-URL 折叠为占位，避免 base64 撑爆内存。
  """

  use GenServer

  @max_entries 100
  @max_body_bytes 300_000
  @max_raw_bytes 200_000
  @max_header_value 2_000
  @pd_key {__MODULE__, :current_id}

  @doc "启动追踪器（监督树 child）。"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(_) do
    {:ok, %{enabled: false, next_id: 1, order: [], by_id: %{}}}
  end

  @doc "是否正在记录（前端开始与停止按钮用）。"
  def enabled? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _ -> GenServer.call(__MODULE__, :enabled?)
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc "设置记录开关，返回新的开关状态。"
  def set_enabled(flag) when is_boolean(flag) do
    case Process.whereis(__MODULE__) do
      nil -> flag
      _ -> GenServer.call(__MODULE__, {:set_enabled, flag})
    end
  rescue
    _ -> flag
  catch
    _, _ -> flag
  end

  @doc "清空缓冲（保留开关与自增 id，避免前端 since 混乱）。"
  def clear do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _ -> GenServer.call(__MODULE__, :clear)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "列出摘要（不含 body，省带宽）。取 since_id 之后 limit 条，id 升序。"
  def list(limit \\ 30, since_id \\ 0) do
    case Process.whereis(__MODULE__) do
      nil -> []
      _ -> GenServer.call(__MODULE__, {:list, limit, since_id})
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "取单条完整记录（含请求与回包头体）。无则 nil。"
  def get(id) when is_integer(id) do
    case Process.whereis(__MODULE__) do
      nil -> nil
      _ -> GenServer.call(__MODULE__, {:get, id})
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "状态摘要。"
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{enabled: false, count: 0, next_id: 1}
      _ -> GenServer.call(__MODULE__, :status)
    end
  rescue
    _ -> %{enabled: false, count: 0, next_id: 1}
  catch
    _, _ -> %{enabled: false, count: 0, next_id: 1}
  end

  @doc """
  开始一条 HTTP 记录。attrs 键为 session_id、model、base_url、endpoint、
  method、url、api、req_headers、req_body。关闭时直接返回 nil。
  开启时把 id 存入进程字典，供同进程后续 note、append、finish 使用。
  """
  def start_exchange(attrs) when is_map(attrs) do
    case Process.whereis(__MODULE__) do
      nil ->
        Process.delete(@pd_key)
        nil

      _ ->
        case GenServer.call(__MODULE__, {:start, attrs}) do
          nil ->
            Process.delete(@pd_key)
            nil

          id when is_integer(id) ->
            Process.put(@pd_key, id)
            id
        end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "当前进程正在记录的 exchange id（无则 nil）。"
  def current_id do
    Process.get(@pd_key)
  end

  @doc "记录回包状态行（同进程隐式 id 版）。无 id 时为空操作。"
  def note_current_response(status, headers) do
    case Process.get(@pd_key) do
      nil -> :ok
      id -> note_response(id, status, headers)
    end
  end

  @doc "记录回包状态行（显式 id 版）。"
  def note_response(id, status, headers) when is_integer(id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _ -> GenServer.cast(__MODULE__, {:note_response, id, status, headers})
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def note_response(_, _, _), do: :ok

  @doc "追加 SSE 原始块（同进程隐式 id）。超长截断，关闭时为空操作。"
  def append_raw(chunk) when is_binary(chunk) do
    case Process.get(@pd_key) do
      nil -> :ok
      id -> append_raw(id, chunk)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def append_raw(_), do: :ok

  @doc "追加 SSE 原始块（显式 id 版）。"
  def append_raw(id, chunk) when is_integer(id) and is_binary(chunk) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _ -> GenServer.cast(__MODULE__, {:append_raw, id, chunk})
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def append_raw(_, _), do: :ok

  @doc """
  结束当前记录（同进程隐式 id）。result 为 LLM 调用返回值，
  完成后清进程字典。
  """
  def finish_current(result) do
    case Process.get(@pd_key) do
      nil -> :ok
      id -> finish(id, result)
    end
  end

  @doc "结束指定记录（显式 id 版）。"
  def finish(id, result) when is_integer(id) do
    try do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _ -> GenServer.call(__MODULE__, {:finish, id, finish_attrs(result)})
      end
    after
      if Process.get(@pd_key) == id, do: Process.delete(@pd_key)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def finish(_, _), do: :ok

  @doc "从缓存路由键反推会话 id（newbee- 前缀之后即 sid）。"
  def session_id_from_cache_key(key) when is_binary(key) do
    case String.split(key, "newbee-", parts: 2) do
      [_, sid] when byte_size(sid) > 0 -> sid
      _ -> nil
    end
  end

  def session_id_from_cache_key(_), do: nil

  @impl true
  def handle_call(:enabled?, _from, st), do: {:reply, st.enabled, st}

  def handle_call({:set_enabled, flag}, _from, st), do: {:reply, flag, %{st | enabled: flag}}

  def handle_call(:clear, _from, st), do: {:reply, :ok, %{st | order: [], by_id: %{}}}

  def handle_call(:status, _from, st) do
    {:reply, %{enabled: st.enabled, count: length(st.order), next_id: st.next_id}, st}
  end

  def handle_call({:list, limit, since_id}, _from, st) do
    limit = limit |> to_int(30) |> min(100) |> max(1)
    since = to_int(since_id, 0)

    items =
      st.order
      |> Enum.reverse()
      |> Enum.map(&Map.get(st.by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.id > since))
      |> Enum.take(limit)
      |> Enum.map(&summary/1)

    {:reply, items, st}
  end

  def handle_call({:get, id}, _from, st) do
    {:reply, Map.get(st.by_id, id), st}
  end

  def handle_call({:start, attrs}, _from, %{enabled: false} = st) do
    _ = attrs
    {:reply, nil, st}
  end

  def handle_call({:start, attrs}, _from, st) do
    id = st.next_id
    now_mono = System.monotonic_time(:millisecond)
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    {req_text, req_bytes, req_trunc} = encode_body(Map.get(attrs, :req_body))

    entry = %{
      id: id,
      started_at: now_iso,
      started_mono: now_mono,
      session_id: Map.get(attrs, :session_id),
      model: Map.get(attrs, :model),
      base_url: Map.get(attrs, :base_url),
      endpoint: Map.get(attrs, :endpoint),
      method: Map.get(attrs, :method, "POST"),
      url: Map.get(attrs, :url),
      api: Map.get(attrs, :api, "chat"),
      req_headers: redact_headers(Map.get(attrs, :req_headers, [])),
      req_body: req_text,
      req_bytes: req_bytes,
      req_truncated: req_trunc,
      phase: "inflight",
      duration_ms: nil,
      resp_status: nil,
      resp_headers: [],
      resp_body: "",
      resp_bytes: 0,
      resp_truncated: false,
      sse_raw: "",
      sse_bytes: 0,
      sse_truncated: false,
      usage: %{},
      error: nil
    }

    order = [id | st.order] |> Enum.take(@max_entries)
    pruned = MapSet.new(order)

    by_id =
      st.by_id
      |> Map.put(id, entry)
      |> Map.filter(fn {k, _} -> MapSet.member?(pruned, k) end)

    {:reply, id, %{st | next_id: id + 1, order: order, by_id: by_id}}
  end

  def handle_call({:finish, id, fattrs}, _from, st) do
    case Map.get(st.by_id, id) do
      nil ->
        {:reply, :ok, st}

      entry ->
        done =
          entry
          |> Map.merge(fattrs)
          |> Map.put(:duration_ms, System.monotonic_time(:millisecond) - entry.started_mono)
          |> Map.delete(:started_mono)

        {:reply, :ok, %{st | by_id: Map.put(st.by_id, id, done)}}
    end
  end

  @impl true
  def handle_cast({:note_response, id, status, headers}, st) do
    case Map.get(st.by_id, id) do
      nil ->
        {:noreply, st}

      entry ->
        done = %{entry | resp_status: to_status(status), resp_headers: redact_headers(headers)}
        {:noreply, %{st | by_id: Map.put(st.by_id, id, done)}}
    end
  end

  def handle_cast({:append_raw, id, chunk}, st) do
    case Map.get(st.by_id, id) do
      nil ->
        {:noreply, st}

      entry ->
        {raw, bytes, trunc} = append_truncated(entry.sse_raw, entry.sse_bytes, chunk, @max_raw_bytes)
        done = %{entry | sse_raw: raw, sse_bytes: bytes, sse_truncated: trunc}
        {:noreply, %{st | by_id: Map.put(st.by_id, id, done)}}
    end
  end

  def handle_cast(_, st), do: {:noreply, st}

  defp summary(e) do
    %{
      id: e.id,
      started_at: e.started_at,
      session_id: e.session_id,
      model: e.model,
      endpoint: e.endpoint,
      api: e.api,
      phase: e.phase,
      status: e.resp_status,
      duration_ms: e.duration_ms,
      req_bytes: e.req_bytes,
      req_truncated: e.req_truncated,
      resp_bytes: e.resp_bytes,
      resp_truncated: e.resp_truncated,
      sse_bytes: e.sse_bytes,
      error: short_error(e.error)
    }
  end

  defp finish_attrs({:ok, msg, usage}) when is_map(msg) do
    {text, bytes, trunc} = encode_body(%{"message" => msg, "usage" => usage})

    %{
      phase: "done",
      resp_status: 200,
      resp_body: text,
      resp_bytes: bytes,
      resp_truncated: trunc,
      usage: json_safe(usage),
      error: nil
    }
  end

  defp finish_attrs({:ok, content, %{usage: usage}}) when is_binary(content) do
    {text, bytes, trunc} = encode_body(%{"content" => content, "usage" => usage})

    %{
      phase: "done",
      resp_status: 200,
      resp_body: text,
      resp_bytes: bytes,
      resp_truncated: trunc,
      usage: json_safe(usage),
      error: nil
    }
  end

  defp finish_attrs({:ok, {:json, body}}) do
    {text, bytes, trunc} = encode_body(body)

    %{
      phase: "done",
      resp_status: 200,
      resp_body: text,
      resp_bytes: bytes,
      resp_truncated: trunc,
      usage: %{},
      error: nil
    }
  end

  defp finish_attrs({:ok, {:stream, msg, usage, _rid}}) do
    {text, bytes, trunc} = encode_body(%{"message" => msg, "usage" => usage})

    %{
      phase: "done",
      resp_status: 200,
      resp_body: text,
      resp_bytes: bytes,
      resp_truncated: trunc,
      usage: json_safe(usage),
      error: nil
    }
  end

  defp finish_attrs({:error, {:http_error, status, body}}) do
    {text, bytes, trunc} = encode_body(body)

    %{
      phase: "error",
      resp_status: to_status(status),
      resp_body: text,
      resp_bytes: bytes,
      resp_truncated: trunc,
      error: short_error(body)
    }
  end

  defp finish_attrs({:error, {:api_error, err}}) do
    {text, bytes, trunc} = encode_body(err)
    %{phase: "error", resp_body: text, resp_bytes: bytes, resp_truncated: trunc, error: short_error(err)}
  end

  defp finish_attrs({:error, {:stream_error, reason, _}}) do
    %{phase: "error", resp_body: "", resp_bytes: 0, resp_truncated: false, error: short_error(reason)}
  end

  defp finish_attrs({:error, other}) do
    %{phase: "error", resp_body: "", resp_bytes: 0, resp_truncated: false, error: short_error(other)}
  end

  defp finish_attrs({:interrupted, content}) do
    {text, bytes, trunc} = encode_body(content)
    %{phase: "interrupted", resp_body: text, resp_bytes: bytes, resp_truncated: trunc, error: "interrupt"}
  end

  defp finish_attrs(other) do
    {text, bytes, trunc} = encode_body(other)
    %{phase: "done", resp_body: text, resp_bytes: bytes, resp_truncated: trunc, error: nil}
  end

  defp redact_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> [to_string(k), redact_value(k, header_value_to_string(v))] end)
  end

  defp redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {k, v} -> [to_string(k), redact_value(k, header_value_to_string(v))]
      [k, v] -> [to_string(k), redact_value(k, header_value_to_string(v))]
      other -> [inspect(other), ""]
    end)
  end

  defp redact_headers(_), do: []

  defp header_value_to_string(v) when is_list(v), do: Enum.map_join(v, ", ", &to_string/1)
  defp header_value_to_string(v), do: to_string(v)

  defp redact_value(key, value) do
    k = key |> to_string() |> String.downcase()

    sensitive =
      k in ["authorization", "x-api-key", "api-key", "x-auth-token"] or
        String.contains?(k, "token") or String.contains?(k, "secret") or
        String.contains?(k, "api-key") or String.contains?(k, "apikey")

    if sensitive do
      case String.split(value, " ", parts: 2) do
        [scheme, secret] when byte_size(secret) > 8 ->
          scheme <> " ****" <> String.slice(secret, -4..-1//1) <> "redacted"

        _ ->
          "redacted"
      end
    else
      String.slice(value, 0, @max_header_value)
    end
  end

  defp encode_body(nil), do: {"", 0, false}
  defp encode_body(""), do: {"", 0, false}

  defp encode_body(term) do
    term = sanitize(term)

    text =
      case term do
        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, decoded} -> pretty(decoded)
            _ -> s
          end

        other ->
          pretty(other)
      end

    bytes = byte_size(text)
    truncate_string(text, bytes)
  end

  defp pretty(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(term, limit: 50, printable_limit: 50_000)
    end
  rescue
    _ -> inspect(term, limit: 20)
  end

  defp truncate_string(text, bytes) when bytes <= @max_body_bytes, do: {text, bytes, false}

  defp truncate_string(text, bytes) do
    kept = binary_part(text, 0, @max_body_bytes)
    {kept <> "truncated total " <> Integer.to_string(bytes), bytes, true}
  end

  defp append_truncated(existing, known_bytes, chunk, max) do
    total = known_bytes + byte_size(chunk)

    cond do
      byte_size(existing) >= max ->
        {existing, total, true}

      byte_size(existing) + byte_size(chunk) <= max ->
        {existing <> chunk, total, total > max}

      true ->
        keep = max - byte_size(existing)
        {existing <> binary_part(chunk, 0, keep), total, true}
    end
  end

  defp sanitize(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, sanitize_value(k, v)} end)
  end

  defp sanitize(term) when is_list(term), do: Enum.map(term, &sanitize/1)
  defp sanitize(term) when is_binary(term), do: fold_data_url(term)
  defp sanitize(term), do: term

  defp sanitize_value(k, v) when is_binary(v) do
    ks = k |> to_string() |> String.downcase()

    cond do
      String.starts_with?(v, "data:") and byte_size(v) > 1_000 ->
        "folded data-url bytes " <> Integer.to_string(byte_size(v))

      ks in ["image_url", "url"] and byte_size(v) > 2_000 ->
        "folded long string bytes " <> Integer.to_string(byte_size(v))

      true ->
        sanitize(v)
    end
  end

  defp sanitize_value(_k, v), do: sanitize(v)

  defp fold_data_url(s) do
    if String.starts_with?(s, "data:") and byte_size(s) > 1_000 do
      "folded data-url bytes " <> Integer.to_string(byte_size(s))
    else
      s
    end
  end

  defp json_safe(v) when is_map(v) and not is_struct(v) do
    Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)
  end

  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&json_safe/1)
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v, limit: 10)

  defp short_error(nil), do: nil

  defp short_error(e) when is_binary(e) do
    e |> String.trim() |> String.slice(0, 300)
  end

  defp short_error(e) when is_map(e) do
    e |> inspect(limit: 10) |> String.slice(0, 300)
  end

  defp short_error(e), do: e |> inspect(limit: 10) |> String.slice(0, 300)

  defp to_status(s) when is_integer(s), do: s

  defp to_status(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_status(_), do: nil

  defp to_int(v, _d) when is_integer(v), do: v

  defp to_int(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> d
    end
  end

  defp to_int(_, d), do: d
end
