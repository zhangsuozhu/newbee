defmodule Newbee.Media do
  @moduledoc """
  媒体上屏（Media Showcase）：模型把图片/音频/视频一键展示到 WebUI。

  模型在 DEE（run_elixir）里调用 `Newbee.Tools.Media.show/2`，本模块：

  1. 把媒体文件复制进会话制品目录 `~/.newbee/session-artifacts/<sid>/media/<id>.<ext>`；
  2. 生成不透明访问 URL `/media/<sid>/<id>`（WebUI 免认证可拉取，id 即令牌）；
  3. 经 Bus 广播 `:web_event`（kind = `:media_show`），WebSocket 下行，
     前端会话流即时渲染图片/音频/视频卡片；
  4. 落一份 `manifest.json`，供 `media.list` RPC 在恢复历史时展示
     「本会话上屏媒体」回放区。

  事件 payload：
      %{media_id, url, kind, caption, name, size, ext, created_at}

  其中 kind ∈ `image | audio | video | other`（按扩展名推断）。
  """

  alias Newbee.Session

  @max_bytes 50 * 1024 * 1024
  @ext_kind %{
    "png" => "image",
    "jpg" => "image",
    "jpeg" => "image",
    "gif" => "image",
    "webp" => "image",
    "svg" => "image",
    "bmp" => "image",
    "mp3" => "audio",
    "wav" => "audio",
    "ogg" => "audio",
    "m4a" => "audio",
    "flac" => "audio",
    "aac" => "audio",
    "mp4" => "video",
    "webm" => "video",
    "mov" => "video",
    "mkv" => "video",
    "avi" => "video",
    "mpeg" => "video",
    "mpg" => "video",
    "ts" => "video"
  }

  @doc "单个文件上屏到指定会话。返回 {:ok, payload} | {:error, code, message}。"
  def show(sid, path, opts \\ [])

  def show(sid, path, opts) when is_binary(sid) and is_binary(path) do
    caption = Keyword.get(opts, :caption)
    name = Keyword.get(opts, :name) || Path.basename(path)
    ext = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    with {:ok, %{size: size}} <- ok_stat(File.stat(path)),
         true <- size > 0 or {:error, "empty", "文件为空: #{path}"},
         true <- size <= @max_bytes or {:error, "too_large", "媒体超过 #{fmt_bytes(@max_bytes)} 上限: #{path}"},
         {:ok, kind} <- kind_for(ext, path),
         media_id <- gen_id(),
         dest <- media_path(sid, media_id, ext),
         :ok <- File.mkdir_p(Path.dirname(dest)) |> mkdir_ok(),
         {:ok, bin} <- File.read(path),
         :ok <- File.write(dest, bin) do
      payload = %{
        media_id: media_id,
        url: "/media/#{sid}/#{media_id}",
        kind: kind,
        caption: caption,
        name: name,
        ext: ext,
        size: size,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      append_manifest(sid, payload)
      append_transcript(sid, payload)
      broadcast(sid, payload)

      {:ok, payload}
    else
      {:error, :enoent} -> {:error, "not_found", "文件不存在: #{path}"}
      {:error, reason} -> {:error, "media_failed", format_reason(reason)}
      {:error, code, msg} -> {:error, code, msg}
    end
  rescue
    e -> {:error, "media_failed", Exception.message(e)}
  end

  def show(_, _, _), do: {:error, "bad_request", "需要 sessionId 与文件路径"}

  @doc "列出会话已上屏媒体（manifest 顺序：新→旧）。"
  def list(sid) when is_binary(sid) do
    manifest_path(sid)
    |> File.read()
    |> case do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, items} when is_list(items) -> {:ok, items}
          _ -> {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  def list(_), do: {:ok, []}

  @doc "删除已上屏媒体（含文件与 manifest 条目）。返回 :ok | {:error, code, msg}。"
  def delete(sid, media_id) when is_binary(sid) and is_binary(media_id) do
    with {:ok, items} <- list(sid) do
      case Enum.find(items, &(&1["media_id"] == media_id)) do
        nil ->
          {:error, "not_found", "媒体不存在: #{media_id}"}

        item ->
          ext = item["ext"] || ""
          File.rm(media_path(sid, media_id, ext))
          kept = Enum.reject(items, &(&1["media_id"] == media_id))
          File.write!(manifest_path(sid), Jason.encode_to_iodata!(kept))
          :ok
      end
    end
  end

  def delete(_, _), do: {:error, "bad_request", "需要 sessionId 与 mediaId"}

  @doc "读取媒体文件字节（Web 下载 / 前端展示用）。返回 {:ok, binary} | {:error, reason}。"
  def read(sid, media_id) when is_binary(sid) and is_binary(media_id) do
    with {:ok, items} <- list(sid) do
      case Enum.find(items, &(&1["media_id"] == media_id)) do
        nil -> {:error, :enoent}
        item -> File.read(media_path(sid, media_id, item["ext"] || ""))
      end
    end
  end

  def read(_, _), do: {:error, :enoent}

  @doc "按 media_id 查 manifest 条目（含 ext / kind / name / url）。返回 {:ok, map} | {:error, :enoent}。"
  def info(sid, media_id) when is_binary(sid) and is_binary(media_id) do
    with {:ok, items} <- list(sid) do
      case Enum.find(items, &(&1["media_id"] == media_id)) do
        nil -> {:error, :enoent}
        item -> {:ok, item}
      end
    end
  end

  def info(_, _), do: {:error, :enoent}

  @doc "媒体文件绝对路径。"
  def media_path(sid, media_id, ext \\ "") do
    safe = String.replace(media_id, ~r/[^a-zA-Z0-9_-]/, "")
    base = Path.join([Session.media_dir(sid), safe])
    if ext == "", do: base, else: base <> "." <> ext
  end

  @doc "行内展示用的 text 摘要（tool result 呈现给模型）。"
  def describe({:ok, payload}) do
    "✓ 已上屏 #{payload.kind} `#{payload.name}`（#{fmt_bytes(payload.size)}）\n" <>
      "  media_id=#{payload.media_id} url=#{payload.url}" <>
      if(payload.caption, do: "\n  caption=#{payload.caption}", else: "")
  end

  def describe({:error, code, msg}), do: "✗ 上屏失败 [#{code}] #{msg}"

  defp mkdir_ok(:ok), do: :ok
  defp mkdir_ok({:ok, _}), do: :ok
  defp mkdir_ok(other), do: other

  defp ok_stat({:ok, stat}), do: {:ok, %{size: stat.size}}
  defp ok_stat(err), do: err

  defp kind_for(ext, path) do
    case Map.get(@ext_kind, ext) do
      nil ->
        case File.read(path) do
          {:ok, bin} -> sniff_kind(bin)
          _ -> {:ok, "other"}
        end

      kind ->
        {:ok, kind}
    end
  end

  defp sniff_kind(<<0x89, ?P, ?N, ?G, _::binary>>), do: {:ok, "image"}
  defp sniff_kind(<<0xFF, 0xD8, _::binary>>), do: {:ok, "image"}
  defp sniff_kind(<<"RIFF", _::binary>>), do: {:ok, "audio"}
  defp sniff_kind(<<"OggS", _::binary>>), do: {:ok, "audio"}
  defp sniff_kind(<<"ID3", _::binary>>), do: {:ok, "audio"}
  defp sniff_kind(<<_::32, "ftyp", _::binary>>), do: {:ok, "video"}
  defp sniff_kind(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: {:ok, "video"}
  defp sniff_kind(_), do: {:ok, "other"}

  # 同步落一条 media 消息进会话 transcript：历史回放时前端据此重建媒体卡片
  defp append_transcript(sid, payload) do
    try do
      session = Newbee.Session.open(sid)
      Newbee.Session.append(session, %{"role" => "media", "content" => payload})
    rescue
      _ -> :ok
    end
  end

  defp append_manifest(sid, payload) do
    {:ok, items} = list(sid)
    File.mkdir_p!(Session.media_dir(sid))
    File.write!(manifest_path(sid), Jason.encode_to_iodata!([payload | items]))
  end

  defp manifest_path(sid), do: Path.join(Session.media_dir(sid), "manifest.json")

  defp broadcast(sid, payload) do
    # DEE 求值节点上没有 Bus 进程：经 Host.emit 转发到主节点（on_main? 时直发，
    # 否则 RPC 回主 VM 的 Bus），WebSocket 订阅者才能收到 :media_show 下行。
    Newbee.Host.emit(:web_event, {:web_event, sid, :media_show, payload})
    :ok
  end

  defp gen_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp fmt_bytes(n) when n >= 1_048_576, do: :io_lib.format("~.1fMB", [n / 1_048_576]) |> IO.iodata_to_binary()
  defp fmt_bytes(n) when n >= 1_024, do: :io_lib.format("~.1fKB", [n / 1_024]) |> IO.iodata_to_binary()
  defp fmt_bytes(n), do: "#{n}B"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
