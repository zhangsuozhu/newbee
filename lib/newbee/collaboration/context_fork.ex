defmodule Newbee.Collaboration.ContextFork do
  @moduledoc """
  把父会话中已完成的安全对话轮次复制给新子会话。

  不复制 system、tool、tool_calls、运行时绑定或未完成轮次。这样继承的是问题背景与
  最终结论，而不是父代理的工具协议状态。为控制上下文成本，最多复制 64 个完整轮次、
  128 KiB 文本；超限显式失败，不静默截断。
  """

  @max_turns 64
  @max_bytes 128 * 1_024

  @doc "按 `:none | :all | positive_integer` 为尚未启动的子会话播种上下文。"
  def seed(_parent_id, _child_id, mode) when mode in [:none, "none", nil],
    do: {:ok, %{turns: 0, messages: 0}}

  def seed(parent_id, child_id, mode) when is_binary(parent_id) and is_binary(child_id) do
    with {:ok, selector} <- normalize_mode(mode),
         :ok <- ensure_empty_child(child_id) do
      turns =
        parent_id
        |> Newbee.Session.open()
        |> Newbee.Session.messages()
        |> completed_turns()
        |> select_turns(selector)

      with :ok <- within_budget(turns) do
        messages = List.flatten(turns)
        child = Newbee.Session.open(child_id)
        Enum.each(messages, &Newbee.Session.append(child, &1))
        {:ok, %{turns: length(turns), messages: length(messages)}}
      end
    end
  end

  def seed(_, _, _), do: {:error, "bad_fork", "父/子 session id 必须是字符串"}

  @doc "把 transcript 投影为完整的 user→assistant 轮次，排除工具协议和私有字段。"
  def completed_turns(messages) when is_list(messages) do
    {reversed, current} =
      Enum.reduce(messages, {[], nil}, fn message, {turns, open_user} ->
        case safe_message(message) do
          {:user, safe} ->
            {turns, safe}

          {:assistant, safe} when not is_nil(open_user) ->
            {[[open_user, safe] | turns], nil}

          _ ->
            {turns, open_user}
        end
      end)

    _incomplete_tail = current
    Enum.reverse(reversed)
  end

  defp safe_message(%{"role" => "user", "content" => content}) when is_binary(content) do
    if String.trim(content) == "", do: :skip, else: {:user, %{"role" => "user", "content" => content}}
  end

  defp safe_message(%{"role" => "assistant", "content" => content} = message)
       when is_binary(content) do
    if String.trim(content) == "" or Map.get(message, "tool_calls", []) != [],
      do: :skip,
      else: {:assistant, %{"role" => "assistant", "content" => content}}
  end

  defp safe_message(_), do: :skip

  defp within_budget(turns) do
    messages = List.flatten(turns)
    bytes = Enum.reduce(messages, 0, &(byte_size(&1["content"]) + &2))

    cond do
      length(turns) > @max_turns ->
        {:error, "fork_context_too_large", "fork 上下文超过 #{@max_turns} 个完整轮次"}

      bytes > @max_bytes ->
        {:error, "fork_context_too_large", "fork 上下文超过 #{@max_bytes} 字节"}

      true ->
        :ok
    end
  end

  defp normalize_mode(mode) when mode in [:all, "all"], do: {:ok, :all}
  defp normalize_mode(mode) when is_integer(mode) and mode > 0, do: {:ok, mode}

  defp normalize_mode(mode) when is_binary(mode) do
    case Integer.parse(mode) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "bad_fork", "fork_turns 只支持 none/all/正整数"}
    end
  end

  defp normalize_mode(_), do: {:error, "bad_fork", "fork_turns 只支持 none/all/正整数"}

  defp select_turns(turns, :all), do: turns
  defp select_turns(turns, n), do: Enum.take(turns, -n)

  defp ensure_empty_child(child_id) do
    child = Newbee.Session.open(child_id)

    if Newbee.Session.messages(child) == [],
      do: :ok,
      else: {:error, "fork_target_not_empty", "子会话已有历史，拒绝覆盖"}
  end
end
