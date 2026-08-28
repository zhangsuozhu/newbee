defmodule Newbee.LLM.Responses do
  @moduledoc false

  @overload_statuses [429, 500, 502, 503, 529]
  @overload_retries 5
  @overload_delay 1_000

  def request(client, messages, tools, opts \\ []) do
    body =
      %{
        model: client.model,
        input: input(messages),
        stream: false,
        tools: tools(tools)
      }
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:reasoning, reasoning(client.reasoning_effort))
      |> Map.merge(Keyword.get(opts, :extra, %{}))

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
      {:ok, %{status: 200, body: body}} -> parse(body)
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, encoded(body)}}
      {:error, error} -> {:error, error}
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

      # media/usage/未知角色：非标准消息不进 API 请求，避免 400
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

  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, error} -> {:error, {:bad_response, error}}
    end
  end

  def parse(%{"error" => error}) when not is_nil(error), do: {:error, {:api_error, error}}

  def parse(%{"output" => output} = body) when is_list(output) do
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

    {:ok, message, usage(body["usage"] || %{})}
  end

  def parse(body), do: {:error, {:bad_response, body}}

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
