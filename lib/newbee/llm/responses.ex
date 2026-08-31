defmodule Newbee.LLM.Responses do
  @moduledoc false

  alias Newbee.LLM.ResponsesContinuation, as: Continuation

  @overload_statuses [429, 500, 502, 503, 529]
  @overload_retries 5
  @overload_delay 1_000
  @stream_timeout 300_000
  @capability_key {__MODULE__, :capabilities}

  def request(client, messages, tools, opts \\ []) do
    logical_input = input(messages)
    wire_tools = tools(tools)

    state = %{
      attempts: MapSet.new(),
      force_full: false,
      replayed_previous: false
    }

    run_request(client, logical_input, wire_tools, opts, state)
  end

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
        [Map.take(message, ["role", "content", "name"])]

      _message ->
        []
    end)
  end

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

  defp run_request(client, logical_input, wire_tools, opts, state) do
    caps = capabilities(client)
    full_body = full_body(client, logical_input, wire_tools, opts, caps)
    envelope = Map.delete(full_body, :input)

    plan =
      if client.responses_continuation and caps.continuation and not state.force_full do
        Continuation.plan(client.responses_checkpoint, envelope, logical_input)
      else
        :full
      end

    {request_body, continued?} =
      case plan do
        {:continue, response_id, delta} ->
          Newbee.DebugLog.log(:llm, "responses continuation delta_items=#{length(delta)}")

          {full_body |> Map.put(:input, delta) |> Map.put(:previous_response_id, response_id), true}

        :full ->
          Newbee.DebugLog.log(:llm, "responses full input_items=#{length(logical_input)}")
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

        run_request(client, logical_input, wire_tools, opts, %{
          state
          | force_full: true,
            replayed_previous: true
        })

      downgrade = capability_downgrade(caps, error) ->
        {capability, value} = downgrade
        put_capability(client, capability, value)

        Newbee.DebugLog.log(
          :llm,
          "responses capability downgrade #{capability}=#{inspect(value)}; retrying"
        )

        force_full =
          if capability == :continuation,
            do: true,
            else: state.force_full

        run_request(client, logical_input, wire_tools, opts, %{state | force_full: force_full})

      match?({:http_error, _, _}, error) ->
        {:http_error, status, body} = error
        {:error, {:http_error, status, encoded(body)}}

      true ->
        {:error, error}
    end
  end

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
    if body[:stream] do
      perform_stream(client, body, on_text, on_reasoning)
    else
      perform_json(client, body)
    end
  end

  defp perform_json(client, body) do
    req = build_req(client, body, false)

    case request_json_with_retry(req, @overload_retries) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, {:json, response_body}}

      {:ok, %{status: status, body: response_body}} ->
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
    |> Enum.flat_map(fn item -> item["summary"] || [] end)
    |> Enum.map_join(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp capabilities(client) do
    stored = :persistent_term.get(@capability_key, %{}) |> Map.get(capability_scope(client), %{})
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
             String.contains?(text, "previous_response_id") and
               (String.contains?(text, "requires") or String.contains?(text, "not supported") or
                  String.contains?(text, "unsupported") or String.contains?(text, "billing") or
                  String.contains?(text, "quota"))) ->
        {:continuation, false}

      caps.stream and
        (String.contains?(text, "stream") or String.contains?(text, "event-stream") or
           String.contains?(text, "sse")) and unsupported_text?(text) ->
        {:stream, false}

      true ->
        nil
    end
  end

  defp capability_downgrade(_caps, _error), do: nil

  defp unsupported_text?(text) do
    Enum.any?(
      ["unsupported", "not supported", "unknown", "invalid", "not allowed"],
      &String.contains?(text, &1)
    )
  end

  defp error_text(body) when is_binary(body), do: String.downcase(body)
  defp error_text(body), do: body |> encoded() |> String.downcase()

  defp previous_response_not_found?({:http_error, _status, body}),
    do: previous_response_not_found?(body)

  defp previous_response_not_found?({:response_error, body}),
    do: previous_response_not_found?(body)

  defp previous_response_not_found?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> previous_response_not_found?(decoded)
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
    Newbee.LLM.Client.normalize_usage(%{
      "prompt_tokens" => usage["input_tokens"] || 0,
      "completion_tokens" => usage["output_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0,
      "cache_read_tokens" => get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
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
  defp reasoning("max"), do: %{effort: "high"}
  defp reasoning("off"), do: %{effort: "none"}
  defp reasoning(effort), do: %{effort: effort}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encoded(body) when is_binary(body), do: body
  defp encoded(body), do: Jason.encode!(body)
end
