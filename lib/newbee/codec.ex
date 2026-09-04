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

  @doc "从 LLM 响应 message 中提取 tool_calls，统一为 %{id, name, args} 列表。"
  def extract_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn c ->
      args =
        case c["function"]["arguments"] do
          s when is_binary(s) ->
            case Jason.decode(s) do
              {:ok, m} -> m
              _ -> %{"code" => s}
            end

          m when is_map(m) ->
            m
        end

      %{id: c["id"], name: c["function"]["name"], args: args}
    end)
  end

  def extract_tool_calls(_), do: []
end
