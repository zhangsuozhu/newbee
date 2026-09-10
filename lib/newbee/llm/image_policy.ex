defmodule Newbee.LLM.ImagePolicy do
  @moduledoc """
  请求图像策略：每次请求保留哪些图片，其余如何卸载。

  ## 为什么

  会话里的图片以内联 data URL 存进 transcript，随后随历史被永久重发：旧截图既烧 token，
  又把上下文撑坏。这里在**请求投影**阶段做确定性的"最老优先卸载"——在真正要发出去的那份
  消息里，超出预算的图片被替换成稳定的文本占位符。transcript 不动、UI 回放照旧，
  模型看到的是一个有界且确定的图片窗口。

  确定性是硬要求：同一份 messages 加同一份策略，必须产出逐字节相同的结果；否则
  `Newbee.RequestEnvelope` 记下的"可缓存前缀"就不再是真实前缀，摘要回放的命中就是假的。

  ## 预算（默认值；可由模型能力覆盖，见 `Newbee.LLM.Capabilities`）

  | 字段 | 默认 | 含义 |
  |---|---|---|
  | `vision` | `true` | 为 false 时把所有图片卸载为文本占位符 |
  | `max_images` | 24 | 单次请求保留的图片张数上限 |
  | `max_request_bytes` | 24 MiB | 单次请求保留图片的总字节上限 |
  | `image_max_bytes` | 8 MiB | 单张图片的字节上限；超出即卸载 |

  ## 可跑示例

      policy = Newbee.LLM.ImagePolicy.for_client(client)
      {messages, dropped} = Newbee.LLM.ImagePolicy.project(messages, policy)
      {messages, 0} = Newbee.LLM.ImagePolicy.project_for(client, messages)
      Newbee.LLM.ImagePolicy.placeholder("data:image/png;base64,AAAA")
  """

  alias Newbee.LLM.Capabilities

  @default_max_images 24
  @default_max_request_bytes 24 * 1024 * 1024
  @default_image_max_bytes 8 * 1024 * 1024
  @id_head_bytes 4096

  defstruct vision: true,
            max_images: @default_max_images,
            max_request_bytes: @default_max_request_bytes,
            image_max_bytes: @default_image_max_bytes

  @type t :: %__MODULE__{
          vision: boolean(),
          max_images: pos_integer(),
          max_request_bytes: pos_integer(),
          image_max_bytes: pos_integer()
        }

  @doc "默认单张图片字节上限；与提交入口 `Newbee.LLM.Image` 的限制保持一致。"
  @spec default_image_max_bytes() :: pos_integer()
  def default_image_max_bytes, do: @default_image_max_bytes

  @doc "从 client 的能力解析请求图像策略；非 client 形状回退默认策略。"
  @spec for_client(term()) :: t()
  def for_client(%__MODULE__{} = policy), do: policy

  def for_client(client) when is_map(client) do
    caps = Capabilities.normalize(Map.get(client, :capabilities))

    %__MODULE__{
      vision: vision(caps, client),
      max_images: Map.get(caps, :max_images_per_request, @default_max_images),
      max_request_bytes: Map.get(caps, :max_request_image_bytes, @default_max_request_bytes),
      image_max_bytes: Map.get(caps, :image_max_bytes, @default_image_max_bytes)
    }
  end

  def for_client(_), do: %__MODULE__{}

  @doc """
  请求投影：按"最老优先"把超出预算的图片换成文本占位符，返回 `{messages, dropped}`。

  未发生卸载时原样返回入参（同一份列表，不做无谓拷贝）。
  """
  @spec project(list(), t()) :: {list(), non_neg_integer()}
  def project(messages, %__MODULE__{} = policy) when is_list(messages) do
    entries = entries(messages)
    keep = keep_set(entries, policy)
    dropped = length(entries) - MapSet.size(keep)

    if dropped == 0, do: {messages, 0}, else: {rewrite(messages, keep), dropped}
  end

  def project(messages, _policy), do: {messages, 0}

  @doc "投影便利入口：策略取自 client 的能力。"
  @spec project_for(term(), list()) :: {list(), non_neg_integer()}
  def project_for(client, messages), do: project(messages, for_client(client))

  @doc "被卸载图片的模型可见占位文本；对同一份 data URL 恒定。"
  @spec placeholder(binary()) :: binary()
  def placeholder(url) when is_binary(url) do
    "[image omitted: id=" <>
      image_id(url) <>
      " mime=" <> media_type(url) <> " bytes=" <> Integer.to_string(data_url_bytes(url)) <> "]"
  end

  # ── 决策 ──

  # 文档序收集所有图片部件：{序号, 消息下标, 部件下标, data URL}。
  # 序号是"第几张图"，投影改写时按同一规则重新编号，两边必须一致。
  defp entries(messages) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, message_index} ->
      message
      |> content_parts()
      |> Enum.with_index()
      |> Enum.flat_map(fn {part, part_index} ->
        case image_url(part) do
          nil -> []
          url -> [{message_index, part_index, url}]
        end
      end)
    end)
    |> Enum.with_index()
    |> Enum.map(fn {{message_index, part_index, url}, ord} -> {ord, message_index, part_index, url} end)
  end

  # 从最新往旧保留；第一个放不下的就停下——保住的永远是"最新的连续一段"。
  defp keep_set(entries, policy) do
    if policy.vision do
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({MapSet.new(), 0, 0}, fn {ord, _mi, _pi, url}, {keep, count, bytes} = acc ->
        size = data_url_bytes(url)

        if keepable?(size, count, bytes, policy) do
          {:cont, {MapSet.put(keep, ord), count + 1, bytes + size}}
        else
          {:halt, acc}
        end
      end)
      |> elem(0)
    else
      MapSet.new()
    end
  end

  defp keepable?(size, count, bytes, policy) do
    count < policy.max_images and
      size <= policy.image_max_bytes and
      bytes + size <= policy.max_request_bytes
  end

  # ── 改写 ──

  defp rewrite(messages, keep) do
    {rewritten, _ord} =
      Enum.reduce(messages, {[], 0}, fn message, {acc, ord} ->
        {message, ord} = rewrite_message(message, keep, ord)
        {[message | acc], ord}
      end)

    Enum.reverse(rewritten)
  end

  defp rewrite_message(%{"content" => parts} = message, keep, ord) when is_list(parts) do
    {parts, ord} = rewrite_parts(parts, keep, ord)
    {Map.put(message, "content", parts), ord}
  end

  defp rewrite_message(%{content: parts} = message, keep, ord) when is_list(parts) do
    {parts, ord} = rewrite_parts(parts, keep, ord)
    {Map.put(message, :content, parts), ord}
  end

  defp rewrite_message(message, _keep, ord), do: {message, ord}

  defp rewrite_parts(parts, keep, ord) do
    {rewritten, ord} =
      Enum.reduce(parts, {[], ord}, fn part, {acc, ord} ->
        case image_url(part) do
          nil ->
            {[part | acc], ord}

          url ->
            if MapSet.member?(keep, ord) do
              {[part | acc], ord + 1}
            else
              {[placeholder_part(part, url) | acc], ord + 1}
            end
        end
      end)

    {Enum.reverse(rewritten), ord}
  end

  defp placeholder_part(%{"type" => "image_url"}, url), do: %{"type" => "text", "text" => placeholder(url)}
  defp placeholder_part(%{type: "image_url"}, url), do: %{type: "text", text: placeholder(url)}
  defp placeholder_part(_part, url), do: %{"type" => "text", "text" => placeholder(url)}

  # ── 部件识别与小工具 ──

  defp vision(caps, client) do
    case Map.get(caps, :vision, Map.get(client, :vision, true)) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp content_parts(%{"content" => parts}) when is_list(parts), do: parts
  defp content_parts(%{content: parts}) when is_list(parts), do: parts
  defp content_parts(_), do: []

  defp image_url(%{"type" => "image_url", "image_url" => %{"url" => url}}) when is_binary(url), do: url
  defp image_url(%{"type" => "image_url", "image_url" => url}) when is_binary(url), do: url
  defp image_url(%{type: "image_url", image_url: %{url: url}}) when is_binary(url), do: url
  defp image_url(%{type: "image_url", image_url: url}) when is_binary(url), do: url
  defp image_url(_), do: nil

  # base64 长度直接换算字节数：不解码，避免每次请求都把图片读一遍。
  defp data_url_bytes(url) do
    {_meta, payload} = split_data_url(url)
    base64_bytes(payload)
  end

  defp base64_bytes(payload) do
    length = byte_size(payload)

    whole = div(length, 4) * 3

    padding =
      cond do
        String.ends_with?(payload, "==") -> 2
        String.ends_with?(payload, "=") -> 1
        true -> 0
      end

    case rem(length, 4) do
      0 -> whole - padding
      2 -> whole + 1
      3 -> whole + 2
      _ -> whole
    end
  end

  # 稳定 id：只哈希前若干字节的头，不把整张图读一遍；同图同 id，跨进程/重启一致。
  defp image_id(url) do
    case split_data_url(url) do
      {_meta, payload} ->
        head_size = min(byte_size(payload), @id_head_bytes)
        head = binary_part(payload, 0, head_size)

        :crypto.hash(:sha256, head)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)
    end
  end

  defp media_type(url) do
    case Regex.run(~r/^data:([^;,]+)/, url) do
      [_, mime] -> mime
      _ -> "image"
    end
  end

  defp split_data_url(url) do
    case String.split(url, ",", parts: 2) do
      [meta, payload] -> {meta, payload}
      [payload] -> {"", payload}
    end
  end
end
