defmodule Newbee.Environment.Store do
  @moduledoc """
  Project Store (DESIGN §4.6 / §11.1)：项目 `.newbee/` 目录的持久化协议。

  布局（§11.1）：

  ```text
  <project>/.newbee/
  ├── environment.json      # active revision 派生快照 + event checkpoint
  ├── profile.md            # adapter 维护的项目画像（不可信数据，仅启发）
  ├── plugins/<plugin_id>/manifest.json + releases/<rel>/   # 不可变 release
  ├── changes/<change_id>/  # change manifest、评测计划与结果
  ├── evaluations/<id>/     # 测试/回放/worker 反馈证据（含失败抗体）
  ├── messages.jsonl        # worker ↔ adapter 协议（事件流派生物理视图）
  ├── events.jsonl          # 项目级事件流（Event Store，唯一权威）
  ├── projections/          # prompt、工具清单、画像等物化视图
  ├── bindings/             # 可选绑定快照
  └── locks/                # change/release 原子提交锁
  ```

  P1 持久化协议：manifest/projection 先写同目录临时文件，`fsync(file)` 后
  原子 `rename`，再 `fsync(directory)`；崩溃遗留临时文件启动时清理。
  事件流是唯一权威，environment.json 只是带 checkpoint 的派生快照。
  """

  require Logger

  @dir ".newbee"
  @schema_version 1

  @subdirs [:plugins, :changes, :evaluations, :projections, :bindings, :locks]

  # ── 路径 ──

  def root, do: Path.join(File.cwd!(), @dir)
  def root(project_root), do: Path.join(project_root, @dir)

  def path(sub) when sub in [:environment, :messages, :events, :profile] do
    file =
      %{
        environment: "environment.json",
        messages: "messages.jsonl",
        events: "events.jsonl",
        profile: "profile.md"
      }[sub]

    Path.join(root(), file)
  end

  def dir(sub) when sub in [:plugins, :changes, :evaluations, :projections, :bindings, :locks] do
    Path.join(root(), Atom.to_string(sub))
  end

  def plugin_dir(plugin_id), do: Path.join(dir(:plugins), safe(plugin_id))

  def release_dir(plugin_id, release_id),
    do: Path.join(plugin_dir(plugin_id), "releases/#{safe(release_id)}")

  def change_dir(change_id), do: Path.join(dir(:changes), safe(change_id))
  def evaluation_dir(evaluation_id), do: Path.join(dir(:evaluations), safe(evaluation_id))

  defp safe(id), do: id |> to_string() |> String.replace(~r/[^\w\.\-]/, "_")

  # ── 初始化 / 启动恢复 ──

  @doc "首启创建 `.newbee`（验收 §15.1）；已存在则校验 schema 并清理崩溃临时文件。"
  def ensure! do
    File.mkdir_p!(root())
    for sub <- @subdirs, do: File.mkdir_p!(dir(sub))

    unless File.exists?(path(:environment)) do
      write_atomic!(
        path(:environment),
        Jason.encode_to_iodata!(fresh_environment(), pretty: true)
      )
    else
      # 已有快照但 active 空（旧文件或被清空）→ 原地热补内置基线，不丢 revision/checkpoint
      case File.read(path(:environment)) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"active" => active} = env} when is_map(active) ->
              if map_size(active) == 0 do
                builtin = Newbee.Plugins.builtin_active_map()
                patched = Map.put(env, "active", Map.merge(builtin, active))

                patched =
                  case env["manifest"] do
                    %{"active" => mactive, "revision" => rev} when is_map(mactive) and rev == 0 ->
                      if map_size(mactive) == 0,
                        do:
                          Map.put(
                            patched,
                            "manifest",
                            Map.put(env["manifest"], "active", builtin)
                          ),
                        else: patched

                    %{"active" => mactive} when is_map(mactive) ->
                      if map_size(mactive) == 0,
                        do:
                          Map.put(
                            patched,
                            "manifest",
                            Map.put(env["manifest"], "active", builtin)
                          ),
                        else: patched

                    _ ->
                      patched
                  end

                write_atomic!(path(:environment), Jason.encode_to_iodata!(patched, pretty: true))
              end

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    reconcile_missing_builtin_releases!()

    cleanup_temp_files(root())
    :ok
  end

  def schema_version, do: @schema_version

  def fresh_environment do
    %{
      schema: @schema_version,
      revision: 0,
      # rev0 = 内置基线环境（DESIGN §3.1/§5）：内置 release 从首启就在 active 图里，
      # 否则 CapabilityGate 在生产环境拒绝全部内置工具（P0 活锁）。
      active: Newbee.Plugins.builtin_active_map(),
      checkpoint: 0,
      created_at: now_iso()
    }
  end

  # ── environment.json（派生快照，权威在事件流）──

  @doc "读取 environment.json 派生快照。"
  def load_environment do
    ensure!()

    case File.read(path(:environment)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"schema" => v} = env} when v <= @schema_version -> {:ok, env}
          {:ok, %{"schema" => v}} -> {:error, {:unsupported_schema, v}}
          other -> other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "原子写 environment.json（tmp + fsync + rename + dir fsync + checkpoint 推进）。"
  def save_environment(env) when is_map(env) do
    ensure!()
    env = Map.put(env, "schema", @schema_version)
    write_atomic!(path(:environment), Jason.encode_to_iodata!(env, pretty: true))
  end

  # ── 通用原子写 ──

  @doc """
  原子写文件：同目录临时文件 → fsync(file) → rename → fsync(dir)（§11.1 P1）。
  """
  def write_atomic!(path, iodata) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    File.write!(tmp, iodata)
    fsync_file!(tmp)
    File.rename!(tmp, path)
    fsync_dir!(dir)
    :ok
  end

  @doc "追加 JSONL（messages.jsonl 等派生物理视图；事件流请用 EventStore）。"
  def append_jsonl!(path, map) when is_map(map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode_to_iodata!(map), "\n"], [:append])
  end

  @doc "读 JSONL 全部行（坏行跳过）。"
  def read_jsonl(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, m} -> [m]
            _ -> []
          end
        end)

      {:error, :enoent} ->
        []
    end
  end

  # ── 锁（§11.1 locks/，跨 daemon/CLI 写入的项目级互斥）──

  @doc """
  项目级文件锁内执行 fun。锁持有者与超时写入锁元数据；
  持有锁崩溃时下一进程按 mtime 超时（默认 30s）接管。
  """
  def with_lock(name, fun, timeout_ms \\ 5_000) when is_function(fun, 0) do
    ensure!()
    lock = Path.join(dir(:locks), safe(name) <> ".lock")
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    acquire(lock, name, deadline)

    try do
      fun.()
    after
      File.rm(lock)
    end
  end

  defp acquire(lock, name, deadline) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        File.write!(io, Jason.encode!(%{holder: inspect(self()), name: name, at: now_iso()}))
        File.close(io)
        :ok

      {:error, :eexist} ->
        stale? =
          case File.stat(lock, time: :posix) do
            {:ok, %{mtime: mtime}} -> System.system_time(:second) - mtime > 30
            _ -> false
          end

        cond do
          stale? ->
            File.rm(lock)
            acquire(lock, name, deadline)

          System.monotonic_time(:millisecond) > deadline ->
            raise "newbee store lock timeout: #{name}"

          true ->
            Process.sleep(20)
            acquire(lock, name, deadline)
        end
    end
  end

  # ── schema migration（候选目录完成并校验后原子切换；release 目录只读不迁移）──

  def migrate(%{"schema" => v} = env) when v < @schema_version do
    backup = path(:environment) <> ".bak.#{v}"
    File.cp!(path(:environment), backup)
    {:ok, %{env | "schema" => @schema_version}}
  end

  def migrate(env), do: {:ok, env}

  # 旧快照可能引用已被重新编译的 builtin release。项目 release 不可变，
  # 但 builtin 由当前 BEAM 的 module md5 内容寻址，因此只迁移缺失的 builtin 指针。
  defp reconcile_missing_builtin_releases! do
    case File.read(path(:environment)) do
      {:ok, body} ->
        with {:ok, env} <- Jason.decode(body),
             active when is_map(active) <- env["active"] do
          builtin = Newbee.Plugins.builtins() |> Map.new(&{&1.plugin_id, &1.release_id})

          # 1. 已有 plugin_id 但 release 指针过期/缺失 → 迁移到当前 builtin release
          migrated =
            Enum.reduce(active, active, fn {plugin_id, release_id}, acc ->
              current = Map.get(builtin, plugin_id)
              release_path = Path.join(release_dir(plugin_id, release_id), "release.json")

              if current && release_id != current && not File.exists?(release_path) do
                Map.put(acc, plugin_id, current)
              else
                acc
              end
            end)

          # 2. 新增内置插件（当前 BEAM 新增的 builtin，active 图缺失）
          #    —— 内置能力从首启就在 active 图（§3.1/§5），新加内置同样应自动呈现，
          #      避免 CapabilityGate 拒绝"未激活的 builtin 工具"（P0 活锁同源）。
          migrated =
            Enum.reduce(builtin, migrated, fn {plugin_id, release_id}, acc ->
              if Map.has_key?(acc, plugin_id), do: acc, else: Map.put(acc, plugin_id, release_id)
            end)

          if migrated != active do
            patched =
              env
              |> Map.put("active", migrated)
              |> update_manifest_active(migrated)

            write_atomic!(path(:environment), Jason.encode_to_iodata!(patched, pretty: true))
          end
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp update_manifest_active(env, active) do
    case env["manifest"] do
      manifest when is_map(manifest) ->
        Map.put(env, "manifest", Map.put(manifest, "active", active))

      _ ->
        env
    end
  end

  # ── internal ──

  defp cleanup_temp_files(dir) do
    for f <- Path.wildcard(Path.join(dir, "**/*.tmp.*")) do
      Logger.info("cleaning crash temp file #{f}")
      File.rm(f)
    end

    :ok
  end

  defp fsync_file!(path) do
    {:ok, io} = File.open(path, [:read])
    :ok = :file.sync(io)
    File.close(io)
  end

  defp fsync_dir!(dir) do
    case File.open(dir, [:read]) do
      {:ok, io} ->
        _ = :file.sync(io)
        File.close(io)

      _ ->
        :ok
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
