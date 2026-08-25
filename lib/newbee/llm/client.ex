defmodule Newbee.LLM.Client do
  @moduledoc """
  OpenRouter 流式客户端 (DESIGN §4)。SSE 流式 + tool_calls 增量聚合。
  API key 默认从 OPENROUTER_API_KEY 读取。
  """

  @default_base_url "https://openrouter.ai/api/v1"
  @default_model "deepseek/deepseek-v4-flash-0731"
  @default_context_window 256_000
  @context_cache_key {__MODULE__, :context_windows}
  @overload_statuses [429, 500, 502, 503, 529]
  @overload_retries 5
  @overload_delay 1_000

  @derive {Inspect, except: [:api_key]}
  defstruct model: @default_model,
            api_key: nil,
            base_url: @default_base_url,
            reasoning_effort: nil,
            vision: true,
            context_window: nil,
            interrupt_scope: nil,
            req_options: []

  def new(opts \\ []) do
    %__MODULE__{
      model: Keyword.get(opts, :model, @default_model),
      api_key: Keyword.get(opts, :api_key, System.get_env("OPENROUTER_API_KEY")),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      vision: Keyword.get(opts, :vision, true),
      context_window: Keyword.get(opts, :context_window),
      interrupt_scope: Keyword.get(opts, :interrupt_scope),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc "获取模型上下文窗口；显式配置优先，否则查询 provider 元数据，失败回退 256K。"
  def context_window(%__MODULE__{context_window: n}) when is_integer(n) and n > 0, do: n

  def context_window(%__MODULE__{} = client) do
    cache = :persistent_term.get(@context_cache_key, %{})
    key = {client.base_url, client.model}

    case Map.fetch(cache, key) do
      {:ok, n} ->
        n

      :error ->
        n = fetch_context_window(client)
        :persistent_term.put(@context_cache_key, Map.put(cache, key, n))
        n
    end
  end

  def context_window(client) when is_map(client), do: Map.get(client, :context_window) || @default_context_window

  defp fetch_context_window(client) do
    with {:ok, %{status: 200, body: body}} <-
           Req.get(client.base_url <> "/models",
             headers: [
               {"authorization", "Bearer #{client.api_key}"},
               {"user-agent", "newbee"}
             ],
             receive_timeout: 15_000,
             retry: false
           ),
         models when is_list(models) <- body["data"] || body[:data],
         model when is_map(model) <- Enum.find(models, &((&1["id"] || &1[:id]) == client.model)),
         n when is_integer(n) and n > 0 <- model["context_length"] || model[:context_length] do
      n
    else
      _ -> @default_context_window
    end
  rescue
    _ -> @default_context_window
  end

  @doc """
  流式聊天。`on_text.(delta)` 收到正文增量；`on_reasoning.(delta)`（DeepSeek 系）
  收到思考增量。返回 {:ok, message, usage} | {:error, term}，
  message 含 "content" 与 "tool_calls"（可能为空列表）。
  """
  def stream_chat(%__MODULE__{} = client, messages, on_text \\ fn _ -> :ok end, on_reasoning \\ fn _ -> :ok end) do
    if interrupted?(client) do
      {:interrupted, ""}
    else
      parent = self()
      ref = make_ref()

      {worker, monitor} =
        spawn_monitor(fn ->
          # 异常就地转结果：worker 一崩，父进程只能拿到无因的 :stream_worker_stopped，
          # 崩溃栈全丢。这里转成既有 {:error, {:stream_error, reason, content}} 形状：
          # 既保留诊断信息，又天然进入 goal 模式的可重试白名单。
          result =
            try do
              stream_chat_request(client, messages, on_text, on_reasoning)
            rescue
              e -> {:error, {:stream_error, Exception.format(:error, e, __STACKTRACE__), ""}}
            catch
              kind, value ->
                {:error, {:stream_error, Exception.format(kind, value, __STACKTRACE__), ""}}
            end

          send(parent, {:stream_chat_result, ref, result})
        end)

      started_at = System.monotonic_time(:millisecond)
      result = await_stream_chat(worker, monitor, ref, client)
      observe_provider(result, client, started_at, "stream_chat")
      result
    end
  end

  # Req.request/1 在收到首个响应前可能同步等待连接/首 token，
  # 所以整个请求放到可杀的 worker；调用方每 50ms 检查一次 Esc 标志。
  defp stream_chat_request(%__MODULE__{} = client, messages, on_text, on_reasoning) do
    Newbee.DebugLog.log(:llm, "start model=#{client.model} messages=#{length(messages)}")
    t0 = System.monotonic_time(:millisecond)

    body = %{
      model: client.model,
      messages: messages,
      tools: Newbee.Codec.tools(),
      stream: true,
      stream_options: %{include_usage: true}
    }

    body =
      if client.reasoning_effort,
        do: Map.put(body, :reasoning_effort, client.reasoning_effort),
        else: body

    # receive_timeout 是"相邻两块数据的间隔"。serverless 端点冷启动（唤醒实例）
    # 实测 ~38s 才出首 token，30s 必然误超时再重试（等待翻倍）；120s 覆盖冷启动。
    build_req = fn body ->
      [
        url: client.base_url <> "/chat/completions",
        method: :post,
        headers: [
          {"authorization", "Bearer #{client.api_key}"},
          {"content-type", "application/json"},
          {"user-agent", "newbee"}
        ],
        json: body,
        receive_timeout: 120_000,
        finch: [pool_timeout: 30_000, conn_max_idle_time: 300_000, conn_opts: [transport_opts: [timeout: 30_000]]],
        retry: false,
        into: :self
      ]
      |> Keyword.merge(client.req_options)
      |> Req.new()
    end

    result =
      case do_request(build_req.(body), on_text, on_reasoning, @overload_retries, client) do
        {:error, %Req.TransportError{reason: reason}} when reason in [:timeout, :closed] ->
          # 冷连接/池连接被服务端关闭：只重拨一次，避免重复整轮重试造成长时间等待
          Newbee.DebugLog.log(:llm, "transport #{reason}, prewarming+single retry")
          prewarm(client)
          do_request(build_req.(body), on_text, on_reasoning, 0, client)

        other ->
          other
      end

    # 各家 provider 接受的 reasoning_effort 档位不一（如 sensenova 无 "max"）：
    # 上游代理（Console Go 等）也可能因 reasoning_effort 报 400 invalid input。
    # 400 时：先尝试摘掉 reasoning_effort 重试；若仍失败，再回传错误。
    result =
      case result do
        {:error, {:http_error, 400, msg}} = err ->
          should_retry_reasoning? =
            client.reasoning_effort && is_binary(msg) &&
              (msg =~ "reasoning" or msg =~ "Upstream" or msg =~ "invalid input")

          if should_retry_reasoning? do
            Newbee.DebugLog.log(
              :llm,
              "400 on reasoning_effort=#{client.reasoning_effort}, retry without it (msg=#{String.slice(msg, 0, 120)})"
            )

            do_request(
              build_req.(Map.delete(body, :reasoning_effort)),
              on_text,
              on_reasoning,
              @overload_retries,
              client
            )
          else
            err
          end

        other ->
          other
      end

    Newbee.DebugLog.log(:llm, "done in #{System.monotonic_time(:millisecond) - t0}ms result=#{elem(result, 0)}")
    result
  end

  defp await_stream_chat(worker, monitor, ref, client) do
    receive do
      {:stream_chat_result, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        Newbee.DebugLog.log(:llm, "stream worker DOWN: #{inspect(reason)}")
        {:error, {:stream_error, "worker 进程异常退出：#{inspect(reason)}", ""}}
    after
      50 ->
        if interrupted?(client) do
          Process.exit(worker, :kill)
          Process.demonitor(monitor, [:flush])
          {:interrupted, ""}
        else
          await_stream_chat(worker, monitor, ref, client)
        end
    end
  end

  @doc """
  非流式补全（verifier/轻量判分用）。`opts`：
    - `logprobs`: true 时请求 token logprobs（部分模型支持，响应含 logprobs.content）
    - `top_logprobs`: 配合 logprobs 使用的 top-N 分布（默认 20）
    - `temperature`: 默认 0.2
    - `extra`: 追加到请求体的任意字段
  返回 {:ok, content, %{usage, logprobs}} | {:error, term}。logprobs 缺失时为 nil。
  """
  def complete(%__MODULE__{} = client, messages, opts \\ []) do
    Newbee.DebugLog.log(:llm, "complete start model=#{client.model} messages=#{length(messages)}")

    body =
      %{
        model: client.model,
        messages: messages,
        stream: false,
        temperature: Keyword.get(opts, :temperature, 0.2)
      }
      |> maybe_put_body(:logprobs, Keyword.get(opts, :logprobs))
      |> maybe_put_body(:top_logprobs, Keyword.get(opts, :top_logprobs, 20))
      |> maybe_put_body(:reasoning_effort, client.reasoning_effort)
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    body =
      case Keyword.get(opts, :tools) do
        tools when is_list(tools) and tools != [] -> Map.put(body, :tools, tools)
        _ -> body
      end

    t0 = System.monotonic_time(:millisecond)

    req =
      [
        url: client.base_url <> "/chat/completions",
        method: :post,
        headers: [
          {"authorization", "Bearer #{client.api_key}"},
          {"content-type", "application/json"},
          {"user-agent", "newbee"}
        ],
        json: body,
        receive_timeout: 120_000,
        retry: false
      ]
      |> Keyword.merge(client.req_options)
      |> Req.new()

    result =
      case complete_req(req, @overload_retries) do
        {:ok, %{status: 200} = resp} ->
          case decode_body(resp.body) do
            {:ok, %{"choices" => [choice | _]} = body_map} ->
              content = get_in(choice, ["message", "content"]) || ""
              logprobs = choice["logprobs"]
              usage = normalize_usage(choice["usage"] || body_map["usage"] || %{})
              {:ok, content, %{usage: usage, logprobs: logprobs}}

            {:ok, %{"error" => err}} ->
              {:error, {:api_error, err}}

            other ->
              {:error, {:bad_response, other}}
          end

        {:ok, %{status: status} = resp} when status in @overload_statuses ->
          {:error, {:http_error, status, resp.body}}

        {:error, e} ->
          {:error, e}
      end

    Newbee.DebugLog.log(
      :llm,
      "complete done in #{System.monotonic_time(:millisecond) - t0}ms result=#{elem(result, 0)}"
    )

    observe_provider(result, client, t0, "complete")
    result
  end

  defp maybe_put_body(body, _k, nil), do: body
  defp maybe_put_body(body, k, v), do: Map.put(body, k, v)

  defp observe_provider(result, client, started_at, task_type) do
    {success, tokens, output_bytes} =
      case result do
        {:ok, message, usage} when is_map(message) ->
          {true, usage_tokens(usage), byte_size(to_string(message["content"] || ""))}

        {:ok, content, %{usage: usage}} when is_binary(content) ->
          {true, usage_tokens(usage), byte_size(content)}

        _ ->
          {false, 0, 0}
      end

    Newbee.Environment.UsageTracker.observe_plugin("provider.openrouter", %{
      success: success,
      latency_ms: System.monotonic_time(:millisecond) - started_at,
      tokens: tokens,
      output_bytes: output_bytes,
      model: client.model,
      task_type: task_type
    })
  rescue
    _ -> :ok
  end

  defp usage_tokens(usage) when is_map(usage) do
    usage["total_tokens"] || usage[:total_tokens] ||
      (usage["prompt_tokens"] || usage[:prompt_tokens] || 0) +
        (usage["completion_tokens"] || usage[:completion_tokens] || 0)
  end

  defp usage_tokens(_), do: 0

  # 429/5xx 过载重试（非流式版，无 SSE drain 需求）
  defp complete_req(req, 0), do: Req.request(req)

  defp complete_req(req, left) do
    case Req.request(req) do
      {:ok, %{status: status}} when status in @overload_statuses ->
        Process.sleep(@overload_delay)
        complete_req(req, left - 1)

      other ->
        other
    end
  end

  # 429/5xx 过载类错误是瞬态的：1 秒后重试，最多 5 次。
  # 重试前必须 drain 掉错误响应体——into: :self 的异步消息残留会污染
  # 下一次请求的 SSE 消费。Esc 中断时立即放弃重试。
  defp do_request(req, on_text, on_reasoning, overload_left, client) do
    case Req.request(req) do
      {:ok, %{status: status} = resp}
      when status in @overload_statuses and overload_left > 0 ->
        _ = drain(resp)

        if interrupted?(client) do
          {:interrupted, ""}
        else
          Newbee.DebugLog.log(
            :llm,
            "http #{status} 过载，#{@overload_delay}ms 后重试（剩余 #{overload_left - 1} 次）"
          )

          Process.sleep(@overload_delay)
          do_request(req, on_text, on_reasoning, overload_left - 1, client)
        end

      {:ok, %{status: 200} = resp} ->
        consume_sse(resp, on_text, on_reasoning, client)

      {:ok, resp} ->
        {:error, {:http_error, resp.status, drain(resp)}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc "预热连接池：建立 TLS 连接，后续请求复用。失败静默。"
  def prewarm(%__MODULE__{} = client) do
    # 假 IP 代理 TLS 握手 ~5.2s，预热必须容忍慢拨号；连接入池后请求级 5s 才有意义
    Req.get(client.base_url <> "/models",
      headers: [
        {"authorization", "Bearer #{client.api_key}"},
        {"user-agent", "newbee"}
      ],
      receive_timeout: 30_000,
      finch: [pool_timeout: 30_000, conn_max_idle_time: 300_000, conn_opts: [transport_opts: [timeout: 30_000]]],
      retry: false
    )

    :ok
  rescue
    _ -> :ok
  end

  # ── SSE 消费 ──

  defp consume_sse(resp, on_text, on_reasoning, client) do
    acc = %{content: "", reasoning: "", tool_calls: %{}, usage: %{}, error: nil}

    case loop(resp, acc, on_text, on_reasoning, "", System.monotonic_time(:millisecond), client) do
      %{error: :interrupted} = a ->
        Newbee.DebugLog.log(:sse, "interrupted content=#{byte_size(a.content)}")
        {:interrupted, a.content}

      %{error: err} = a when not is_nil(err) ->
        Newbee.DebugLog.log(:sse, "error #{inspect(err)} content=#{byte_size(a.content)}")
        {:error, {:stream_error, err, a.content}}

      acc ->
        Newbee.DebugLog.log(
          :sse,
          "done content=#{byte_size(acc.content)} reasoning=#{byte_size(acc.reasoning)} tool_calls=#{map_size(acc.tool_calls)}"
        )

        msg =
          %{"role" => "assistant", "content" => acc.content}
          |> maybe_put("tool_calls", assemble_tool_calls(acc.tool_calls))
          |> maybe_put("reasoning", acc.reasoning)

        {:ok, msg, acc.usage}
    end
  end

  # DeepSeek 系拒绝空 tool_calls 数组（400）；空值不写字段
  defp maybe_put(msg, _key, []), do: msg
  defp maybe_put(msg, _key, ""), do: msg
  defp maybe_put(msg, key, val), do: Map.put(msg, key, val)

  # 中断标志（会话作用域）：Esc 置位的是"当前会话 scope"的标志，
  # 流式循环 ≤100ms 内响应并取消连接。
  #
  # scope = 每个会话（Loop 进程）一个 id，存进 client struct；stream_chat
  # 的请求 worker / 重试 / SSE 消费都拿着同一份 client，天然同 scope。
  # 每个会话一个 scope，中断互不影响。client 无 scope（旧调用方/测试）
  # 时回退"当前调用树"：本进程 pdict，再沿 $callers 向上找。
  @interrupt_scope_key {__MODULE__, :interrupt_scope}
  @interrupt_legacy_key {__MODULE__, :interrupt_legacy}

  @doc "生成一个新的中断 scope id（Loop 每个回合持有一个）。"
  def new_interrupt_scope, do: make_ref()

  @doc "在当前进程注册中断 scope（Loop submit 前调用，供无 client 的旧路径回退）。返回 scope id。"
  def register_interrupt_scope do
    scope = new_interrupt_scope()
    Process.put(@interrupt_scope_key, scope)
    scope
  end

  @doc "请求中断（Esc）。给 client 时只置位该会话的 scope；不给时置位当前调用树。"
  def interrupt(client \\ nil)

  def interrupt(%__MODULE__{interrupt_scope: scope}) when not is_nil(scope) do
    :persistent_term.put(scope_key(scope), true)
  end

  def interrupt(_) do
    case find_interrupt_scope() do
      {:ok, scope} -> :persistent_term.put(scope_key(scope), true)
      :error -> :persistent_term.put(@interrupt_legacy_key, true)
    end
  end

  @doc "清除中断标志（回合开始时）。给 client 清该会话 scope，不给清当前调用树。"
  def clear_interrupt(client \\ nil)

  def clear_interrupt(%__MODULE__{interrupt_scope: scope}) when not is_nil(scope) do
    :persistent_term.erase(scope_key(scope))
  end

  def clear_interrupt(_) do
    case find_interrupt_scope() do
      {:ok, scope} -> :persistent_term.erase(scope_key(scope))
      :error -> :persistent_term.erase(@interrupt_legacy_key)
    end
  end

  @doc "中断标志是否已置位。给 client 查该会话 scope，不给查当前调用树。"
  def interrupted?(client \\ nil)

  def interrupted?(%{interrupt_scope: scope}) when not is_nil(scope) do
    :persistent_term.get(scope_key(scope), false)
  end

  def interrupted?(_) do
    case find_interrupt_scope() do
      {:ok, scope} -> :persistent_term.get(scope_key(scope), false)
      :error -> :persistent_term.get(@interrupt_legacy_key, false)
    end
  end

  defp scope_key(scope), do: {__MODULE__, {:interrupt, scope}}

  # 先查本进程 pdict；否则沿 $callers 链向上（spawn_monitor/Task 的调用树
  # 会记录 $callers），找到最近的 scope 注册者。整条链找不到视为无 scope。
  defp find_interrupt_scope do
    case Process.get(@interrupt_scope_key) do
      nil -> find_scope_in_callers(callers())
      scope -> {:ok, scope}
    end
  end

  defp callers do
    case Process.info(self(), :dictionary) do
      {:dictionary, dict} when is_list(dict) -> :proplists.get_value(:"$callers", dict, [])
      _ -> []
    end
  end

  defp find_scope_in_callers([pid | rest]) when is_pid(pid) do
    if Process.alive?(pid) do
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} when is_list(dict) ->
          case :proplists.get_value(@interrupt_scope_key, dict) do
            nil -> find_scope_in_callers(rest)
            scope -> {:ok, scope}
          end

        _ ->
          find_scope_in_callers(rest)
      end
    else
      find_scope_in_callers(rest)
    end
  end

  defp find_scope_in_callers(_), do: :error

  defp loop(resp, acc, on_text, on_reasoning, buf, t0, client) do
    receive do
      message ->
        if interrupted?(client) do
          Req.cancel_async_response(resp)
          %{acc | error: :interrupted}
        else
          case Req.parse_message(resp, message) do
            {:ok, [data: data]} ->
              {events, rest} = split_sse(buf <> data)
              acc = Enum.reduce(events, acc, &apply_event(&1, &2, on_text, on_reasoning))
              loop(resp, acc, on_text, on_reasoning, rest, t0, client)

            {:ok, [:done]} ->
              acc

            {:ok, [trailers: _]} ->
              loop(resp, acc, on_text, on_reasoning, buf, t0, client)

            {:error, e} ->
              %{acc | error: inspect(e)}

            :unknown ->
              loop(resp, acc, on_text, on_reasoning, buf, t0, client)
          end
        end
    after
      100 ->
        cond do
          interrupted?(client) ->
            Req.cancel_async_response(resp)
            %{acc | error: :interrupted}

          System.monotonic_time(:millisecond) - t0 > 300_000 ->
            Newbee.DebugLog.log(:sse, "stream timeout, cancelling")
            Req.cancel_async_response(resp)
            %{acc | error: "stream timeout"}

          true ->
            loop(resp, acc, on_text, on_reasoning, buf, t0, client)
        end
    end
  end

  defp split_sse(buf) do
    parts = String.split(buf, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    events =
      complete
      |> Enum.flat_map(&String.split(&1, "\n"))
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.trim_leading(&1, "data: "))

    {events, rest}
  end

  defp apply_event("[DONE]", acc, _, _), do: acc

  defp apply_event(data, acc, on_text, on_reasoning) do
    case Jason.decode(data) do
      {:ok, %{"choices" => [choice | _]} = chunk} ->
        acc
        |> apply_delta(choice["delta"] || %{}, on_text, on_reasoning)
        |> maybe_usage(chunk)

      {:ok, %{"usage" => usage}} ->
        %{acc | usage: usage || acc.usage}

      {:ok, %{"error" => err}} ->
        %{acc | error: inspect(err)}

      _ ->
        acc
    end
  end

  defp maybe_usage(acc, %{"usage" => usage}) when is_map(usage), do: %{acc | usage: normalize_usage(usage)}
  defp maybe_usage(acc, _), do: acc

  @doc "将 provider 错误转换为可操作的简短提示；原始错误仍写入 debug.log。"
  def format_error({:http_error, status, body}) do
    detail = provider_error_detail(body)
    hint = if status == 400, do: "请检查模型能力、消息内容和请求参数；系统会自动重试。", else: "系统会按策略自动重试。"
    "LLM 请求失败（HTTP #{status}）：#{detail} #{hint}"
  end

  def format_error({:upstream_error, reason}), do: "LLM 上游暂时不可用：#{inspect(reason)} 系统会自动重试。"
  def format_error({:stream_error, reason}), do: "LLM 流式请求失败：#{inspect(reason)} 系统会自动重试。"
  def format_error({:stream_error, reason, _content}), do: format_error({:stream_error, reason})
  def format_error(%Req.TransportError{reason: reason}), do: "LLM 网络请求失败：#{inspect(reason)} 系统会自动重试。"
  def format_error(error), do: "LLM 请求失败：#{inspect(error)}"

  defp provider_error_detail(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_map(error) ->
        error["message"] || error["detail"] || "provider 返回未说明具体原因"

      _ ->
        body |> String.trim() |> String.slice(0, 500)
    end
  end

  defp provider_error_detail(body), do: inspect(body)

  @doc false
  def normalize_usage(usage) when is_map(usage) do
    cache_read =
      usage["cache_read_input_tokens"] || usage["cached_tokens"] ||
        get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        usage["prompt_cache_hit_tokens"]

    cache_write = usage["cache_write_input_tokens"] || usage["cache_write_tokens"]

    usage =
      usage
      |> maybe_put_usage("cache_read_tokens", cache_read)
      |> maybe_put_usage("cache_write_tokens", cache_write)

    case usage["prompt_tokens"] do
      prompt_tokens when is_number(prompt_tokens) ->
        Map.put(usage, "uncached_prompt_tokens", max(prompt_tokens - (cache_read || 0), 0))

      _ ->
        usage
    end
  end

  defp maybe_put_usage(usage, _key, nil), do: usage
  defp maybe_put_usage(usage, key, value), do: Map.put(usage, key, value)

  # Req 默认 decode_body: true——真实 HTTP 响应 body 已被解码为 map；
  # decode_body: false（或插桩）时是二进制。两态都兼容。
  defp decode_body(b) when is_binary(b), do: Jason.decode(b)
  defp decode_body(m) when is_map(m), do: {:ok, m}

  defp apply_delta(acc, delta, on_text, on_reasoning) do
    # 注意：OpenRouter 等在 reasoning 阶段常带 "content": ""——空串也是 binary，
    # 不挡会让 TUI 每个思考块都翻转 stream_kind 开新行（"几个字一行"根因）
    acc =
      case delta["content"] do
        text when is_binary(text) and text != "" ->
          on_text.(text)
          %{acc | content: acc.content <> text}

        _ ->
          acc
      end

    # DeepSeek 思考流：reasoning_content（delta 阶段与 content 分开发送）
    acc =
      case delta["reasoning_content"] || delta["reasoning"] do
        text when is_binary(text) and text != "" ->
          on_reasoning.(text)
          %{acc | reasoning: acc.reasoning <> text}

        _ ->
          acc
      end

    Enum.reduce(delta["tool_calls"] || [], acc, fn tc, acc ->
      idx = tc["index"] || 0
      slot = Map.get(acc.tool_calls, idx, %{"id" => nil, "name" => "", "arguments" => ""})
      fun = tc["function"] || %{}

      slot = %{
        "id" => tc["id"] || slot["id"],
        "name" => slot["name"] <> (fun["name"] || ""),
        "arguments" => slot["arguments"] <> (fun["arguments"] || "")
      }

      %{acc | tool_calls: Map.put(acc.tool_calls, idx, slot)}
    end)
  end

  defp assemble_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_, slot} ->
      %{
        "id" => slot["id"],
        "type" => "function",
        "function" => %{"name" => slot["name"], "arguments" => slot["arguments"]}
      }
    end)
  end

  defp drain(resp) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, [data: d]} -> d <> drain(resp)
          {:ok, [:done]} -> ""
          _ -> drain(resp)
        end
    after
      15_000 -> ""
    end
  end
end
