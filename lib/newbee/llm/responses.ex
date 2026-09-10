defmodule Newbee.LLM.Responses do
  @moduledoc false

  alias Newbee.LLM.ResponsesContinuation, as: Continuation
  alias Newbee.LLM.ResponsesCapabilities, as: Caps

  @overload_statuses [429, 500, 502, 503, 529]
  @overload_retries 5
  @overload_delay 1_000
  @stream_timeout 300_000
  @capability_key {__MODULE__, :capabilities}

  def request(client, messages, tools, opts \\ []) do
    {messages, _dropped} = Newbee.LLM.ImagePolicy.project_for(client, messages)
    logical_input = input(messages)
    wire_tools = tools(tools)

    state = %{
      attempts: MapSet.new(),
      force_full: false,
      replayed_previous: false
    }

    run_request(client, logical_input, wire_tools, opts, state)
  end

  @doc """
  非流式补全：`Newbee.LLM.Client.complete/3` 在 responses 路由上的实现。

  `Client.complete/3` 原先永远 POST `chat/completions`，于是 responses 路由上
  （`api: auto`/`openai-responses`）压缩摘要、进度判分、advisor 与 PPT 判分全部失效。
  这里复用流式路径的输入转换、请求构造与 `parse_with_id/1`，只把 `stream` 关掉走 JSON 分支，
  返回契约与 `Client.complete/3` 保持一致：`{:ok, content, %{usage, logprobs}}`。
  """
  def complete(client, messages, opts \\ []) do
    logical_input = input(messages)
    wire_tools = tools(Keyword.get(opts, :tools, []))
    caps = capabilities(client)

    body =
      full_body(client, logical_input, wire_tools, opts, %{caps | stream: false, continuation: false})
      |> normalize_output_limit(opts)
      |> drop_empty_tools(wire_tools)

    case perform(client, body, fn _ -> :ok end, fn _ -> :ok end) do
      {:ok, {:json, response_body}} ->
        case parse_with_id(response_body) do
          {:ok, message, usage, _response_id} ->
            {:ok, message["content"] || "", %{usage: usage, logprobs: nil}}

          error ->
            error
        end

      {:ok, other} ->
        {:error, {:bad_response, other}}

      {:error, error} ->
        {:error, error}
    end
  end

  # 调用方沿用 chat/completions 的 `max_tokens` 口径（archive 摘要传 extra: %{max_tokens: n}）；
  # Responses 的字段名是 `max_output_tokens`，不翻译会被网关当未知字段拒绝。
  defp normalize_output_limit(body, opts) do
    limit =
      body[:max_tokens] || body["max_tokens"] || Keyword.get(opts, :max_tokens)

    case limit do
      n when is_integer(n) and n > 0 ->
        body
        |> Map.delete(:max_tokens)
        |> Map.delete("max_tokens")
        |> Map.put(:max_output_tokens, n)

      _ ->
        body
    end
  end

  # 无工具时不出 tools 键：与 Client.complete/3 的 chat 路径一致，避免空数组被网关拒绝。
  defp drop_empty_tools(body, []), do: Map.delete(body, :tools)
  defp drop_empty_tools(body, _wire_tools), do: body

  def input(messages) do
    Enum.flat_map(messages, fn
      %{"role" => "assistant"} = message ->
        opaque = response_items(message)

        text =
          if message["content"] in [nil, ""],
            do: [],
            else: [%{"role" => "assistant", "content" => message["content"]}]

        calls =
          Enum.map(message["tool_calls"] || [], fn call ->
            function = call["function"] || %{}

            %{
              "type" => "function_call",
              "call_id" => call["id"],
              "name" => function["name"],
              "arguments" => function["arguments"] || "{}"
            }
          end)

        opaque ++ text ++ calls

      %{"role" => "tool", "tool_call_id" => id, "content" => content} ->
        [%{"type" => "function_call_output", "call_id" => id, "output" => to_string(content)}]

      %{"role" => role} = message when role in ["user", "system"] ->
        [input_message(message)]

      _message ->
        []
    end)
  end

  defp input_message(message) do
    message
    |> Map.take(["role", "content", "name"])
    |> Map.update("content", nil, &input_content/1)
  end

  defp input_content(content) when is_list(content), do: Enum.map(content, &input_content_part/1)
  defp input_content(content), do: content

  defp input_content_part(%{"type" => "text", "text" => text}) do
    %{"type" => "input_text", "text" => text}
  end

  defp input_content_part(%{"type" => "image_url", "image_url" => %{"url" => url} = image}) do
    %{"type" => "input_image", "image_url" => url}
    |> maybe_put("detail", image["detail"])
  end

  defp input_content_part(%{"type" => "image_url", "image_url" => url}) when is_binary(url) do
    %{"type" => "input_image", "image_url" => url}
  end

  defp input_content_part(part), do: part

  def tools(tools) do
    Enum.map(tools, fn tool ->
      function = tool["function"] || tool[:function] || %{}

      %{
        "type" => "function",
        "name" => function["name"] || function[:name],
        "description" => function["description"] || function[:description],
        "parameters" => function["parameters"] || function[:parameters] || %{}
      }
    end)
  end

  def parse(body) do
    case parse_with_id(body) do
      {:ok, message, usage, _response_id} -> {:ok, message, usage}
      error -> error
    end
  end

  # Tool output must not travel alone: delta with function_call_output but no matching function_call means pairing was split by previous_response_id. Some gateways reject with 400. Use full in that case. Text deltas still save tokens.
  defp tool_output_orphaned_in_delta?(delta) when is_list(delta) do
    call_ids =
      delta
      |> Enum.filter(&(&1["type"] == "function_call"))
      |> Enum.map(& &1["call_id"])
      |> MapSet.new()

    Enum.any?(delta, fn
      %{"type" => "function_call_output", "call_id" => id} when is_binary(id) and id != "" ->
        not MapSet.member?(call_ids, id)

      _ ->
        false
    end)
  end

  defp tool_output_orphaned_in_delta?(_), do: false

  defp tool_output_missing_error?(body) when is_binary(body) do
    body |> String.downcase() |> String.contains?("no tool call found for tool output")
  end

  defp tool_output_missing_error?({:http_error, _, body}), do: tool_output_missing_error?(body)
  defp tool_output_missing_error?({:response_error, body}), do: tool_output_missing_error?(body)
  defp tool_output_missing_error?(_), do: false

  defp run_request(client, logical_input, wire_tools, opts, state) do
    caps = capabilities(client)
    full_body = full_body(client, logical_input, wire_tools, opts, caps)
    envelope = Map.delete(full_body, :input)

    {plan, plan_reason} =
      if client.responses_continuation and caps.continuation and not state.force_full do
        case Continuation.plan_with_reason(client.responses_checkpoint, envelope, logical_input) do
          {:continue, _response_id, delta} = continuation_plan ->
            if tool_output_orphaned_in_delta?(delta) do
              Newbee.DebugLog.log(
                :llm,
                "responses continuation skipped: tool output without call in delta, using full"
              )

              {:full, :tool_output_without_call_in_delta}
            else
              {continuation_plan, :continue}
            end

          {:full, reason} ->
            {:full, reason}
        end
      else
        {:full, :disabled}
      end

    {request_body, continued?} =
      case plan do
        {:continue, response_id, delta} ->
          Newbee.DebugLog.log(:llm, "responses continuation delta_items=#{length(delta)}")

          {full_body |> Map.put(:input, delta) |> Map.put(:previous_response_id, response_id), true}

        :full ->
          Newbee.DebugLog.log(
            :llm,
            "responses full input_items=#{length(logical_input)} continuation=#{plan_reason}"
          )

          {full_body, false}
      end

    attempt = {caps.stream, caps.encrypted_reasoning, caps.continuation, continued?, state.force_full}

    if MapSet.member?(state.attempts, attempt) do
      {:error, {:responses_retry_loop, attempt}}
    else
      state = %{state | attempts: MapSet.put(state.attempts, attempt)}
      on_text = Keyword.get(opts, :on_text, fn _ -> :ok end)
      on_reasoning = Keyword.get(opts, :on_reasoning, fn _ -> :ok end)

      case perform(client, request_body, on_text, on_reasoning) do
        {:ok, result} ->
          finish(client, caps, envelope, logical_input, result, on_text, on_reasoning)

        {:interrupted, _content} = interrupted ->
          interrupted

        {:error, error} ->
          recover_or_error(
            client,
            logical_input,
            wire_tools,
            opts,
            state,
            caps,
            continued?,
            error
          )
      end
    end
  end

  defp full_body(client, logical_input, wire_tools, opts, caps) do
    %{
      model: client.model,
      input: logical_input,
      stream: caps.stream,
      tools: wire_tools
    }
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:reasoning, reasoning(client.reasoning_effort))
    |> maybe_put(:prompt_cache_key, client.cache_key)
    |> maybe_put(:prompt_cache_options, client.prompt_cache_options)
    |> maybe_put(:store, if(client.responses_continuation and caps.continuation, do: true))
    |> maybe_put(:include, if(caps.encrypted_reasoning, do: ["reasoning.encrypted_content"]))
    |> Map.merge(Keyword.get(opts, :extra, %{}))
  end

  defp recover_or_error(
         client,
         logical_input,
         wire_tools,
         opts,
         state,
         caps,
         continued?,
         error
       ) do
    cond do
      continued? and not state.replayed_previous and previous_response_not_found?(error) ->
        Newbee.DebugLog.log(:llm, "responses continuation expired; retrying full request")
        Continuation.clear(client.responses_checkpoint)

        # 该 route 实际不支持/不保留 previous_response_id：把 continuation 能力降级，
        # 重试成功后才落盘——本会话后续 turn 与重启后都不再白试续接（否则每个 turn
        # 都先失败一次再全量重放，等于每步白付一个全 prompt）。
        retry_with_capability(client, :continuation, false, error, fn ->
          run_request(client, logical_input, wire_tools, opts, %{
            state
            | force_full: true,
              replayed_previous: true
          })
        end)

      continued? and not state.replayed_previous and tool_output_missing_error?(error) ->
        Newbee.DebugLog.log(:llm, "responses tool output orphaned in delta; retrying full request")
        Continuation.clear(client.responses_checkpoint)

        run_request(client, logical_input, wire_tools, opts, %{
          state
          | force_full: true,
            replayed_previous: true
        })

      downgrade = capability_downgrade(caps, error) ->
        {capability, value} = downgrade

        force_full =
          if capability == :continuation,
            do: true,
            else: state.force_full

        retry_with_capability(client, capability, value, error, fn ->
          run_request(client, logical_input, wire_tools, opts, %{state | force_full: force_full})
        end)

      match?({:http_error, _, _}, error) ->
        {:http_error, status, body} = error
        {:error, {:http_error, status, encoded(body)}}

      true ->
        {:error, error}
    end
  end

  # 能力降级是"猜测 + 重试"：只有关掉该能力后重试**确实成功**，才把这一猜测落盘复用；
  # 重试仍以同一错误失败，说明降级没解决问题（例如把 "must be passed back" 里的 "passed"
  # 误当成 "sse"，判定网关不支持流式），就地回退内存标记，避免误判被永久固化。
  defp retry_with_capability(client, capability, value, error, retry) do
    put_capability(client, capability, value)

    Newbee.DebugLog.log(
      :llm,
      "responses capability downgrade #{capability}=#{inspect(value)}; retrying"
    )

    case retry.() do
      {:ok, _message, _usage} = ok ->
        persist_capability(client, capability, value)
        ok

      {:error, retry_error} = failed ->
        if error_signature(retry_error) == error_signature(error) do
          revert_capability(client, capability)

          Newbee.DebugLog.log(
            :llm,
            "responses capability downgrade #{capability} reverted: retry hit the same error"
          )
        end

        failed

      other ->
        other
    end
  end

  defp error_signature({:error, error}), do: error_signature(error)
  defp error_signature({:http_error, status, body}), do: {status, error_text(body)}
  defp error_signature(other), do: other

  defp finish(client, caps, envelope, logical_input, result, on_text, on_reasoning) do
    parsed =
      case result do
        {:json, body} ->
          case parse_with_id(body) do
            {:ok, message, _usage, _response_id} = ok ->
              emit_complete_message(message, on_text, on_reasoning)
              ok

            error ->
              error
          end

        {:stream, message, usage, response_id} ->
          {:ok, message, usage, response_id}
      end

    case parsed do
      {:ok, message, usage, response_id} ->
        next_prefix = logical_input ++ input([message])

        if client.responses_continuation and caps.continuation and is_binary(response_id) and response_id != "" do
          Continuation.commit(client.responses_checkpoint, envelope, next_prefix, response_id)
        else
          Continuation.clear(client.responses_checkpoint)
        end

        {:ok, message, usage}

      error ->
        error
    end
  end

  defp emit_complete_message(message, on_text, on_reasoning) do
    if message["content"] not in [nil, ""], do: on_text.(message["content"])
    if message["reasoning"] not in [nil, ""], do: on_reasoning.(message["reasoning"])
  end

  defp parse_with_id(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_with_id(decoded)
      {:error, error} -> {:error, {:bad_response, error}}
    end
  end

  defp parse_with_id(%{"error" => error}) when not is_nil(error),
    do: {:error, {:api_error, error}}

  defp parse_with_id(%{"output" => output} = body) when is_list(output) do
    content = output_text(output)
    tool_calls = tool_calls(output)
    opaque = opaque_items(output)
    reasoning = reasoning_text(opaque)

    message =
      %{"role" => "assistant", "content" => content}
      |> maybe_put("tool_calls", tool_calls)
      |> maybe_put("reasoning", reasoning)
      |> maybe_put("_responses_items", opaque)

    {:ok, message, usage(body["usage"] || %{}), body["id"]}
  end

  defp parse_with_id(body), do: {:error, {:bad_response, body}}

  defp perform(client, %{} = body, on_text, on_reasoning) do
    request_headers = Newbee.LLM.Client.request_headers(client)

    _dbg_id =
      Newbee.LLM.HttpDebug.start_exchange(%{
        session_id: Newbee.LLM.HttpDebug.session_id_from_cache_key(client.cache_key),
        model: client.model,
        base_url: client.base_url,
        endpoint: "/responses",
        method: "POST",
        url: client.base_url <> "/responses",
        api: "responses",
        req_headers: request_headers,
        req_body: body
      })

    result =
      if body[:stream] do
        perform_stream(client, body, on_text, on_reasoning)
      else
        perform_json(client, body)
      end

    Newbee.LLM.HttpDebug.finish_current(result)
    result
  end

  defp perform_json(client, body) do
    req = build_req(client, body, false)

    case request_json_with_retry(req, @overload_retries) do
      {:ok, %{status: 200, body: response_body} = resp} ->
        Newbee.LLM.HttpDebug.note_current_response(resp.status, resp.headers)
        {:ok, {:json, response_body}}

      {:ok, %{status: status, body: response_body} = resp} ->
        Newbee.LLM.HttpDebug.note_current_response(resp.status, resp.headers)
        {:error, {:http_error, status, response_body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp perform_stream(client, body, on_text, on_reasoning) do
    req = build_req(client, body, true)
    request_stream_with_retry(req, client, on_text, on_reasoning, @overload_retries)
  end

  defp build_req(client, body, stream?) do
    options =
      [
        url: client.base_url <> "/responses",
        method: :post,
        headers: Newbee.LLM.Client.request_headers(client),
        json: body,
        receive_timeout: 120_000,
        retry: false
      ]
      |> Keyword.merge(client.req_options)

    options = if stream?, do: Keyword.put(options, :into, :self), else: options
    Req.new(options)
  end

  defp request_stream_with_retry(req, client, on_text, on_reasoning, left) do
    case Req.request(req) do
      {:ok, %{status: status} = resp} when status in @overload_statuses and left > 0 ->
        _ = drain_async(resp, client)

        if Newbee.LLM.Client.interrupted?(client) do
          {:interrupted, ""}
        else
          Process.sleep(@overload_delay)
          request_stream_with_retry(req, client, on_text, on_reasoning, left - 1)
        end

      {:ok, %{status: 200} = resp} ->
        Newbee.LLM.HttpDebug.note_current_response(resp.status, resp.headers)

        if event_stream?(resp) do
          consume_sse(resp, client, on_text, on_reasoning)
        else
          case drain_async(resp, client) do
            {:ok, bytes} -> decode_stream_or_json(bytes, on_text, on_reasoning)
            {:interrupted, content} -> {:interrupted, content}
            {:error, error} -> {:error, error}
          end
        end

      {:ok, resp} ->
        Newbee.LLM.HttpDebug.note_current_response(resp.status, resp.headers)

        case resp.body do
          body when is_binary(body) and body != "" ->
            {:error, {:http_error, resp.status, body}}

          _ ->
            case drain_async(resp, client) do
              {:ok, body} -> {:error, {:http_error, resp.status, body}}
              {:interrupted, content} -> {:interrupted, content}
              {:error, error} -> {:error, error}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode_stream_or_json(bytes, on_text, on_reasoning) do
    if String.starts_with?(String.trim_leading(bytes), "data:") do
      consume_sse_payload(bytes, on_text, on_reasoning)
    else
      case Jason.decode(bytes) do
        {:ok, body} -> {:ok, {:json, body}}
        {:error, error} -> {:error, {:bad_response, error}}
      end
    end
  end

  defp event_stream?(resp) do
    resp
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "text/event-stream"))
  end

  defp consume_sse(resp, client, on_text, on_reasoning) do
    acc = sse_acc()
    started_at = System.monotonic_time(:millisecond)

    case sse_loop(resp, client, on_text, on_reasoning, acc, "", started_at) do
      {:done, acc, rest} -> finish_sse(apply_sse_buffer(acc, rest, on_text, on_reasoning))
      {:interrupted, acc} -> {:interrupted, acc.content}
      {:error, error} -> {:error, error}
    end
  end

  defp consume_sse_payload(bytes, on_text, on_reasoning) do
    acc = apply_sse_buffer(sse_acc(), bytes, on_text, on_reasoning)
    finish_sse(acc)
  end

  defp sse_loop(resp, client, on_text, on_reasoning, acc, buffer, started_at) do
    receive do
      message ->
        if Newbee.LLM.Client.interrupted?(client) do
          Req.cancel_async_response(resp)
          {:interrupted, acc}
        else
          case Req.parse_message(resp, message) do
            {:ok, [data: data]} ->
              Newbee.LLM.HttpDebug.append_raw(IO.iodata_to_binary(data))
              {events, rest} = split_sse(buffer <> IO.iodata_to_binary(data))
              acc = Enum.reduce(events, acc, &apply_sse_event(&1, &2, on_text, on_reasoning))
              sse_loop(resp, client, on_text, on_reasoning, acc, rest, started_at)

            {:ok, [:done]} ->
              {:done, acc, buffer}

            {:ok, [trailers: _]} ->
              sse_loop(resp, client, on_text, on_reasoning, acc, buffer, started_at)

            {:error, error} ->
              {:error, error}

            :unknown ->
              sse_loop(resp, client, on_text, on_reasoning, acc, buffer, started_at)
          end
        end
    after
      100 ->
        cond do
          Newbee.LLM.Client.interrupted?(client) ->
            Req.cancel_async_response(resp)
            {:interrupted, acc}

          System.monotonic_time(:millisecond) - started_at > @stream_timeout ->
            Req.cancel_async_response(resp)
            {:error, {:responses_stream_error, "stream timeout"}}

          true ->
            sse_loop(resp, client, on_text, on_reasoning, acc, buffer, started_at)
        end
    end
  end

  defp drain_async(resp, client, chunks \\ []) do
    receive do
      message ->
        if Newbee.LLM.Client.interrupted?(client) do
          Req.cancel_async_response(resp)
          {:interrupted, ""}
        else
          case Req.parse_message(resp, message) do
            {:ok, [data: data]} -> drain_async(resp, client, [IO.iodata_to_binary(data) | chunks])
            {:ok, [:done]} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
            {:ok, [trailers: _]} -> drain_async(resp, client, chunks)
            {:error, error} -> {:error, error}
            :unknown -> drain_async(resp, client, chunks)
          end
        end
    after
      120_000 ->
        Req.cancel_async_response(resp)
        {:error, {:responses_stream_error, "response body timeout"}}
    end
  end

  defp sse_acc do
    %{
      content: "",
      reasoning: "",
      tool_calls: %{},
      opaque_items: %{},
      usage: %{},
      response_id: nil,
      completed?: false,
      error: nil
    }
  end

  defp apply_sse_buffer(acc, "", _on_text, _on_reasoning), do: acc

  defp apply_sse_buffer(acc, buffer, on_text, on_reasoning) do
    {events, rest} = split_sse(buffer <> "\n\n")
    acc = Enum.reduce(events, acc, &apply_sse_event(&1, &2, on_text, on_reasoning))

    if String.trim(rest) == "" do
      acc
    else
      apply_sse_event(rest, acc, on_text, on_reasoning)
    end
  end

  defp split_sse(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    events =
      complete
      |> Enum.map(&sse_data/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    {events, rest}
  end

  defp sse_data(block) do
    block
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn line -> line |> String.trim_leading("data:") |> String.trim_leading() end)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp apply_sse_event("[DONE]", acc, _on_text, _on_reasoning), do: acc

  defp apply_sse_event(data, acc, on_text, on_reasoning) do
    case Jason.decode(data) do
      {:ok, event} -> apply_response_event(event, acc, on_text, on_reasoning)
      {:error, _} -> acc
    end
  end

  defp apply_response_event(
         %{"type" => "response.output_text.delta", "delta" => delta},
         acc,
         on_text,
         _
       )
       when is_binary(delta) do
    on_text.(delta)
    %{acc | content: acc.content <> delta}
  end

  defp apply_response_event(
         %{"type" => type, "delta" => delta},
         acc,
         _,
         on_reasoning
       )
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] and
              is_binary(delta) do
    on_reasoning.(delta)
    %{acc | reasoning: acc.reasoning <> delta}
  end

  defp apply_response_event(
         %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = item} =
           event,
         acc,
         _,
         _
       ) do
    put_tool_item(acc, event_key(event, item), item, false)
  end

  defp apply_response_event(
         %{"type" => "response.function_call_arguments.delta", "delta" => delta} = event,
         acc,
         _,
         _
       )
       when is_binary(delta) do
    key = event_key(event, %{})
    slot = Map.get(acc.tool_calls, key, empty_tool_slot(event))
    slot = %{slot | arguments: slot.arguments <> delta}
    %{acc | tool_calls: Map.put(acc.tool_calls, key, slot)}
  end

  defp apply_response_event(
         %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item} =
           event,
         acc,
         _,
         _
       ) do
    put_tool_item(acc, event_key(event, item), item, true)
  end

  defp apply_response_event(
         %{"type" => "response.output_item.done", "item" => %{"type" => "message"} = item},
         acc,
         on_text,
         _
       ) do
    put_final_text(acc, item_text(item), on_text)
  end

  defp apply_response_event(
         %{"type" => "response.output_item.done", "item" => %{"type" => "reasoning"} = item} =
           event,
         acc,
         _,
         on_reasoning
       ) do
    acc
    |> put_opaque_item(event_key(event, item), item)
    |> put_final_reasoning(reasoning_text([item]), on_reasoning)
  end

  defp apply_response_event(%{"type" => "response.created", "response" => response}, acc, _, _)
       when is_map(response) do
    %{acc | response_id: response["id"] || acc.response_id}
  end

  defp apply_response_event(
         %{"type" => "response.completed", "response" => response},
         acc,
         on_text,
         on_reasoning
       )
       when is_map(response) do
    acc = merge_final_output(acc, response["output"] || [], on_text, on_reasoning)

    %{
      acc
      | response_id: response["id"] || acc.response_id,
        usage: usage(response["usage"] || %{}),
        completed?: true
    }
  end

  defp apply_response_event(%{"type" => type, "response" => response}, acc, _, _)
       when type in ["response.failed", "response.incomplete"] do
    %{acc | error: response["error"] || response["incomplete_details"] || response}
  end

  defp apply_response_event(%{"type" => "error"} = event, acc, _, _) do
    %{acc | error: event["error"] || event}
  end

  defp apply_response_event(_event, acc, _on_text, _on_reasoning), do: acc

  defp merge_final_output(acc, output, on_text, on_reasoning) when is_list(output) do
    output
    |> Enum.with_index()
    |> Enum.reduce(acc, fn
      {%{"type" => "message"} = item, _index}, current ->
        put_final_text(current, item_text(item), on_text)

      {%{"type" => "function_call"} = item, index}, current ->
        put_tool_item(current, {index, item["id"] || item["call_id"]}, item, true)

      {%{"type" => "reasoning"} = item, index}, current ->
        current
        |> put_opaque_item({index, item["id"]}, item)
        |> put_final_reasoning(reasoning_text([item]), on_reasoning)

      {_item, _index}, current ->
        current
    end)
  end

  defp finish_sse(%{error: error}) when not is_nil(error),
    do: {:error, {:response_error, error}}

  defp finish_sse(acc) do
    message =
      %{"role" => "assistant", "content" => acc.content}
      |> maybe_put("tool_calls", assemble_stream_tool_calls(acc.tool_calls))
      |> maybe_put("reasoning", acc.reasoning)
      |> maybe_put("_responses_items", assemble_opaque_items(acc.opaque_items))

    {:ok, {:stream, message, acc.usage, acc.response_id}}
  end

  defp put_final_text(acc, "", _on_text), do: acc

  defp put_final_text(%{content: ""} = acc, text, on_text) when is_binary(text) do
    on_text.(text)
    %{acc | content: text}
  end

  defp put_final_text(acc, _text, _on_text), do: acc

  defp put_final_reasoning(acc, "", _on_reasoning), do: acc

  defp put_final_reasoning(%{reasoning: ""} = acc, text, on_reasoning) when is_binary(text) do
    on_reasoning.(text)
    %{acc | reasoning: text}
  end

  defp put_final_reasoning(acc, _text, _on_reasoning), do: acc

  defp put_tool_item(acc, key, item, complete?) do
    current = Map.get(acc.tool_calls, key, empty_tool_slot(item))

    arguments =
      cond do
        complete? and is_binary(item["arguments"]) -> item["arguments"]
        is_binary(item["arguments"]) and current.arguments == "" -> item["arguments"]
        true -> current.arguments
      end

    slot = %{
      id: item["call_id"] || current.id || item["id"],
      name: item["name"] || current.name,
      arguments: arguments
    }

    %{acc | tool_calls: Map.put(acc.tool_calls, key, slot)}
  end

  defp empty_tool_slot(item) do
    %{
      id: item["call_id"] || item["id"],
      name: item["name"],
      arguments: item["arguments"] || ""
    }
  end

  defp event_key(event, item) do
    {
      event["output_index"] || 0,
      event["item_id"] || item["id"] || event["call_id"] || item["call_id"] || ""
    }
  end

  defp put_opaque_item(acc, key, item) do
    %{acc | opaque_items: Map.put(acc.opaque_items, key, item)}
  end

  defp assemble_stream_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {key, _} -> inspect(key) end)
    |> Enum.map(fn {_key, slot} ->
      %{
        "id" => slot.id,
        "type" => "function",
        "function" => %{"name" => slot.name, "arguments" => slot.arguments || "{}"}
      }
    end)
  end

  defp assemble_opaque_items(items) do
    items
    |> Enum.sort_by(fn {key, _} -> inspect(key) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq_by(fn item -> item["id"] || :erlang.phash2(item) end)
  end

  defp output_text(output) do
    output
    |> Enum.filter(&match?(%{"type" => "message"}, &1))
    |> Enum.map_join(&item_text/1)
  end

  defp item_text(%{"content" => parts}) when is_list(parts) do
    for %{"type" => type, "text" => text} <- parts,
        type in ["output_text", "text"],
        into: "",
        do: text
  end

  defp item_text(_), do: ""

  defp tool_calls(output) do
    for %{"type" => "function_call"} = call <- output do
      %{
        "id" => call["call_id"] || call["id"],
        "type" => "function",
        "function" => %{"name" => call["name"], "arguments" => call["arguments"] || "{}"}
      }
    end
  end

  defp opaque_items(output) do
    Enum.filter(output, &match?(%{"type" => "reasoning"}, &1))
  end

  defp response_items(%{"_responses_items" => items}) when is_list(items) do
    Enum.filter(items, &match?(%{"type" => "reasoning"}, &1))
  end

  defp response_items(_message), do: []

  defp reasoning_text(items) do
    items
    |> Enum.flat_map(&reasoning_parts/1)
    |> Enum.map_join(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  # OpenAI 系把思考放在 summary[]；DeepSeek/国御这类网关放在 content[] 的 reasoning_text
  # 段且 summary 为空数组。两条都认，否则非流式路径与最终 output 合并会把整段思考丢掉，
  # 历史回放里就再也看不到 Think。
  defp reasoning_parts(item) do
    summarized =
      case item["summary"] do
        parts when is_list(parts) -> Enum.filter(parts, &is_map/1)
        _ -> []
      end

    content =
      case item["content"] do
        parts when is_list(parts) ->
          Enum.filter(parts, &match?(%{"type" => type} when type in ["reasoning_text", "text"], &1))

        _ ->
          []
      end

    summarized ++ content
  end

  defp capabilities(client) do
    scope = capability_scope(client)

    stored =
      @capability_key
      |> :persistent_term.get(%{})
      |> Map.get(scope, %{})
      |> Map.merge(load_persisted(scope))

    configured_stream = Map.get(client, :responses_stream, :auto)

    stream =
      case configured_stream do
        false -> false
        "false" -> false
        _ -> Map.get(stored, :stream, true)
      end

    %{
      stream: stream,
      encrypted_reasoning: Map.get(stored, :encrypted_reasoning, true),
      continuation: Map.get(stored, :continuation, true)
    }
  end

  defp put_capability(client, capability, value) do
    all = :persistent_term.get(@capability_key, %{})
    scope = capability_scope(client)
    current = Map.get(all, scope, %{})

    :persistent_term.put(
      @capability_key,
      Map.put(all, scope, Map.put(current, capability, value))
    )

    :ok
  end

  defp revert_capability(client, capability) do
    all = :persistent_term.get(@capability_key, %{})
    scope = capability_scope(client)
    current = Map.get(all, scope, %{})

    :persistent_term.put(
      @capability_key,
      Map.put(all, scope, Map.delete(current, capability))
    )

    :ok
  end

  # 落盘：重启后复用已探明（且经重试验证）的能力，避免每次重启重新踩一遍 400 全量重放。
  defp persist_capability(client, capability, value) do
    Caps.put(capability_scope(client), capability, value)
  end

  # 进程内缓存磁盘快照，避免每个请求都读盘；只把已探测的降级键（false）合并进来。
  defp load_persisted(scope) do
    key = {:newbee, :responses_caps_persisted, scope}

    case :persistent_term.get(key, :unset) do
      :unset ->
        caps = Caps.load(scope)
        :persistent_term.put(key, caps)
        caps

      caps ->
        caps
    end
  end

  defp capability_scope(client), do: {client.base_url, client.model}

  defp capability_downgrade(caps, {:http_error, status, body})
       when status in [400, 406, 415, 422] do
    text = error_text(body)

    cond do
      caps.encrypted_reasoning and status in [400, 422] and
          (String.contains?(text, "reasoning.encrypted_content") or
             (String.contains?(text, "include") and unsupported_text?(text))) ->
        {:encrypted_reasoning, false}

      caps.continuation and
          (String.contains?(text, "previous_response_id requires") or
             String.contains?(text, "api-key account") or
             (String.contains?(text, "previous_response_id") and
                (String.contains?(text, "requires") or String.contains?(text, "not supported") or
                   String.contains?(text, "unsupported") or String.contains?(text, "billing") or
                   String.contains?(text, "quota")))) ->
        {:continuation, false}

      caps.stream and stream_unsupported?(text) ->
        {:stream, false}

      true ->
        nil
    end
  end

  defp capability_downgrade(_caps, _error), do: nil

  # 按词边界匹配"不支持"线索：老实现用 String.contains?(text, "sse")，会被
  # "must be passed back"（passed 里含 sse）命中，把支持流式的网关误判成不支持，
  # 再被持久化就永久失去流式（连带实时思考流）。
  defp stream_unsupported?(text) do
    unsupported_text?(text) and
      Regex.match?(~r/\bstream(?:ing)?\b|\bevent[-\s]?stream\b|\bsse\b/, text)
  end

  defp unsupported_text?(text) do
    Regex.match?(
      ~r/\bunsupported\b|\bnot supported\b|\bunknown\b|\binvalid\b|\bnot allowed\b/,
      text
    )
  end

  # 只匹配报错正文里的 message/description：JSON 里的 `"type":"invalid_request_error"`
  # 是各家网关的固定分类码，任何 400 都带，混进来会让所有 4xx 都像"能力缺失"。
  defp error_text(body) do
    body
    |> encoded()
    |> error_message()
    |> String.downcase()
  end

  defp error_message(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) -> error_message_field(decoded, text)
      _ -> text
    end
  end

  defp error_message_field(%{"error" => error}, fallback) when is_map(error) do
    case error["message"] || error["description"] || error["detail"] do
      message when is_binary(message) -> message
      _ -> fallback
    end
  end

  defp error_message_field(%{"message" => message}, _fallback) when is_binary(message), do: message
  defp error_message_field(%{"detail" => detail}, _fallback) when is_binary(detail), do: detail
  defp error_message_field(_decoded, fallback), do: fallback

  defp previous_response_not_found?({:http_error, _status, body}),
    do: previous_response_not_found?(body)

  defp previous_response_not_found?({:response_error, body}),
    do: previous_response_not_found?(body)

  defp previous_response_not_found?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        previous_response_not_found?(decoded)

      _ ->
        String.contains?(String.downcase(body), "previous_response_not_found") or
          String.contains?(String.downcase(body), "referenced response not found")
    end
  end

  defp previous_response_not_found?(%{"error" => error}) when is_map(error) do
    previous_response_not_found?(error)
  end

  defp previous_response_not_found?(%{} = error) do
    error["code"] == "previous_response_not_found" or
      error["type"] == "previous_response_not_found" or
      String.contains?(String.downcase(to_string(error["message"] || "")), "previous response") or
      String.contains?(String.downcase(to_string(error["message"] || "")), "referenced response")
  end

  defp previous_response_not_found?(_), do: false

  defp usage(usage) do
    details = usage["input_tokens_details"] || %{}

    Newbee.LLM.Client.normalize_usage(%{
      "prompt_tokens" => usage["input_tokens"] || 0,
      "completion_tokens" => usage["output_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0,
      "cache_read_tokens" => details["cached_tokens"] || 0,
      "cache_write_tokens" => details["cache_write_tokens"] || 0
    })
  end

  defp request_json_with_retry(req, 0), do: Req.request(req)

  defp request_json_with_retry(req, left) do
    case Req.request(req) do
      {:ok, %{status: status}} when status in @overload_statuses ->
        Process.sleep(@overload_delay)
        request_json_with_retry(req, left - 1)

      result ->
        result
    end
  end

  defp reasoning(nil), do: nil
  defp reasoning("off"), do: %{effort: "none"}
  defp reasoning(effort), do: %{effort: effort}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encoded(body) when is_binary(body), do: body
  defp encoded(body), do: Jason.encode!(body)
end
