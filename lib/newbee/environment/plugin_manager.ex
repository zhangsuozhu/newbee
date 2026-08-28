defmodule Newbee.Environment.PluginManager do
  @moduledoc """
  Plugin Manager (DESIGN §4.5 / §13)：contract 校验、依赖解析、release 物化。

  - **物化**：release 源码写入 `.newbee/plugins/<plugin_id>/releases/<rel>/`，
    一经发布只读，不做原地 migration（§11.1 P1）；
  - **static 评价**：编译 + contract envelope + 依赖图解析（§8.2 Static 层）；
  - **装载**：把 active release set 编译/加载进求值器节点（generation 物化）；
  - **builtin**：应用内编译进 BEAM 的能力以 builtin release 身份注册
    （内容寻址用模块 md5），与源码 release 走同一生命周期。

  纯函数 + 磁盘，无独立状态——active 指针归 Coordinator/Manifest。
  """

  alias Newbee.Environment.{PluginContract, Release, Store, ToolContract}

  # ── 物化 ──

  @doc """
  物化 release 到项目 store：写 source_files + release.json + usage.md。
  目录已存在且 hash 一致 → 幂等成功；hash 不一致 → 拒绝（不可变）。
  """
  def materialize(%Release{} = release) do
    Store.ensure!()
    dir = Store.release_dir(release.plugin_id, release.release_id)
    meta_path = Path.join(dir, "release.json")

    cond do
      File.exists?(meta_path) ->
        case File.read(meta_path) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, %{"source_hash" => h}} when h == release.source_hash -> {:ok, dir}
              _ -> {:error, :immutable_conflict}
            end

          _ ->
            {:error, :immutable_conflict}
        end

      release.source_files == %{} ->
        # builtin/引用型 release：只写元数据
        File.mkdir_p!(dir)
        write_release_meta(dir, release)
        {:ok, dir}

      true ->
        File.mkdir_p!(dir)

        Enum.each(release.source_files, fn {name, content} ->
          name = to_string(name)

          if String.contains?(name, ["..", "/", "\\"]) do
            raise ArgumentError, "invalid source file name: #{name}"
          end

          File.write!(Path.join(dir, name), content)
        end)

        write_release_meta(dir, release)
        update_plugin_manifest(release)
        {:ok, dir}
    end
  end

  defp write_release_meta(dir, %Release{} = release) do
    Store.write_atomic!(
      Path.join(dir, "release.json"),
      Jason.encode_to_iodata!(Release.to_map(release), pretty: true)
    )

    if release.usage != "" do
      File.write!(Path.join(dir, "usage.md"), release.usage)
    end
  end

  defp update_plugin_manifest(%Release{} = release) do
    dir = Store.plugin_dir(release.plugin_id)
    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")

    manifest =
      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, m} -> m
            _ -> %{"plugin_id" => release.plugin_id, "releases" => []}
          end

        _ ->
          %{"plugin_id" => release.plugin_id, "releases" => []}
      end

    releases = Enum.uniq((manifest["releases"] || []) ++ [release.release_id])
    manifest = %{manifest | "releases" => releases}

    Store.write_atomic!(path, Jason.encode_to_iodata!(manifest, pretty: true))
  end

  @doc "从磁盘读取已物化 release。"
  def fetch(release_id) do
    case String.split(to_string(release_id), "@") do
      [plugin_id, _hash] ->
        dir = Store.release_dir(plugin_id, release_id)

        with {:ok, body} <- File.read(Path.join(dir, "release.json")),
             {:ok, map} <- Jason.decode(body) do
          {:ok, Release.from_map(map)}
        else
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :bad_release_id}
    end
  end

  # ── Static 评价层（§8.2）──

  @doc """
  静态校验 release：编译全部源码 + contract envelope + 依赖存在性。
  `available` = 当前可解析的 plugin_id 集合（全局 registry + 项目 store）。
  """
  def static_validate(%Release{} = release, available \\ nil) do
    available = available || all_plugin_ids()

    with :ok <- validate_dependencies(release, available),
         :ok <- validate_sources(release),
         :ok <- validate_builtin_contract(release) do
      :ok
    end
  end

  defp validate_dependencies(%Release{dependencies: deps}, available) do
    missing =
      Enum.reject(deps, fn
        {plugin_id, _req} -> to_string(plugin_id) in available
        plugin_id -> to_string(plugin_id) in available
      end)

    if missing == [], do: :ok, else: {:error, {:missing_dependencies, missing}}
  end

  defp validate_sources(%Release{source_files: files}) when map_size(files) == 0, do: :ok

  defp validate_sources(%Release{source_files: files, kind: kind}) do
    errors =
      Enum.flat_map(files, fn {name, source} ->
        case PluginContract.validate_source(source, kind) do
          {:ok, _} -> []
          {:error, reasons} -> [{name, reasons}]
        end
      end)

    cond do
      errors != [] -> {:error, {:contract_violation, errors}}
      # 有状态插件必须提供完整生命周期（§4.5）
      kind == :stateful_service -> :ok
      true -> :ok
    end
  end

  defp validate_builtin_contract(%Release{kind: :tool, source_files: files, plugin_id: plugin_id})
       when map_size(files) == 0 do
    case Newbee.Plugins.module_for_plugin_id(plugin_id) do
      nil -> {:error, {:unknown_builtin_tool, plugin_id}}
      module -> ToolContract.validate_builtin(module)
    end
  end

  defp validate_builtin_contract(_release), do: :ok

  @doc "全部已知 plugin_id（builtin + 项目 store + 全局 store）。"
  def all_plugin_ids do
    builtin = Enum.map(Newbee.Plugins.builtins(), & &1.plugin_id)

    project =
      Store.dir(:plugins)
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)

    Enum.uniq(builtin ++ project)
  end

  # ── 装载（generation 物化）──

  @doc """
  把 release 加载到目标节点（或本节点）。返回 {:ok, modules} | {:error, reason}。
  builtin release（无源码）只在目标节点确认模块可用。
  """
  def load_release(%Release{source_files: files}, node \\ nil) do
    target = node || Node.self()

    if map_size(files) == 0 do
      {:ok, []}
    else
      modules =
        Enum.flat_map(files, fn {name, source} ->
          case compile_on(target, source, to_string(name)) do
            {:ok, mods} -> mods
            {:error, reason} -> throw({:load_failed, name, reason})
          end
        end)

      {:ok, modules}
    end
  catch
    {:load_failed, name, reason} -> {:error, {:load_failed, name, reason}}
  end

  defp compile_on(node, source, name) do
    if node == Node.self() do
      try do
        Code.put_compiler_option(:ignore_module_conflict, true)
        {:ok, Code.compile_string(source, name) |> Enum.map(&elem(&1, 0))}
      rescue
        e -> {:error, Exception.message(e)}
      after
        Code.put_compiler_option(:ignore_module_conflict, false)
      end
    else
      case :rpc.call(node, Newbee.Environment.PluginManager, :compile_on_local, [source, name], 60_000) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        other -> other
      end
    end
  end

  @doc false
  def compile_on_local(source, name), do: compile_on(Node.self(), source, name)

  @doc """
  物化一组 active release 到目标节点（generation 启动用）。
  返回 {:ok, loaded} | {:error, {release_id, reason}}；失败不加载半成品之外的承诺：
  已加载的模块无害（未被激活指针引用）。
  """
  def materialize_active(active, node) when is_map(active) do
    Enum.reduce_while(active, {:ok, %{}}, fn {plugin_id, release_id}, {:ok, acc} ->
      with {:ok, release} <- fetch_or_builtin(release_id),
           {:ok, modules} <- load_release(release, node) do
        {:cont, {:ok, Map.put(acc, plugin_id, modules)}}
      else
        {:error, reason} -> {:halt, {:error, {release_id, reason}}}
      end
    end)
  end

  @doc "release 解析：优先项目 store，其次 builtin registry。"
  def fetch_or_builtin(release_id) do
    case fetch(release_id) do
      {:ok, r} ->
        {:ok, r}

      {:error, _} ->
        case Enum.find(Newbee.Plugins.builtins(), &(&1.release_id == release_id)) do
          nil -> {:error, :not_found}
          r -> {:ok, r}
        end
    end
  end

  # ── 依赖图（§8.4 回退时整图重解析）──

  @doc """
  拓扑排序 active 图（按 dependencies）。环 → {:error, :cyclic}。
  """
  def topo_sort(releases) when is_list(releases) do
    by_id = Map.new(releases, &{&1.plugin_id, &1})

    Enum.reduce(releases, {[], MapSet.new()}, fn r, {order, seen} ->
      visit(r, by_id, order, seen, [])
    end)
    |> then(fn {order, _} -> {:ok, Enum.reverse(order) |> Enum.uniq_by(& &1.plugin_id)} end)
  catch
    :cyclic -> {:error, :cyclic_dependencies}
  end

  defp visit(%Release{} = r, by_id, order, seen, stack) do
    cond do
      r.plugin_id in stack ->
        throw(:cyclic)

      MapSet.member?(seen, r.plugin_id) ->
        {order, seen}

      true ->
        {order, seen} =
          Enum.reduce(r.dependencies, {order, seen}, fn dep, {o, s} ->
            dep_id =
              dep
              |> then(fn
                {id, _} -> id
                id -> id
              end)
              |> to_string()

            case Map.fetch(by_id, dep_id) do
              {:ok, dep_r} -> visit(dep_r, by_id, o, s, [r.plugin_id | stack])
              :error -> {o, s}
            end
          end)

        {[r | order], MapSet.put(seen, r.plugin_id)}
    end
  end
end
