defmodule Newbee.LLM.Image do
  @moduledoc """
  本地图片到 OpenAI-compatible 多模态 user message 的转换。

  图片以内联 data URL 发送并随 transcript 持久化；默认限制 8 MiB，避免单张图片
  挤满上下文。支持 PNG、JPEG、GIF、WebP。
  """

  @max_bytes 8 * 1024 * 1024
  @mime_by_extension %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  @default_prompt "请分析这张错误截图，定位相关源码中的 bug，直接修复并运行必要的验证。"

  def message(path, prompt \\ nil)

  def message(path, prompt) when is_binary(path) do
    with {:ok, data_url} <- data_url(path),
         {:ok, text} <- normalize_prompt(prompt) do
      {:ok,
       %{
         "role" => "user",
         "content" => [
           %{"type" => "text", "text" => text},
           %{"type" => "image_url", "image_url" => %{"url" => data_url}}
         ]
       }}
    end
  end

  def message(_, _), do: {:error, :invalid_image_path}

  @doc "读取图片并编码为 data URL。"
  def data_url(path) when is_binary(path) do
    extension = path |> Path.extname() |> String.downcase()

    with {:ok, mime} <- Map.fetch(@mime_by_extension, extension),
         {:ok, %{type: :regular, size: size}} <- File.stat(path),
         true <- size <= @max_bytes,
         {:ok, binary} <- File.read(path) do
      {:ok, "data:#{mime};base64," <> Base.encode64(binary)}
    else
      :error -> {:error, {:unsupported_image_type, extension}}
      {:error, :enoent} -> {:error, :image_not_found}
      {:error, reason} -> {:error, {:image_stat_failed, reason}}
      false -> {:error, {:image_too_large, @max_bytes}}
      _ -> {:error, :image_not_found}
    end
  end

  def data_url(_), do: {:error, :invalid_image_path}

  @doc false
  def max_bytes, do: @max_bytes

  @doc """
  由浏览器上传/粘贴获得的 data URL 直接构造多模态 user message。

  校验：必须是 `data:image/<type>;base64,` 形式的 data URL，解码后不超过
  @max_bytes（8 MiB）。返回 `{:ok, %{"role" => "user", "content" => [...]}}`，
  content 为 [text, image_url, ...] 的 OpenAI-compatible 数组。
  仅支持 PNG / JPEG / GIF / WebP。
  """
  def message_with_images([], _text), do: {:error, :invalid_images}

  def message_with_images(data_urls, text) when is_list(data_urls) do
    with {:ok, prompt} <- normalize_prompt(text),
         {:ok, urls} <- validate_data_urls(data_urls) do
      {:ok,
       %{
         "role" => "user",
         "content" =>
           [%{"type" => "text", "text" => prompt}] ++
             Enum.map(urls, fn url ->
               %{"type" => "image_url", "image_url" => %{"url" => url}}
             end)
       }}
    end
  end

  def message_with_images(_data_urls, _text), do: {:error, :invalid_images}

  @doc "校验 data URL 列表：mime 白名单 + 解码后大小限制。返回 {:ok, [url]} | {:error, reason}。"
  def validate_data_urls(urls) when is_list(urls) do
    urls
    |> Enum.reduce_while({:ok, []}, fn url, {:ok, acc} ->
      case validate_data_url(url) do
        {:ok, _} -> {:cont, {:ok, [url | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  def validate_data_urls(_), do: {:error, :invalid_images}

  @doc false
  def validate_data_url(url) when is_binary(url) do
    with {:ok, mime, b64} <- parse_data_url(url),
         {:ok, binary} <- decode_b64(b64) do
      if byte_size(binary) <= @max_bytes do
        {:ok, {mime, binary}}
      else
        {:error, {:image_too_large, @max_bytes}}
      end
    else
      :error -> {:error, {:invalid_data_url, url |> String.slice(0, 60)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_data_url(_), do: {:error, :invalid_data_url}

  defp parse_data_url(url) do
    case Regex.run(~r/^data:image\/(png|jpeg|jpg|gif|webp);base64,(.+)$/s, url) do
      [_, "jpg" | rest] when rest != [] -> {:ok, "image/jpeg", List.last(rest)}
      [_, type, b64] -> {:ok, "image/" <> normalize_mime_type(type), b64}
      _ -> :error
    end
  end

  defp normalize_mime_type("jpg"), do: "jpeg"
  defp normalize_mime_type(t), do: t

  defp decode_b64(b64) do
    try do
      {:ok, Base.decode64!(b64)}
    rescue
      _ -> {:error, :bad_base64}
    end
  end

  defp normalize_prompt(nil), do: {:ok, @default_prompt}

  defp normalize_prompt(prompt) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> {:ok, @default_prompt}
      text -> {:ok, text}
    end
  end

  defp normalize_prompt(_), do: {:error, :invalid_image_prompt}
end
