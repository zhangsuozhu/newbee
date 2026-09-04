defmodule Newbee.Memory do
  @moduledoc """
  全局记忆 (DESIGN §6.4.3)：按 topic 索引的持久化记忆条目。
  `~/.newbee/memory/<topic>.md`。自动脱敏：写入时剥离形如
  sk-xxx / Bearer xxx / key=xxx 的密钥片段。
  """

  @dir Path.join(System.user_home!(), ".newbee/memory")

  @doc "读一条记忆（更新 last_ref 时钟，§9.1 TTL GC 用）。返回 {:ok, content} | {:error, :not_found}。"
  def read(topic) do
    path = Path.join(@dir, sanitize_topic(topic) <> ".md")

    case File.read(path) do
      {:ok, body} ->
        touch(topic)
        {:ok, body}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "写一条记忆（自动脱敏）。opts: ttl_days（默认 90）、pin（默认 false）。"
  def write(topic, content, opts \\ []) do
    File.mkdir_p!(@dir)
    File.write!(Path.join(@dir, sanitize_topic(topic) <> ".md"), redact(content))

    put_meta(topic, %{
      "created_at" => now_iso(),
      "last_ref" => now_iso(),
      "ttl_days" => Keyword.get(opts, :ttl_days, 90),
      "pin" => Keyword.get(opts, :pin, false)
    })

    :ok
  end

  @doc "pin/unpin 一条记忆（pin 的活跃值不因 TTL 删除，§9.1）。"
  def pin(topic, pinned \\ true) do
    meta = get_meta(topic) || %{"created_at" => now_iso(), "ttl_days" => 90}
    put_meta(topic, Map.merge(meta, %{"pin" => pinned, "last_ref" => now_iso()}))
    :ok
  end

  @doc """
  TTL GC（§9.1）：过期普通记忆转归档投影（memory/archive/），不删除；
  pin 项与安全规则不因 TTL 删除。
  """
  def gc do
    now = System.system_time(:second)

    for topic <- topics() do
      meta = get_meta(topic)

      if meta && not meta["pin"] do
        last = parse_iso(meta["last_ref"] || meta["created_at"])
        ttl = (meta["ttl_days"] || 90) * 86_400

        if last && now - last > ttl do
          archive(topic)
        end
      end
    end

    :ok
  end

  defp archive(topic) do
    src = Path.join(@dir, sanitize_topic(topic) <> ".md")
    dst_dir = Path.join(@dir, "archive")
    File.mkdir_p!(dst_dir)

    if File.exists?(src) do
      File.rename(src, Path.join(dst_dir, Path.basename(src)))
    end

    meta = (get_meta(topic) || %{}) |> Map.put("archived_at", now_iso())
    put_meta(topic, meta)
  end

  # ── 元数据 sidecar（.meta.json：topic → created_at/last_ref/ttl/pin）──

  @meta Path.join(@dir, ".meta.json")

  defp get_meta(topic) do
    case File.read(@meta) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} -> m[sanitize_topic(topic)]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp put_meta(topic, meta) do
    File.mkdir_p!(@dir)

    all =
      case File.read(@meta) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, m} -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    all = Map.put(all, sanitize_topic(topic), meta)

    tmp = @meta <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(all, pretty: true))
    File.rename!(tmp, @meta)
  end

  defp touch(topic) do
    case get_meta(topic) do
      nil -> :ok
      meta -> put_meta(topic, Map.put(meta, "last_ref", now_iso()))
    end
  end

  defp parse_iso(nil), do: nil

  defp parse_iso(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "删除一条记忆。"
  def delete(topic) do
    File.rm(Path.join(@dir, sanitize_topic(topic) <> ".md"))
    :ok
  end

  @doc "记忆主题列表。"
  def topics do
    @dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".md")))
    |> Enum.sort()
  end

  # 密钥形态：sk-<token> / Bearer <token> / <KEY>=<value> 长值 / GitHub PAT 系列（ghp_/gho_/ghu_/ghs_/ghr_）
  @secret ~r/(sk-[A-Za-z0-9_\-]{8,}|Bearer\s+[A-Za-z0-9_\-\.]{8,}|\b[A-Z_]{3,}_KEY\s*=\s*[^\s]{8,}|gh[opusr]_[A-Za-z0-9]{20,})/
  @redacted "…[redacted]…"

  defp redact(content) do
    Regex.replace(@secret, content, @redacted)
  end

  defp sanitize_topic(topic) do
    topic
    |> String.replace(~r/[^A-Za-z0-9_\-\.]/, "_")
    |> String.slice(0, 64)
  end
end
