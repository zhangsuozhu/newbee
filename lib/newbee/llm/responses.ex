defmodule Newbee.LLM.Responses do
  @moduledoc false

  alias Newbee.LLM.ResponsesContinuation, as: Continuation

  @overload_statuses [429, 500, 502, 503, 529]
  @overload_retries 5
  @overload_delay 1_000

  def request(client, messages, tools, opts \\ []) do
    logical_input = input(messages)
    wire_tools = tools(tools)

    full_body =
      %{
        model: client.model,
        input: logical_input,
        stream: false,
        tools: wire_tools
      }
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:reasoning, reasoning(client.reasoning_effort))
      |> maybe_put(:prompt_cache_key, client.cache_key)
      |> maybe_put(:store, if(client.responses_continuation, do: true))
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    envelope = Map.delete(full_body, :input)

    plan =
      if client.responses_continuation do
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

    case perform(client, request_body) do
      {:ok, body} ->
        finish(client, envelope, logical_input, body)

      {:error, {:http_error, status, body}} when continued? ->
        if previous_response_not_found?(body) do
          Newbee.DebugLog.log(:llm, "responses continuation expired; retrying full request")
          Continuation.clear(client.responses_checkpoint)

          case perform(client, full_body) do
            {:ok, retry_body} ->
              finish(client, envelope, logical_input, retry_body)

            {:error, {:http_error, retry_status, retry_body}} ->
              {:error, {:http_error, retry_status, encoded(retry_body)}}

            error ->
              error
          end
        else
          {:error, {:http_error, status, encoded(body)}}
        end

      {:error, {:http_error, status, body}} ->
        {:error, {:http_error, status, encoded(body)}}

      error ->
        error
    end
  end

  def input(messages) do
    Enum.flat_map(messages, fn
      %{"role" => "assistant", "tool_calls" => calls} = message when is_list(calls) ->
        text =
          if message["content"] in [nil, ""],
            do: [],
            else: [%{"role" => "assistant", "content" => message["content"]}]

        calls =
          Enum.map(calls, fn call ->
            function = call["function"] || %{}

            %{
              "type" => "function_call",
              "call_id" => call["id"],
              "name" => function["name"],
              "arguments" => function["arguments"] || "{}"
            }
          end)

        text ++ calls

      %{"role" => "tool", "tool_call_id" => id, "content" => content} ->
        [%{"type" => "function_call_output", "call_id" => id, "output" => to_string(content)}]

      %{"role" => role} = message when role in ["user", "system", "assistant"] ->
        [message]

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

  defp finish(client, envelope, logical_input, body) do
    case parse_with_id(body) do
      {:ok, message, usage, response_id} ->
        next_prefix = logical_input ++ input([message])

        if client.responses_continuation and is_binary(response_id) and response_id != "" do
          Continuation.commit(client.responses_checkpoint, envelope, next_prefix, response_id)
        else
          Continuation.clear(client.responses_checkpoint)
        end

        {:ok, message, usage}

      error ->
        error
    end
  end

  defp parse_with_id(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_with_id(decoded)
      {:error, error} -> {:error, {:bad_response, error}}
    end
  end

  defp parse_with_id(%{"error" => error}) when not is_nil(error), do: {:error, {:api_error, error}}

  defp parse_with_id(%{"output" => output} = body) when is_list(output) do
    content =
      for %{"type" => "message", "content" => parts} <- output,
          %{"type" => "output_text", "text" => text} <- parts,
          into: "",
          do: text

    tool_calls =
      for %{"type" => "function_call"} = call <- output do
        %{
          "id" => call["call_id"] || call["id"],
          "type" => "function",
          "function" => %{"name" => call["name"], "arguments" => call["arguments"] || "{}"}
        }
      end

    message =
      %{"role" => "assistant", "content" => content}
      |> maybe_put("tool_calls", tool_calls)

    {:ok, message, usage(body["usage"] || %{}), body["id"]}
  end

  defp parse_with_id(body), do: {:error, {:bad_response, body}}

  defp perform(client, body) do
    req =
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
      |> Req.new()

    case request_with_retry(req, @overload_retries) do
      {:ok, %{status: 200, body: response_body}} -> {:ok, response_body}
      {:ok, %{status: status, body: response_body}} -> {:error, {:http_error, status, response_body}}
      {:error, error} -> {:error, error}
    end
  end

  defp previous_response_not_found?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> previous_response_not_found?(decoded)
      _ -> false
    end
  end

  defp previous_response_not_found?(%{"error" => error}) when is_map(error) do
    error["code"] == "previous_response_not_found" or
      error["type"] == "previous_response_not_found"
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

  defp request_with_retry(req, 0), do: Req.request(req)

  defp request_with_retry(req, left) do
    case Req.request(req) do
      {:ok, %{status: status}} when status in @overload_statuses ->
        Process.sleep(@overload_delay)
        request_with_retry(req, left - 1)

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
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encoded(body) when is_binary(body), do: body
  defp encoded(body), do: Jason.encode!(body)
end
