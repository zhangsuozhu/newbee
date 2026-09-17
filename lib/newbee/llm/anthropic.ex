defmodule Newbee.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API adapter.

  The OpenCode Zen gateway exposes some models, including union-alpha, through
  the Anthropic-compatible `/messages` endpoint. This module translates the
  internal OpenAI-shaped transcript into Anthropic content blocks and restores
  the internal assistant/tool-call message shape on the way back.
  """

  @overload_statuses [429, 500, 502, 503, 529]
  @overload_retries 5
  @overload_delay 1_000
  @stream_timeout 300_000
  @response_timeout 120_000
  @default_max_tokens 8_192
  @anthropic_version "2023-06-01"

  @doc "Stream a message through Anthropic's Messages API."
  def request(client, messages, tools, opts \\ []) do
    {messages, dropped} = Newbee.LLM.ImagePolicy.project_for(client, messages)

    if dropped > 0 do
      Newbee.DebugLog.log(:llm, "image offload dropped=" <> Integer.to_string(dropped))
    end

    messages = Newbee.LLM.Client.sanitize_messages(messages)
    body = request_body(client, messages, tools, opts, true)
    on_text = Keyword.get(opts, :on_text, fn _ -> :ok end)
    on_reasoning = Keyword.get(opts, :on_reasoning, fn _ -> :ok end)
    perform(client, body, on_text, on_reasoning)
  end

  @doc "Complete a message through Anthropic's non-streaming Messages API."
  def complete(client, messages, opts \\ []) do
    messages = Newbee.LLM.Client.sanitize_messages(messages)
    body = request_body(client, messages, Keyword.get(opts, :tools, []), opts, false)

    case perform(client, body, fn _ -> :ok end, fn _ -> :ok end) do
      {:ok, message, usage} ->
        {:ok, message["content"] || "", %{usage: usage, logprobs: nil}}

      other ->
        other
    end
  end

  @doc false
  def to_wire_messages(messages) when is_list(messages) do
    {system_parts, conversation} =
      Enum.reduce(messages, {[], []}, fn message, {systems, messages_acc} ->
        role = message |> field("role", :role) |> normalize_role()
        content = field(message, "content", :content)

        case role do
          "system" ->
            {[content | systems], messages_acc}

          "assistant" ->
            {systems, [assistant_message(message) | messages_acc]}

          "tool" ->
            {systems, [tool_result_message(message) | messages_acc]}

          "user" ->
            {systems, [user_message(message) | messages_acc]}

          _ ->
            {systems, messages_acc}
        end
      end)

    system = system_content(Enum.reverse(system_parts))
    {system, merge_adjacent(Enum.reverse(conversation))}
  end

  def to_wire_messages(_), do: {nil, []}

  @doc false
  def tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn tool ->
      function = field(tool, "function", :function) || %{}
      name = field(function, "name", :name)
      description = field(function, "description", :description)
      parameters = field(function, "parameters", :parameters)

      if is_binary(name) and String.trim(name) != "" do
        tool = %{
          "name" => name,
          "input_schema" => if(is_map(parameters), do: stringify_keys(parameters), else: %{})
        }

        tool = if is_binary(description), do: Map.put(tool, "description", description), else: tool
        [tool]
      else
        []
      end
    end)
  end

  def tools(_), do: []

  @doc false
  def parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, error} -> {:error, {:bad_response, error}}
    end
  end

  def parse_response(%{"error" => error}) when not is_nil(error),
    do: {:error, {:api_error, error}}

  def parse_response(%{"content" => content} = body) do
    blocks = if is_list(content), do: content, else: content_blocks(content)
    text = text_from_blocks(blocks)
    reasoning = reasoning_from_blocks(blocks)
    tool_calls = tool_calls_from_blocks(blocks)

    message =
      %{"role" => "assistant", "content" => text}
      |> maybe_put("reasoning", reasoning)
      |> maybe_put("tool_calls", tool_calls)

    {:ok, message, normalize_usage(field(body, "usage", :usage) || %{})}
  end

  def parse_response(body), do: {:error, {:bad_response, body}}

  defp request_body(client, messages, tools, opts, stream?) do
    {system, wire_messages} = to_wire_messages(messages)
    wire_tools = tools(tools)
    extra = stringify_keys(Keyword.get(opts, :extra, %{}))
    max_tokens = output_limit(opts, extra)

    %{
      "model" => client.model,
      "messages" => wire_messages,
      "max_tokens" => max_tokens,
      "stream" => stream?
    }
    |> maybe_put("system", system)
    |> maybe_put("temperature", Keyword.get(opts, :temperature))
    |> maybe_put_tools(wire_tools)
    |> Map.merge(extra)
    |> Map.put("model", client.model)
    |> Map.put("messages", wire_messages)
    |> Map.put("max_tokens", max_tokens)
    |> Map.put("stream", stream?)
  end

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, tools), do: Map.put(body, "tools", tools)

  defp output_limit(opts, extra) do
    candidate = Keyword.get(opts, :max_tokens) || field(extra, "max_tokens", :max_tokens)

    case positive_integer(candidate) do
      nil -> @default_max_tokens
      value -> value
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp positive_integer(_), do: nil

  defp perform(client, body, on_text, on_reasoning) do
    _dbg_id =
      Newbee.LLM.HttpDebug.start_exchange(%{
        session_id: Newbee.LLM.HttpDebug.session_id_from_cache_key(client.cache_key),
        model: client.model,
        base_url: client.base_url,
        endpoint: "/messages",
        method: "POST",
        url: endpoint(client),
        api: "anthropic-messages",
        req_headers: request_headers(client),
        req_body: body
      })

    result =
      if body["stream"] do
        perform_stream(client, body, on_text, on_reasoning)
      else
        perform_json(client, body)
      end

    result =
      case {body["stream"], result} do
        {false, {:ok, response_body}} ->
          parse_response(response_body)

        {_stream, other} ->
          other
      end

    Newbee.LLM.HttpDebug.finish_current(result)
    result
  end

  defp perform_json(client, body) do
    req = build_req(client, body, false)

    case request_json(req, @overload_retries) do
      {:ok, %{status: 200, body: response_body} = response} ->
        Newbee.LLM.HttpDebug.note_current_response(response.status, response.headers)
        {:ok, response_body}

      {:ok, %{status: status, body: response_body} = response} ->
        Newbee.LLM.HttpDebug.note_current_response(response.status, response.headers)
        {:error, {:http_error, status, response_body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp request_json(req, left) do
    case Req.request(req) do
      {:ok, %{status: status}} when status in @overload_statuses and left > 0 ->
        Process.sleep(@overload_delay)
        request_json(req, left - 1)

      other ->
        other
    end
  end

  defp perform_stream(client, body, on_text, on_reasoning) do
    req = build_req(client, body, true)
    request_stream(req, client, on_text, on_reasoning, @overload_retries)
  end

  defp build_req(client, body, stream?) do
    options =
      [
        url: endpoint(client),
        method: :post,
        headers: request_headers(client),
        json: body,
        receive_timeout: @response_timeout,
        retry: false
      ]
      |> Keyword.merge(client.req_options)

    options = if stream?, do: Keyword.put(options, :into, :self), else: options
    Req.new(options)
  end

  defp request_stream(req, client, on_text, on_reasoning, left) do
    case Req.request(req) do
      {:ok, %{status: status} = response} when status in @overload_statuses and left > 0 ->
        _ = drain_async(response, client)

        if Newbee.LLM.Client.interrupted?(client) do
          {:interrupted, ""}
        else
          Process.sleep(@overload_delay)
          request_stream(req, client, on_text, on_reasoning, left - 1)
        end

      {:ok, %{status: 200} = response} ->
        Newbee.LLM.HttpDebug.note_current_response(response.status, response.headers)

        if event_stream?(response) do
          consume_sse(response, client, on_text, on_reasoning)
        else
          case drain_async(response, client) do
            {:ok, bytes} -> decode_stream_or_json(bytes, on_text, on_reasoning)
            {:interrupted, content} -> {:interrupted, content}
            {:error, error} -> {:error, error}
          end
        end

      {:ok, response} ->
        Newbee.LLM.HttpDebug.note_current_response(response.status, response.headers)

        case response.body do
          body when is_binary(body) and body != "" ->
            {:error, {:http_error, response.status, body}}

          _ ->
            case drain_async(response, client) do
              {:ok, body} -> {:error, {:http_error, response.status, body}}
              {:interrupted, content} -> {:interrupted, content}
              {:error, error} -> {:error, error}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode_stream_or_json(bytes, on_text, on_reasoning) do
    if String.starts_with?(String.trim_leading(bytes), "data:") or
         String.starts_with?(String.trim_leading(bytes), "event:") do
      consume_sse_payload(bytes, on_text, on_reasoning)
    else
      case parse_response(bytes) do
        {:ok, message, _usage} = result ->
          emit_message(message, on_text, on_reasoning)
          result

        error ->
          error
      end
    end
  end

  defp event_stream?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "text/event-stream"))
  end

  defp consume_sse(response, client, on_text, on_reasoning) do
    acc = sse_acc()
    started_at = System.monotonic_time(:millisecond)

    case sse_loop(response, client, on_text, on_reasoning, acc, "", started_at) do
      {:done, acc, rest} -> finish_sse(apply_sse_buffer(acc, rest, on_text, on_reasoning))
      {:interrupted, acc} -> {:interrupted, acc.content}
      {:error, error} -> {:error, error}
    end
  end

  defp consume_sse_payload(bytes, on_text, on_reasoning) do
    acc = apply_sse_buffer(sse_acc(), bytes, on_text, on_reasoning)
    finish_sse(acc)
  end

  defp sse_loop(response, client, on_text, on_reasoning, acc, buffer, started_at) do
    receive do
      message ->
        if Newbee.LLM.Client.interrupted?(client) do
          Req.cancel_async_response(response)
          {:interrupted, acc}
        else
          case Req.parse_message(response, message) do
            {:ok, [data: data]} ->
              raw = IO.iodata_to_binary(data)
              Newbee.LLM.HttpDebug.append_raw(raw)
              {events, rest} = split_sse(buffer <> raw)
              acc = Enum.reduce(events, acc, &apply_sse_event(&1, &2, on_text, on_reasoning))
              sse_loop(response, client, on_text, on_reasoning, acc, rest, started_at)

            {:ok, [:done]} ->
              {:done, acc, buffer}

            {:ok, [trailers: _]} ->
              sse_loop(response, client, on_text, on_reasoning, acc, buffer, started_at)

            {:error, error} ->
              {:error, error}

            :unknown ->
              sse_loop(response, client, on_text, on_reasoning, acc, buffer, started_at)
          end
        end
    after
      100 ->
        cond do
          Newbee.LLM.Client.interrupted?(client) ->
            Req.cancel_async_response(response)
            {:interrupted, acc}

          System.monotonic_time(:millisecond) - started_at > @stream_timeout ->
            Req.cancel_async_response(response)
            {:error, {:anthropic_stream_error, "stream timeout"}}

          true ->
            sse_loop(response, client, on_text, on_reasoning, acc, buffer, started_at)
        end
    end
  end

  defp drain_async(response, client, chunks \\ []) do
    receive do
      message ->
        if Newbee.LLM.Client.interrupted?(client) do
          Req.cancel_async_response(response)
          {:interrupted, ""}
        else
          case Req.parse_message(response, message) do
            {:ok, [data: data]} ->
              drain_async(response, client, [IO.iodata_to_binary(data) | chunks])

            {:ok, [:done]} ->
              {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

            {:ok, [trailers: _]} ->
              drain_async(response, client, chunks)

            {:error, error} ->
              {:error, error}

            :unknown ->
              drain_async(response, client, chunks)
          end
        end
    after
      @response_timeout ->
        Req.cancel_async_response(response)
        {:error, {:anthropic_stream_error, "response body timeout"}}
    end
  end

  defp sse_acc do
    %{content: "", reasoning: "", tool_calls: %{}, usage: %{}, response_id: nil, error: nil}
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

  defp apply_sse_event(data, acc, on_text, on_reasoning) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, event} -> apply_anthropic_event(event, acc, on_text, on_reasoning)
      {:error, _} -> acc
    end
  end

  defp apply_anthropic_event(%{"type" => "message_start", "message" => message}, acc, _, _)
       when is_map(message) do
    %{
      acc
      | response_id: field(message, "id", :id) || acc.response_id,
        usage: Map.merge(acc.usage, field(message, "usage", :usage) || %{})
    }
  end

  defp apply_anthropic_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         acc,
         on_text,
         _on_reasoning
       )
       when is_map(block) do
    case field(block, "type", :type) do
      "tool_use" ->
        slot = %{
          id: field(block, "id", :id),
          name: field(block, "name", :name),
          arguments: ""
        }

        %{acc | tool_calls: Map.put(acc.tool_calls, index, slot)}

      "text" ->
        text = field(block, "text", :text) || ""

        if text == "" do
          acc
        else
          on_text.(text)
          %{acc | content: acc.content <> text}
        end

      "thinking" ->
        thinking = field(block, "thinking", :thinking) || ""

        if thinking == "" do
          acc
        else
          %{acc | reasoning: acc.reasoning <> thinking}
        end

      _ ->
        acc
    end
  end

  defp apply_anthropic_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         acc,
         on_text,
         on_reasoning
       )
       when is_map(delta) do
    case field(delta, "type", :type) do
      "text_delta" ->
        text = field(delta, "text", :text) || ""
        on_text.(text)
        %{acc | content: acc.content <> text}

      "thinking_delta" ->
        thinking = field(delta, "thinking", :thinking) || ""
        on_reasoning.(thinking)
        %{acc | reasoning: acc.reasoning <> thinking}

      "input_json_delta" ->
        partial = field(delta, "partial_json", :partial_json) || ""
        slot = Map.get(acc.tool_calls, index, %{id: nil, name: nil, arguments: ""})
        slot = %{slot | arguments: slot.arguments <> partial}
        %{acc | tool_calls: Map.put(acc.tool_calls, index, slot)}

      _ ->
        acc
    end
  end

  defp apply_anthropic_event(%{"type" => "message_delta", "usage" => usage}, acc, _, _)
       when is_map(usage) do
    %{acc | usage: Map.merge(acc.usage, usage)}
  end

  defp apply_anthropic_event(%{"type" => "error"} = event, acc, _, _) do
    %{acc | error: field(event, "error", :error) || event}
  end

  defp apply_anthropic_event(_event, acc, _on_text, _on_reasoning), do: acc

  defp finish_sse(%{error: error} = acc) when not is_nil(error),
    do: {:error, {:response_error, error, acc.content}}

  defp finish_sse(acc) do
    message =
      %{"role" => "assistant", "content" => acc.content}
      |> maybe_put("reasoning", acc.reasoning)
      |> maybe_put("tool_calls", assemble_tool_calls(acc.tool_calls))

    {:ok, message, normalize_usage(acc.usage)}
  end

  defp assemble_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {index, _slot} -> index end)
    |> Enum.flat_map(fn {_index, slot} ->
      if is_binary(slot.name) and String.trim(slot.name) != "" do
        arguments = if slot.arguments == "", do: "{}", else: slot.arguments

        [
          %{
            "id" => slot.id,
            "type" => "function",
            "function" => %{"name" => slot.name, "arguments" => arguments}
          }
        ]
      else
        []
      end
    end)
  end

  defp emit_message(message, on_text, on_reasoning) do
    if message["content"] not in [nil, ""], do: on_text.(message["content"])
    if message["reasoning"] not in [nil, ""], do: on_reasoning.(message["reasoning"])
  end

  defp normalize_usage(usage) when is_map(usage) do
    input = positive_or_zero(field(usage, "input_tokens", :input_tokens))
    output = positive_or_zero(field(usage, "output_tokens", :output_tokens))
    cache_read = positive_or_zero(field(usage, "cache_read_input_tokens", :cache_read_input_tokens))
    cache_write = positive_or_zero(field(usage, "cache_creation_input_tokens", :cache_creation_input_tokens))

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output,
      "cache_read_tokens" => cache_read,
      "cache_write_tokens" => cache_write,
      "uncached_prompt_tokens" => max(input - cache_read, 0)
    }
  end

  defp normalize_usage(_), do: normalize_usage(%{})

  defp positive_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp positive_or_zero(value) when is_float(value) and value >= 0, do: trunc(value)
  defp positive_or_zero(_), do: 0

  defp text_from_blocks(blocks) do
    blocks
    |> Enum.filter(&(field(&1, "type", :type) == "text"))
    |> Enum.map_join(fn block -> field(block, "text", :text) || "" end)
  end

  defp reasoning_from_blocks(blocks) do
    blocks
    |> Enum.filter(&(field(&1, "type", :type) in ["thinking", "redacted_thinking"]))
    |> Enum.map_join(fn block -> field(block, "thinking", :thinking) || "" end)
  end

  defp tool_calls_from_blocks(blocks) do
    blocks
    |> Enum.filter(&(field(&1, "type", :type) == "tool_use"))
    |> Enum.flat_map(fn block ->
      name = field(block, "name", :name)

      if is_binary(name) and String.trim(name) != "" do
        input = field(block, "input", :input) || %{}

        [
          %{
            "id" => field(block, "id", :id),
            "type" => "function",
            "function" => %{"name" => name, "arguments" => Jason.encode!(stringify_keys(input))}
          }
        ]
      else
        []
      end
    end)
  end

  defp assistant_message(message) do
    content = content_blocks(field(message, "content", :content))
    calls = field(message, "tool_calls", :tool_calls) || []

    tool_blocks =
      Enum.flat_map(calls, fn call ->
        function = field(call, "function", :function) || %{}
        name = field(function, "name", :name)
        id = field(call, "id", :id)
        arguments = field(function, "arguments", :arguments)

        if is_binary(name) and String.trim(name) != "" do
          [%{"type" => "tool_use", "id" => id, "name" => name, "input" => tool_input(arguments)}]
        else
          []
        end
      end)

    %{"role" => "assistant", "content" => empty_as_string(content ++ tool_blocks)}
  end

  defp user_message(message) do
    %{"role" => "user", "content" => empty_as_string(content_blocks(field(message, "content", :content)))}
  end

  defp tool_result_message(message) do
    id = field(message, "tool_call_id", :tool_call_id) || ""
    content = tool_result_content(field(message, "content", :content))

    %{
      "role" => "user",
      "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => content}]
    }
  end

  defp tool_result_content(content) do
    case content_blocks(content) do
      [] -> ""
      [%{"type" => "text", "text" => text}] -> text
      blocks -> blocks
    end
  end

  defp tool_input(value) when is_map(value), do: stringify_keys(value)

  defp tool_input(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      _ -> %{"raw_arguments" => value}
    end
  end

  defp tool_input(_), do: %{}

  defp content_blocks(nil), do: []

  defp content_blocks(content) when is_binary(content) do
    if content == "", do: [], else: [%{"type" => "text", "text" => content}]
  end

  defp content_blocks(content) when is_list(content), do: Enum.flat_map(content, &content_block/1)
  defp content_blocks(content), do: content_block(content)

  defp content_block(content) when is_binary(content), do: content_blocks(content)
  defp content_block(nil), do: []

  defp content_block(%{} = part) do
    type = field(part, "type", :type)

    case type do
      "text" -> [%{"type" => "text", "text" => field(part, "text", :text) || ""}]
      "input_text" -> [%{"type" => "text", "text" => field(part, "text", :text) || ""}]
      "image_url" -> [image_block(field(part, "image_url", :image_url))]
      "input_image" -> [image_block(field(part, "image_url", :image_url))]
      _ -> [stringify_keys(part)]
    end
  end

  defp content_block(_), do: []

  defp image_block(image) when is_map(image), do: image_block(field(image, "url", :url))
  defp image_block(url) when is_binary(url), do: %{"type" => "image", "source" => image_source(url)}
  defp image_block(_), do: %{"type" => "image", "source" => %{"type" => "url", "url" => ""}}

  defp image_source("data:" <> encoded) do
    case String.split(encoded, ",", parts: 2) do
      [meta, data] ->
        media_type = meta |> String.split(";") |> hd() |> String.trim_leading("data:")
        %{"type" => "base64", "media_type" => media_type, "data" => data}

      _ ->
        %{"type" => "url", "url" => "data:" <> encoded}
    end
  end

  defp image_source(url), do: %{"type" => "url", "url" => url}

  defp system_content(contents) do
    blocks = Enum.flat_map(contents, &content_blocks/1)

    case blocks do
      [] ->
        nil

      blocks ->
        if Enum.all?(blocks, &(field(&1, "type", :type) == "text")) do
          Enum.map_join(blocks, "\n\n", &(field(&1, "text", :text) || ""))
        else
          blocks
        end
    end
  end

  defp merge_adjacent(messages) do
    messages
    |> Enum.reduce([], fn message, acc ->
      case acc do
        [%{"role" => role, "content" => previous} = prior | rest] ->
          if role == message["role"] do
            [Map.put(prior, "content", append_content(previous, message["content"])) | rest]
          else
            [message | acc]
          end

        _ ->
          [message | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp append_content(previous, current) do
    previous_blocks = if is_list(previous), do: previous, else: content_blocks(previous)
    current_blocks = if is_list(current), do: current, else: content_blocks(current)
    empty_as_string(previous_blocks ++ current_blocks)
  end

  defp empty_as_string([]), do: ""
  defp empty_as_string(content), do: content

  defp field(map, string_key, atom_key) when is_map(map),
    do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp field(_, _string_key, _atom_key), do: nil

  defp normalize_role(role) when is_atom(role), do: Atom.to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_), do: nil

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp endpoint(client), do: String.trim_trailing(client.base_url, "/") <> "/messages"

  defp request_headers(client) do
    Newbee.LLM.Client.request_headers(client) ++
      [
        {"x-api-key", to_string(client.api_key)},
        {"anthropic-version", @anthropic_version}
      ]
  end
end
