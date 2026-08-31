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
          "在持久 Elixir 环境执行代码；绑定跨调用保留，可调用 Newbee.Tools.*。" <>
            "大结果留在 binding 或文件。生成含插值/heredoc 的源码先用 Edit.source_literal/1。",
        parameters: %{
          type: "object",
          properties: %{
            code: %{type: "string", description: "要执行的 Elixir 代码"},
            title: %{type: "string", description: "简短操作标题"}
          },
          required: ["code"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "done",
        description: "完成总结；可附下一步",
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
        description: "需要用户决定或澄清时暂停。kind: text=文本、single=单选、multi=多选、buttons=按钮；选择项放 options。",
        parameters: %{
          type: "object",
          properties: %{
            question: %{type: "string", description: "向用户提出的问题"},
            kind: %{type: "string", enum: ["text", "single", "multi", "buttons"], description: "交互形态；默认 text"},
            options: %{type: "array", description: "选择项 [{label, value}]", items: %{type: "object", properties: %{label: %{type: "string"}, value: %{type: "string"}}}}
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
