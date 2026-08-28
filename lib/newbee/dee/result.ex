defmodule Newbee.DEE.Result do
  @moduledoc """
  结果压缩 (DESIGN §4.3)：回填给模型的输出默认做头尾截断，
  长输出引导模型用 binding 或文件引用，而非全文塞回上下文。
  """

  @max_chars 8_000
  @head_ratio 0.6

  @doc "压缩文本为 head+tail 形式，附行数统计。"
  def compress(text, opts \\ []) when is_binary(text) do
    max = Keyword.get(opts, :max_chars, @max_chars)

    if byte_size(text) <= max do
      text
    else
      head = floor(max * @head_ratio)
      tail = max - head
      total_lines = text |> String.split("\n") |> length()

      binary_part(text, 0, head) <>
        "\n… [compressed: #{byte_size(text)} bytes, #{total_lines} lines; " <>
        "用 binding 变量或写文件后再局部读取] …\n" <>
        binary_part(text, byte_size(text) - tail, tail)
    end
  end

  @doc "把求值结果 map 渲染成回填给模型的字符串。"
  def render(%{status: :ok, value: value, output: output}) do
    body = sanitize(output <> "\n" <> value) |> compress() |> sanitize()
    "✓ ok\n" <> body
  end

  def render(%{status: :error, error: error, output: output}) do
    hint = repair_hint(error)
    body = sanitize(output <> "\n" <> error <> hint) |> compress() |> sanitize()
    "✗ error\n" <> body
  end

  @doc "根据常见 Elixir 错误附加可直接尝试的修复示例。"
  def repair_hint(error) when is_binary(error) do
    cond do
      String.contains?(error, "String.Chars not implemented for Tuple") ->
        """

        💡 修复建议：这是一个返回值 tuple 被当成字符串使用的问题。先匹配 `{:ok, value}`，再传给 `IO.puts/1`；错误分支也要处理。例如：
        case Newbee.read("path.md") do
          {:ok, content} -> IO.puts(content)
          {:error, reason} -> IO.puts("读取失败: \#{inspect(reason)}")
        end
        """

      String.contains?(error, "KeyError") ->
        """

        💡 修复建议：不要直接用 `map.key` 读取可能不存在的键。可改用 `Map.get(map, :key, default)`，或先用 `Map.fetch/2` 匹配 `{:ok, value} | :error`。
        """

      String.contains?(error, "no function clause matching") ->
        """

        💡 修复建议：函数收到的参数类型/数量没有匹配任何子句。先用 `IO.inspect(value, label: "value")` 检查实际值，并为预期类型增加匹配或兜底子句。
        """

      String.contains?(error, "MatchError") and String.contains?(error, "%{") ->
        """

        💡 修复建议：返回值是 map 而非 tuple。工具函数如 `Run.sh/1`、`Run.sh/2` 返回 `%{exit:, output:}`，用 `result = Run.sh(cmd)` 再取 `result.output` / `result.exit`，不要用 `{out, code} = ...` 解构。
        """

      String.contains?(error, "MatchError") ->
        """

        💡 修复建议：模式匹配失败。先用 `IO.inspect(value, label: "debug")` 查看实际值结构，再写匹配模式。常见原因：函数返回值结构和预期不一致。
        """

      String.contains?(error, "UndefinedFunctionError") ->
        """

        💡 修复建议：函数不存在或不可见。检查：1) 模块名/函数名拼写；2) 函数是 public（def）还是 private（defp）；3) 用 `Newbee.Tools.Introspect.exports(Module)` 查看可用函数列表。
        """

      String.contains?(error, "timeout") ->
        """

        💡 修复建议：操作超时。可尝试：1) 拆分大操作为小步骤；2) 增加 timeout 参数；3) 如果是 shell 命令，检查是否有交互式输入阻塞。
        """

      String.contains?(error, "Kernel.to_string/1") and
          (String.contains?(error, "CompileError") or String.contains?(error, "undefined variable")) ->
        """

        💡 修复建议：这是生成 Elixir 源码时的二阶插值错误。目标源码中的插值在当前 cell 提前执行了。请先调用 `Newbee.Tools.Edit.source_literal(source)` 生成安全字符串表达式，再拼入写文件代码。
        """

      String.contains?(error, "MismatchedDelimiterError") and
          (String.contains?(error, "heredoc") or String.contains?(error, "terminator")) ->
        """

        💡 修复建议：这是 heredoc 或 sigil 分隔符嵌套冲突。不要继续手工更换分隔符；请调用 `Newbee.Tools.Edit.source_literal(source)` 生成不会与目标内容冲突的字符串表达式。
        """

      String.contains?(error, "SyntaxError") or String.contains?(error, "CompileError") ->
        """

        💡 修复建议：先定位错误报告中的行号和列号，检查括号、逗号、`do/end` 及字符串边界；生成源码时先用 `Newbee.Tools.Edit.source_literal/1` 避免二阶插值和分隔符嵌套。可用 `Code.format_string!(code)` 验证代码结构。
        """

      true ->
        ""
    end
  end

  def repair_hint(_), do: ""

  @doc """
  清洗非法 UTF-8：工具输出可能是任意字节（读二进制文件等），
  直接回填会让 Session.append 的 Jason 编码崩溃（kernel 死亡）。
  非法字节替换为 U+FFFD，且每次至少消费一个坏字节，保证终止。
  """
  def sanitize(s) when is_binary(s) do
    case :unicode.characters_to_binary(s, :utf8, :utf8) do
      bin when is_binary(bin) ->
        bin

      {:error, good, <<_invalid, rest::binary>>} ->
        good <> <<0xFFFD::utf8>> <> sanitize(rest)

      {:incomplete, good, _incomplete} ->
        good <> <<0xFFFD::utf8>>
    end
  end

  def sanitize(other), do: inspect(other)
end
