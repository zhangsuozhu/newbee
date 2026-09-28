defmodule Newbee.Session do
  @moduledoc """
  会话持久化 (DESIGN §5.3/§3.8)：transcript JSONL 追加写 + 制品目录
  （bindings 快照）。恢复的是状态与绑定值——进程/闭包 tombstone。
  """

  defstruct id: nil, dir: nil, transcript: nil

  defp root, do: Path.join(Newbee.GlobalStore.root(), "sessions")
  defp artifacts, do: Path.join(Newbee.GlobalStore.root(), "session-artifacts")

  defp index, do: Path.join(root(), ".index.json")

  require Logger

  # -- index self-heal and atomic persist (P0) --

  defp read_index do
    case File.read(index()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      _ ->
        []
    end
  end

  defp fs_scan_entries do
    root()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(fn fp ->
      case File.stat(fp) do
        {:ok, stat} ->
          id = Path.basename(fp, ".jsonl")

          [
            %{
              "id" => id,
              "mtime" => posix_mtime(stat.mtime),
              "created" => created_from_id(id) || posix_mtime(stat.mtime),
              "size" => stat.size
            }
          ]

        _ ->
          []
      end
    end)
  end

  # 目录 mtime 不变时复用合并结果。往已有 transcript 追加不会改目录 mtime，
  # 所以热路径不再 wildcard + stat 全部会话。新建/删除会改目录 mtime，缓存失效后重扫。
  # persist 在本目录写临时文件，落盘后按新 mtime 回填。
  defp merged_index do
    mtime = sessions_dir_mtime()

    case :ets.lookup(index_table(), :merged) do
      [{:merged, ^mtime, entries}] when is_list(entries) ->
        entries

      _ ->
        entries = compute_merged_index()
        cache_index(entries, mtime)
        entries
    end
  end

  defp compute_merged_index do
    idx = read_index()
    fs = fs_scan_entries()
    fs_map = Map.new(fs, fn e -> {e["id"], e} end)
    idx_map = Map.new(idx, fn e -> {e["id"], e} end)

    merged_map =
      Map.merge(fs_map, idx_map, fn _id, fs_v, idx_v ->
        %{
          "id" => fs_v["id"],
          "mtime" => idx_v["mtime"] || fs_v["mtime"],
          "created" => idx_v["created"] || fs_v["created"],
          "size" => idx_v["size"],
          "count" => idx_v["count"],
          "auto_title" => idx_v["auto_title"]
        }
      end)

    merged_map
    |> Map.values()
    |> Enum.filter(fn e -> File.regular?(Path.join(root(), e["id"] <> ".jsonl")) end)
    |> Enum.sort_by(fn e -> e["mtime"] || e["created"] end, :desc)
  end

  defp sessions_dir_mtime do
    case File.stat(root()) do
      {:ok, stat} -> posix_mtime(stat.mtime)
      _ -> 0
    end
  end

  defp index_table do
    name = :newbee_session_index

    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, [:named_table, :public, :set, {:read_concurrency, true}])
        catch
          :error, :badarg -> name
        end

      tid ->
        tid
    end
  end

  defp cache_index(entries, mtime \\ nil) do
    :ets.insert(index_table(), {:merged, mtime || sessions_dir_mtime(), entries})
    :ok
  end

  defp persist_index(entries) do
    File.mkdir_p!(root())

    tmp =
      index() <>
        ".tmp-" <>
        Integer.to_string(System.unique_integer([:positive])) <>
        "-" <>
        Integer.to_string(:erlang.monotonic_time())

    File.write!(tmp, Jason.encode_to_iodata!(entries))
    File.rename!(tmp, index())
    cache_index(entries)
    :ok
  rescue
    e ->
      Logger.error("persist_index failed: " <> Exception.message(e))
      :ok
  end

  @doc "repair index: union of index and filesystem, persist and return merged list"
  def repair_index do
    merged = merged_index()
    raw = read_index()
    raw_ids = MapSet.new(raw, fn e -> e["id"] end)
    merged_ids = MapSet.new(merged, fn e -> e["id"] end)

    if MapSet.size(merged_ids) != MapSet.size(raw_ids) or not MapSet.subset?(raw_ids, merged_ids) do
      Logger.warning(
        "repair_index: healing " <>
          Integer.to_string(MapSet.size(raw_ids)) <> " -> " <> Integer.to_string(MapSet.size(merged_ids)) <> " entries"
      )

      persist_index(merged)
    end

    merged
  end

  @doc "当前活动会话 id（kernel 启动时登记；无会话返回 nil）。"
  def current_id, do: :persistent_term.get({__MODULE__, :current}, nil)

  @doc "登记当前活动会话（kernel init 调用；nil 清除）。"
  def set_current(nil), do: :persistent_term.erase({__MODULE__, :current})
  def set_current(id) when is_binary(id), do: :persistent_term.put({__MODULE__, :current}, id)
  @doc "该会话的媒体上屏制品目录（不存在时自动创建）。"
  def media_dir(id) when is_binary(id) do
    dir = Path.join(artifacts(), id <> "/media")
    File.mkdir_p!(dir)
    dir
  end

  def media_dir(_) do
    dir = Path.join(artifacts(), "unknown/media")
    File.mkdir_p!(dir)
    dir
  end

  @doc "该会话的 WebUI 上传文件目录（不存在时自动创建）。"
  def uploads_dir(id) when is_binary(id) do
    dir = Path.join(artifacts(), id <> "/uploads")
    File.mkdir_p!(dir)
    dir
  end

  @doc "新会话或恢复已有会话。"
  def open(id \\ nil) do
    id = id || gen_id()
    dir = Path.join(artifacts(), id)
    File.mkdir_p!(dir)

    %__MODULE__{id: id, dir: dir, transcript: Path.join(root(), "#{id}.jsonl")}
    |> tap(fn _ -> File.mkdir_p!(root()) end)
  end

  # ── 删除墓碑 ──
  # 现场证据：批量删除「当前会话」时约 1/5 概率该会话刷新后仍在——迟到的 ensure/
  # mark_created（残留 WebSocket 的 cast_session、切换会话前后的重连）把刚删的空会话
  # 重建出来（transcript 被重新创建成 0 字节文件 + 写回 .index.json）。
  # 删除后打 60s 墓碑：TTL 内任何路径都不得复活它；客户端只会生成新 id，不受影响。
  @deleted_tombstones {__MODULE__, :deleted_tombstones}
  @deleted_tombstone_ttl_ms 60_000

  @doc "该 id 是否在删除墓碑 TTL 内（60s）。供测试与调用方判断要不要跳过重建。"
  def recently_deleted?(id) when is_binary(id) do
    now = System.monotonic_time(:millisecond)

    case Map.fetch(:persistent_term.get(@deleted_tombstones, %{}), id) do
      {:ok, at} -> now - at < @deleted_tombstone_ttl_ms
      :error -> false
    end
  end

  defp tombstone(id) when is_binary(id) do
    now = System.monotonic_time(:millisecond)

    kept =
      @deleted_tombstones
      |> :persistent_term.get(%{})
      |> Enum.reject(fn {_k, at} -> now - at >= @deleted_tombstone_ttl_ms end)

    :persistent_term.put(@deleted_tombstones, Map.put(Map.new(kept), id, now))
    :ok
  end

  @doc "让新会话立即出现在列表：创建空 transcript 并更新索引（幂等）。墓碑 TTL 内的已删除 id 直接跳过，防止迟到的 ensure 复活刚删的会话。"
  def mark_created(id) when is_binary(id) do
    if recently_deleted?(id), do: :ok, else: do_mark_created(id)
  end

  defp do_mark_created(id) do
    s = open(id)

    if File.regular?(s.transcript) do
      :ok
    else
      File.write!(s.transcript, "")
      touch_index(id)
      :ok
    end
  end

  @doc "追加一条消息到 transcript。"
  def append(%__MODULE__{transcript: t, id: id}, %{"role" => _} = msg) do
    msg = Map.put_new(msg, "created_at", local_iso())
    iodata = [Jason.encode_to_iodata!(msg), "\n"]
    File.write!(t, iodata, [:append])
    touch_index(id, bytes: IO.iodata_length(iodata), user_text: index_user_text(msg))
  end

  defp index_user_text(%{"role" => "user", "content" => content}), do: content_text(content)
  defp index_user_text(_), do: nil

  @doc "Seal abandoned tool calls before a recovered kernel accepts new input. Never call on a running turn."
  def seal_pending_tools(%__MODULE__{} = session) do
    :global.trans(
      {{__MODULE__, :seal, session.id}, self()},
      fn ->
        pending =
          Enum.reduce(messages(session), %{}, fn message, acc ->
            case message do
              %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
                Enum.reduce(calls, acc, fn
                  %{"id" => id}, found when is_binary(id) -> Map.put(found, id, true)
                  _, found -> found
                end)

              %{"role" => "tool", "tool_call_id" => id} ->
                Map.delete(acc, id)

              _ ->
                acc
            end
          end)

        if map_size(pending) > 0 do
          File.write!(session.transcript, "\n", [:append])

          Enum.each(Enum.sort(Map.keys(pending)), fn id ->
            append(session, %{
              "role" => "tool",
              "tool_call_id" => id,
              "content" =>
                "outcome_unknown: execution interrupted before its result was persisted; code was not replayed",
              "recovery" => true
            })
          end)
        end

        map_size(pending)
      end,
      [node()]
    )
  end

  @doc "读取全部历史消息。坏行（崩溃写了一半的）跳过而非崩 init。"
  def messages(%__MODULE__{transcript: t}) do
    fallback = legacy_iso(t)

    case File.read(t) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, msg} when is_map(msg) -> [Map.put_new(msg, "created_at", fallback) | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  @doc "读取当前工作根对应的稳定 system prompt；旧会话没有时返回 nil。"
  def system_prompt(%__MODULE__{dir: dir}) do
    case File.read(Path.join(dir, "system-prompt.md")) do
      {:ok, prompt} -> prompt
      {:error, :enoent} -> nil
      {:error, _} -> nil
    end
  end

  @doc "持久化当前工作根的 system prompt；切换工作根时覆盖。"
  def save_system_prompt(%__MODULE__{dir: dir}, prompt) when is_binary(prompt) do
    File.write!(Path.join(dir, "system-prompt.md"), prompt)
    prompt
  end

  @doc "绑定快照：落两份——`bindings.json`(JSON 可读，tombstone 标注) + `bindings.etf`(ETF 全量，term_to_binary，覆盖 PID/Ref/Fun 等，/resume 优先用 ETF)。"
  def save_bindings(%__MODULE__{dir: d}, binding) do
    safe =
      Enum.map(binding, fn
        {name, v} when is_binary(v) or is_number(v) or is_atom(v) or is_map(v) or is_list(v) ->
          case serializable?(v) do
            true -> [to_string(name), ["ok", v]]
            false -> [to_string(name), "tombstone"]
          end

        {name, _} ->
          [to_string(name), "tombstone"]
      end)

    File.write!(Path.join(d, "bindings.json"), Jason.encode_to_iodata!(safe))
    persist_etf(d, binding)
    persist_beam_snapshot(d, binding)
  end

  @doc "加载绑定：优先 `bindings.etf`（全量反序列化，safe_binary_to_term），否则回退 JSON。"
  def load_bindings(%__MODULE__{dir: d}) do
    case load_etf(d) do
      {:ok, binding} -> binding
      :no_etf -> load_json_bindings(d)
    end
  end

  defp load_json_bindings(d) do
    case File.read(Path.join(d, "bindings.json")) do
      {:ok, body} ->
        body
        |> Jason.decode!()
        |> Enum.flat_map(fn
          [name, ["ok", v]] -> [{String.to_atom(name), v}]
          _ -> []
        end)

      _ ->
        []
    end
  end

  # ── ETF 全量 dump：term_to_binary（可保 PID/Ref/简单 Fun/Port 等的"值语义"快照）──
  # 注意 BEAM 硬限制：外部资源（打开的文件/ETS 表/Port/NIF 资源/跨节点 PID）反序列化后
  # 为"死句柄"，只能做值检查不能继续操作——ETf 侧已尽量保存，tombstone 仅用于不可 term_to_binary 的项。
  defp persist_etf(dir, binding) do
    payload = %{
      version: 1,
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      saved_at: local_iso(),
      bindings: encode_etf_bindings(binding)
    }

    File.write!(Path.join(dir, "bindings.etf"), :erlang.term_to_binary(payload, compressed: 9))
  rescue
    _ -> :ok
  end

  defp encode_etf_bindings(binding) do
    Enum.flat_map(binding, fn {name, v} ->
      if migratable?(v) do
        try do
          bin = :erlang.term_to_binary(v, compressed: 1)
          _ = :erlang.binary_to_term(bin, [:safe])
          [{to_string(name), {:etf, Base.encode64(bin)}}]
        rescue
          _ -> []
        catch
          _, _ -> []
        end
      else
        []
      end
    end)
  end

  defp migratable?(v) when is_pid(v) or is_port(v) or is_reference(v) or is_function(v), do: false
  defp migratable?(_), do: true

  defp load_etf(dir) do
    path = Path.join(dir, "bindings.etf")

    case File.read(path) do
      {:ok, bin} ->
        try do
          payload = :erlang.binary_to_term(bin, [:safe])
          validate_etf_version(payload)
          bindings = decode_etf_bindings(payload[:bindings] || payload["bindings"] || [])
          {:ok, bindings}
        rescue
          _ -> :no_etf
        catch
          _, _ -> :no_etf
        end

      _ ->
        :no_etf
    end
  end

  defp decode_etf_bindings(list) when is_list(list) do
    Enum.flat_map(list, fn
      {name, {:etf, b64}} when is_binary(b64) ->
        decode_etf_entry(name, b64)

      [name, %{"etf" => b64}] when is_binary(b64) ->
        decode_etf_entry(name, b64)

      [name, ["etf", b64]] when is_binary(b64) ->
        decode_etf_entry(name, b64)

      _ ->
        []
    end)
  end

  defp decode_etf_bindings(_), do: []

  defp decode_etf_entry(name, b64) do
    bin = Base.decode64!(b64)
    v = :erlang.binary_to_term(bin, [:safe])
    if migratable?(v), do: [{String.to_atom(name), v}], else: []
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp validate_etf_version(%{otp: _otp, elixir: _elixir}), do: :ok
  defp validate_etf_version(%{"otp" => _otp, "elixir" => _elixir}), do: :ok
  defp validate_etf_version(_), do: :ok

  # ── Beam 快照（诊断/可观测）：文本摘要，非反序列化还原，仅供 /resume 时提示环境差异 ──
  defp persist_beam_snapshot(dir, binding) do
    snapshot = %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      erts: :erlang.system_info(:version) |> List.to_string(),
      nodes: Node.list() |> Enum.map(&to_string/1),
      self_node: Node.self() |> to_string(),
      bindings_summary:
        Enum.map(binding, fn {name, v} ->
          %{name: to_string(name), type: type_of(v), size: byte_size_safe(v)}
        end),
      saved_at: local_iso()
    }

    File.write!(
      Path.join(dir, "beam_snapshot.json"),
      Jason.encode_to_iodata!(snapshot, pretty: true)
    )
  rescue
    _ -> :ok
  end

  defp type_of(v) when is_binary(v), do: "binary"
  defp type_of(v) when is_list(v), do: "list"
  defp type_of(v) when is_map(v), do: "map"
  defp type_of(v) when is_tuple(v), do: "tuple"
  defp type_of(v) when is_pid(v), do: "pid"
  defp type_of(v) when is_port(v), do: "port"
  defp type_of(v) when is_reference(v), do: "reference"
  defp type_of(v) when is_function(v), do: "function"
  defp type_of(_), do: "other"

  defp byte_size_safe(v) do
    try do
      byte_size(:erlang.term_to_binary(v))
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  @doc "该会话是否还存在（transcript 是唯一事实来源；用于过滤已删除的对话）。"
  def exists?(id) when is_binary(id) do
    File.regular?(Path.join(root(), id <> ".jsonl"))
  end

  def exists?(_), do: false

  @doc "删除会话：transcript + artifacts 目录 + 索引。返回 :ok | {:error, reason}。"
  def delete(id) when is_binary(id) do
    transcript = Path.join(root(), "#{id}.jsonl")
    artifacts = Path.join(artifacts(), id)

    with :ok <- remove_file(transcript),
         :ok <- remove_dir(artifacts),
         :ok <- remove_from_index(id) do
      tombstone(id)

      try do
        if current_id() == id, do: set_current(nil)
      rescue
        _ -> :ok
      end

      :ok
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, r} -> {:error, r}
    end
  end

  defp remove_dir(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, r, _} -> {:error, r}
    end
  end

  defp remove_from_index(id) do
    merged = merged_index()
    kept = Enum.reject(merged, fn e -> e["id"] == id end)
    persist_index(kept)
    :ok
  rescue
    e ->
      Logger.error("remove_from_index failed: " <> Exception.message(e))
      :ok
  end

  @doc "重命名会话标题：把 title 元信息落到会话目录的 meta.json（list_with_meta 优先读取）。"
  def rename(id, title) when is_binary(id) and is_binary(title) do
    update_metadata(id, &Map.put(&1, "title", title))
  end

  @doc "保存该会话选用的模型；不会修改全局模型配置。"
  def set_model(id, model) when is_binary(id) and is_binary(model) do
    update_metadata(id, &Map.put(&1, "model", model))
  end

  @doc "读取该会话选用的模型；未选择时返回 nil。"
  def model(id) when is_binary(id) do
    case metadata(id)["model"] do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @doc "保存该会话选用的厂家（provider）；不会修改全局模型配置。"
  def set_provider(id, provider) when is_binary(id) and is_binary(provider) do
    update_metadata(id, &Map.put(&1, "provider", provider))
  end

  @doc "读取该会话选用的厂家；未选择时返回 nil。"
  def provider(id) when is_binary(id) do
    case metadata(id)["provider"] do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> nil
    end
  end

  @doc "读取该会话绑定的绝对项目工作根；旧会话尚未绑定时返回 nil。"
  def cwd(id) when is_binary(id) do
    case metadata(id)["cwd"] do
      cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
      _ -> nil
    end
  end

  @doc "绑定该会话的唯一绝对项目工作根。"
  def set_cwd(id, cwd) when is_binary(id) and is_binary(cwd) do
    update_metadata(id, &Map.put(&1, "cwd", Path.expand(cwd)))
  end

  @doc "读取该会话的思考强度（nil = 未设置，用 client 默认）。"
  def effort(id) when is_binary(id) do
    case metadata(id)["effort"] do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  @doc "绑定该会话的思考强度（reasoning_effort）。"
  def set_effort(id, effort) when is_binary(id) do
    update_metadata(id, &Map.put(&1, "effort", effort))
  end

  defp update_metadata(id, fun) do
    dir = Path.join(artifacts(), id)
    File.mkdir_p!(dir)
    meta_path = Path.join(dir, "meta.json")

    meta = metadata(id) |> fun.()
    tmp_path = meta_path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp_path, Jason.encode_to_iodata!(meta))
    File.rename!(tmp_path, meta_path)
    :ok
  end

  defp metadata(id) do
    meta_path = Path.join([artifacts(), id, "meta.json"])

    with {:ok, body} <- File.read(meta_path),
         {:ok, meta} when is_map(meta) <- Jason.decode(body) do
      meta
    else
      _ -> %{}
    end
  end

  @doc "读取用户自定义标题（rename 落盘）；没有返回 nil。"
  def custom_title(id) when is_binary(id) do
    case metadata(id)["title"] do
      title when is_binary(title) -> title
      _ -> nil
    end
  end

  @doc "会话总数（廉价：单次 File.ls；/status 用）。"
  def count do
    case File.ls(root()) do
      {:ok, files} -> Enum.count(files, &String.ends_with?(&1, ".jsonl"))
      _ -> 0
    end
  end

  @doc "可回收的陈旧空会话 id：transcript 存在但 0 字节，且 mtime 早于 older_than_secs 秒前。"
  def stale_empty_ids(older_than_secs \\ 3600) do
    cutoff = System.system_time(:second) - older_than_secs

    merged_index()
    |> Enum.filter(fn e ->
      (e["mtime"] || 0) < cutoff and
        match?({:ok, %{size: 0}}, File.stat(Path.join(root(), e["id"] <> ".jsonl")))
    end)
    |> Enum.map(fn e -> e["id"] end)
  rescue
    _ -> []
  end

  @doc "有效会话总数（transcript 文件仍存在）。供列表分页计算 total/hasMore。"
  def count_valid do
    length(merged_index())
  rescue
    _ -> length(fs_scan_entries())
  end

  @doc "列出会话元信息（新→旧，默认最多 20 个）：id / when_str / mtime / messages / title。"
  def list_with_meta(n \\ 20, offset \\ 0) do
    {entries, _total} = list_page(n, offset)
    entries
  end

  @doc "分页列表加总数（单次 merged_index）：缓存命中时零 transcript 读盘，未命中单次读盘回填。"
  def list_page(n \\ 20, offset \\ 0) do
    merged = merged_index()
    raw = read_index()
    total = length(merged)

    recent =
      merged
      |> Enum.drop(offset)
      |> Enum.take(n)

    {entries, updates} =
      Enum.flat_map_reduce(recent, %{}, fn entry, acc ->
        id = entry["id"]
        fp = Path.join(root(), id <> ".jsonl")

        case File.stat(fp) do
          {:ok, stat} ->
            fsize = stat.size
            meta = metadata(id)
            custom = meta["title"]
            cwd = meta["cwd"]
            cached_size = entry["size"]
            cached_count = entry["count"]
            cached_title = entry["auto_title"]

            hit =
              cached_size == fsize and is_integer(cached_count) and is_binary(cached_title)

            {count, auto} =
              if hit do
                {cached_count, cached_title}
              else
                fast_transcript_stats(fp)
              end

            acc2 =
              if hit do
                acc
              else
                Map.put(acc, id, %{"size" => fsize, "count" => count, "auto_title" => auto})
              end

            effective = if is_binary(custom), do: custom, else: auto

            entry_out = %{
              id: id,
              mtime: stat.mtime,
              when_str: when_str(stat.mtime),
              messages: count,
              title: effective,
              cwd: cwd
            }

            {[entry_out], acc2}

          _ ->
            {[], acc}
        end
      end)

    if map_size(updates) > 0 or length(merged) != length(raw) do
      spawn(fn -> backfill_index_cache(updates) end)
    end

    {entries, total}
  end

  defp backfill_index_cache(updates) do
    try do
      fresh = merged_index()

      merged =
        Enum.map(fresh, fn e ->
          case Map.get(updates, e["id"]) do
            nil ->
              e

            %{"size" => sz, "count" => c, "auto_title" => a} ->
              e |> Map.put("size", sz) |> Map.put("count", c) |> Map.put("auto_title", a)
          end
        end)

      persist_index(merged)
    rescue
      _ -> :ok
    end
  end

  @doc false
  def transcript_scan_count do
    case :ets.lookup(index_table(), :transcript_scans) do
      [{:transcript_scans, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp note_transcript_scan do
    :ets.update_counter(index_table(), :transcript_scans, {2, 1}, {:transcript_scans, 0})
  end

  # 冷路径才读 transcript。按字节数行，只解码可能是用户消息的行，避免 split 出全部行再逐条 JSON。
  defp fast_transcript_stats(fp) do
    note_transcript_scan()

    case File.read(fp) do
      {:ok, ""} ->
        {0, ""}

      {:ok, bin} ->
        scan_transcript_bin(bin, 0, nil, nil, false)

      _ ->
        {0, ""}
    end
  end

  defp scan_transcript_bin(<<>>, count, first, last, _settled) do
    {count, title_from_user_bounds(first, last)}
  end

  defp scan_transcript_bin(<<"\n", rest::binary>>, count, first, last, settled) do
    scan_transcript_bin(rest, count, first, last, settled)
  end

  defp scan_transcript_bin(bin, count, first, last, settled) do
    case :binary.match(bin, "\n") do
      {pos, 1} ->
        line = binary_part(bin, 0, pos)
        rest = binary_part(bin, pos + 1, byte_size(bin) - pos - 1)
        {first, last, settled} = take_user_line(line, first, last, settled)
        scan_transcript_bin(rest, count + 1, first, last, settled)

      :nomatch ->
        {first, last, _settled} = take_user_line(bin, first, last, settled)
        {count + 1, title_from_user_bounds(first, last)}
    end
  end

  defp take_user_line(_line, first, last, true), do: {first, last, true}

  defp take_user_line(line, first, last, false) do
    if String.contains?(line, "\"role\":\"user\"") do
      case Jason.decode(line) do
        {:ok, %{"role" => "user", "content" => content}} ->
          text = content_text(content)

          cond do
            is_nil(first) and String.length(text) >= 4 -> {text, text, true}
            is_nil(first) -> {text, text, false}
            true -> {first, text, false}
          end

        _ ->
          {first, last, false}
      end
    else
      {first, last, false}
    end
  end

  defp title_from_user_bounds(nil, _), do: ""

  defp title_from_user_bounds(first, last) do
    msgs =
      if String.length(first) >= 4 or last in [nil, first] do
        [%{"role" => "user", "content" => first}]
      else
        [%{"role" => "user", "content" => first}, %{"role" => "user", "content" => last}]
      end

    title(msgs)
  end

  defp touch_index(id, opts \\ []) do
    # 删除墓碑：索引写入本身也可能是迟到的复活路径（append / set_cwd 等都会 touch）
    if recently_deleted?(id) do
      :ok
    else
      do_touch_index(id, opts)
    end
  rescue
    e ->
      Logger.error("touch_index failed: " <> Exception.message(e))
      :ok
  end

  defp do_touch_index(id, opts) do
    now = System.system_time(:second)
    bytes = Keyword.get(opts, :bytes, 0)
    user_text = Keyword.get(opts, :user_text)
    merged = merged_index()
    idx_map = Map.new(merged, fn e -> {e["id"], e} end)
    existing = Map.get(idx_map, id)

    created =
      if existing do
        existing["created"] || created_from_id(id) || existing["mtime"] || now
      else
        created_from_id(id) || now
      end

    base = %{"id" => id, "mtime" => now, "created" => created}

    updated =
      case incremental_cache(existing, id, bytes, user_text) do
        {:ok, fields} -> Map.merge(base, fields)
        :miss -> base
      end

    new_list =
      idx_map
      |> Map.put(id, updated)
      |> Map.values()
      |> Enum.sort_by(fn e -> e["mtime"] || e["created"] end, :desc)

    persist_index(new_list)
  end

  # 索引里的 size/count/title 与文件一致时直接加一，避免为了侧栏重读整个 transcript。
  defp incremental_cache(existing, id, bytes, user_text) when is_integer(bytes) and bytes >= 0 do
    existing = existing || %{}

    cached? =
      is_integer(existing["size"]) and is_integer(existing["count"]) and
        is_binary(existing["auto_title"])

    path = Path.join(root(), id <> ".jsonl")

    known_size = existing["size"]

    case File.stat(path) do
      {:ok, stat} when cached? and stat.size == known_size + bytes ->
        count = existing["count"] + if(bytes > 0, do: 1, else: 0)

        {:ok,
         %{
           "size" => stat.size,
           "count" => count,
           "auto_title" => refresh_auto_title(existing["auto_title"], user_text)
         }}

      {:ok, %{size: 0}} when bytes == 0 and not cached? ->
        {:ok, %{"size" => 0, "count" => 0, "auto_title" => ""}}

      _ ->
        :miss
    end
  end

  defp incremental_cache(_existing, _id, _bytes, _user_text), do: :miss

  defp refresh_auto_title(current, nil), do: current || ""

  defp refresh_auto_title(current, text) when is_binary(text) do
    current = if is_binary(current), do: current, else: ""

    if String.length(current) >= 4 do
      current
    else
      msgs =
        if current == "" do
          [%{"role" => "user", "content" => text}]
        else
          [%{"role" => "user", "content" => current}, %{"role" => "user", "content" => text}]
        end

      title(msgs)
    end
  end

  defp refresh_auto_title(current, _text), do: current || ""

  # 从会话 id 前缀解析创建时间（YYYYMMDD-HHMMSS-xxxx / YYYYMMDD-HHMMSSxxxx），失败返回 nil。
  # id 前缀是本地时间，需按本地 UTC 偏移换算成 unix 秒（与 System.system_time(:second) 同基准）。
  defp created_from_id(id) when is_binary(id) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})[-](\d{2})(\d{2})(\d{2})/, id) do
      [_, y, mo, d, h, mi, s] ->
        local =
          {{String.to_integer(y), String.to_integer(mo), String.to_integer(d)},
           {String.to_integer(h), String.to_integer(mi), String.to_integer(s)}}

        :calendar.datetime_to_gregorian_seconds(local) -
          :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}) -
          utc_offset_seconds()

      _ ->
        nil
    end
  end

  defp created_from_id(_), do: nil

  defp utc_offset_seconds do
    :calendar.datetime_to_gregorian_seconds(:calendar.local_time()) -
      :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
  end

  defp posix_mtime(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp posix_mtime({{_, _, _}, {_, _, _}} = t) do
    :calendar.datetime_to_gregorian_seconds(t) -
      :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  end

  defp posix_mtime(n) when is_integer(n), do: n
  defp posix_mtime(_), do: 0

  @doc "单个会话的元信息（时间 / 消息数 / 标题）。"
  def meta(id) do
    s = open(id)
    stat = File.stat!(s.transcript)
    msgs = messages(s)

    %{
      id: id,
      mtime: stat.mtime,
      when_str: when_str(stat.mtime),
      messages: length(msgs),
      title: title(msgs)
    }
  end

  @doc "会话标题：首条用户消息（太短则用最近一条），单行化 + 截断。"
  def title(msgs) do
    users = msgs |> Enum.filter(&(&1["role"] == "user")) |> Enum.map(&content_text(&1["content"]))

    pick =
      case users do
        [] -> ""
        [first | _] -> if String.length(first) < 4, do: List.last(users), else: first
      end

    pick |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 48)
  end

  defp content_text(text) when is_binary(text), do: text

  defp content_text(parts) when is_list(parts) do
    parts
    |> Enum.find_value("[图片]", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp content_text(_), do: ""

  @doc "按 id 精确或前缀匹配，返回匹配的 id 列表。"
  def find(input) do
    ids = list()

    case Enum.filter(ids, &(&1 == input)) do
      [] -> Enum.filter(ids, &String.starts_with?(&1, input))
      exact -> exact
    end
  end

  def list do
    root()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".jsonl"))
    |> Enum.sort(:desc)
  end

  # File.stat/1 的 datetime tuple 按 UTC 返回；显示前必须转换为系统本地时间。
  defp when_str(utc_datetime) do
    {{y, m, d}, {h, mi, _}} = :calendar.universal_time_to_local_time(utc_datetime)
    {{ny, nm, nd}, _} = :calendar.local_time()

    yesterday =
      (:calendar.date_to_gregorian_days({ny, nm, nd}) - 1) |> :calendar.gregorian_days_to_date()

    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    cond do
      {y, m, d} == {ny, nm, nd} -> "今天 #{pad.(h)}:#{pad.(mi)}"
      {y, m, d} == yesterday -> "昨天 #{pad.(h)}:#{pad.(mi)}"
      y == ny -> "#{pad.(m)}-#{pad.(d)} #{pad.(h)}:#{pad.(mi)}"
      true -> "#{y}-#{pad.(m)}-#{pad.(d)}"
    end
  end

  defp serializable?(v) do
    try do
      Jason.encode!(v)
      true
    rescue
      _ -> false
    end
  end

  defp gen_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  # 本地时间 ISO（无 tz database 时 :calendar.local_time 即系统本地时区）
  defp local_iso do
    local = :calendar.local_time()
    utc = :calendar.universal_time()

    offset =
      :calendar.datetime_to_gregorian_seconds(local) -
        :calendar.datetime_to_gregorian_seconds(utc)

    iso_from_local(local, offset)
  end

  defp legacy_iso(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        local = :calendar.universal_time_to_local_time(mtime)

        offset =
          :calendar.datetime_to_gregorian_seconds(local) -
            :calendar.datetime_to_gregorian_seconds(mtime)

        iso_from_local(local, offset)

      _ ->
        local_iso()
    end
  end

  defp iso_from_local({{y, m, d}, {h, mi, sec}}, offset) do
    sign = if offset < 0, do: "-", else: "+"
    abs_offset = abs(offset)
    oh = div(abs_offset, 3600)
    om = div(rem(abs_offset, 3600), 60)

    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B~s~2..0B:~2..0B", [
      y,
      m,
      d,
      h,
      mi,
      sec,
      sign,
      oh,
      om
    ])
    |> IO.iodata_to_binary()
  end

  @doc "保存受信的协作 persona 配置；只接受 Persona 已校验的运行时字段。"
  def set_collaboration_profile(id, profile) when is_binary(id) and is_map(profile) do
    safe =
      Map.take(profile, [
        "name",
        "role",
        "provider",
        "model",
        "reasoning_effort",
        "instructions",
        "group_id",
        "parent_session_id",
        "fork_turns"
      ])

    update_metadata(id, &Map.put(&1, "collaboration_profile", safe))
  end

  @doc "读取会话的受信协作 persona 配置；普通会话返回 nil。"
  def collaboration_profile(id) when is_binary(id) do
    case metadata(id)["collaboration_profile"] do
      profile when is_map(profile) -> profile
      _ -> nil
    end
  end
end
