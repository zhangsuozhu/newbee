defmodule Newbee.Codec do
  @moduledoc """
  模型↔环境协议 (DESIGN §4.2)：function calling 包裹自由代码。
  可见工具面封顶 3 个（§1.1 光头优先）：run_elixir / done / ask。
  """

  @tools [
    %{
      type: "function",
      function: %{
        name: "run_elixir",
        description:
          "Run code in the persistent Elixir environment; bindings survive across calls, Newbee.Tools.* callable." <>
            "Keep large results in bindings or files. For generated source with interpolation/heredocs, build it via Edit.source_literal/1 first.",
        parameters: %{
          type: "object",
          properties: %{
            code: %{type: "string", description: "Elixir code to run"},
            title: %{type: "string", description: "Short action title"}
          },
          required: ["code"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "done",
        description: "Completion summary; may attach next steps",
        parameters: %{
          type: "object",
          properties: %{
            summary: %{type: "string"},
            next_question: %{type: "string"},
            next_kind: %{type: "string", enum: ["single", "multi", "buttons"]},
            next_options: %{type: "array", items: %{type: "object", properties: %{label: %{type: "string"}, value: %{type: "string"}}}}
          },
          required: ["summary"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "ask",
        description: "Pause for a user decision or clarification. kind: text, single, multi, buttons; put choices in options.",
        parameters: %{
          type: "object",
          properties: %{
            question: %{type: "string", description: "Question for the user"},
            kind: %{type: "string", enum: ["text", "single", "multi", "buttons"], description: "Interaction shape; default text"},
            options: %{type: "array", description: "Choices [{label, value}]", items: %{type: "object", properties: %{label: %{type: "string"}, value: %{type: "string"}}}}
          },
          required: ["question"]
        }
      }
    }
  ]

  def tools, do: @tools

  @doc "从 LLM 响应提取 tool_calls，统一为 id name args 列表。无名碎片丢掉，避免 unknown tool 又写回 nil id。"
  def extract_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    calls
    |> Enum.map(&extract_single/1)
    |> Enum.reject(&is_nil/1)
  end

  def extract_tool_calls(_), do: []

  defp extract_single(c) when is_map(c) do
    fun = c["function"] || c[:function] || %{}
    fun = if is_map(fun), do: fun, else: %{}
    name = fun["name"] || fun[:name]
    if is_binary(name) and String.trim(name) != "" do
      raw_args = fun["arguments"] || fun[:arguments]
      args =
        cond do
          is_binary(raw_args) ->
            case Jason.decode(raw_args) do
              {:ok, m} when is_map(m) -> m
              _ -> %{"code" => raw_args}
            end
          is_map(raw_args) -> raw_args
          is_nil(raw_args) -> %{}
          true -> %{"code" => inspect(raw_args)}
        end
      %{id: c["id"] || c[:id], name: name, args: args}
    else
      nil
    end
  end
  defp extract_single(_), do: nil
end
