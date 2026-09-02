defmodule Newbee.Tools.HotReload do
  @moduledoc """
  BEAM 模块热替换：从完整源码或文件加载。
  默认作用当前节点；传 `target: :main` 经 RPC 作用 newbee 主节点。

  ## 函数清单
  - `replace(source, opts \ []) :: map()` — 编译完整源码字符串并替换其中模块。`opts` 支持 `file:`、`target:`、`force:`。
  - `load_file(path, opts \ []) :: map()` — 加载 `.ex/.exs/.beam` 文件；选项同 `replace/2`。
  - `status(module) :: map()` — 返回 `loaded?`、`source`、`md5`、`old_code?`。
  - `purge(module) :: map()` — 强制清除旧代码版本，返回 `purged?` 和 `old_code_remaining?`。
  - `unload(module) :: map()` — `delete + purge` 卸载模块，返回 `deleted?`、`purged?`、`loaded?`。

  `replace_local/2`、`load_file_local/2` 是 RPC 内部入口（`@doc false`），模型不直接调用。

  ## 可跑示例
      source = "defmodule Demo.Hot do\n  def hi, do: :ok\nend"
      %{ok: true} = Newbee.Tools.HotReload.replace(source)
      %{ok: true} = Newbee.Tools.HotReload.load_file("lib/demo/hot.ex", target: :main)
      %{ok: true, loaded?: loaded?} = Newbee.Tools.HotReload.status(Demo.Hot)
      %{ok: true, purged?: _} = Newbee.Tools.HotReload.purge(Demo.Hot)
      %{ok: true, loaded?: false} = Newbee.Tools.HotReload.unload(Demo.Hot)

  `force: true` 和 `purge/unload` 可能终止旧代码路径；只对可重新加载的临时或明确目标模块使用。
  """

  @rpc_timeout 60_000

  @doc """
  从完整源码字符串编译并替换其中定义的模块；参数不是模块名。
  opts:
    - :file   源码文件名（诊断用，默认 "hot_reload.ex"）
    - :target :local（默认）| :main | 节点 atom——在哪个节点替换
    - :force  true 时强行 purge 旧代码（有进程仍在用旧版本时，默认报错不换）
  返回 `%{ok: true, file: _, modules: [...], warnings: [...]}`；编译/加载失败返回 `%{ok: false, error: reason}`。
  """
  def replace(source, opts \\ []) when is_binary(source) do
    dispatch(:replace, [source, opts], opts)
  end

  @doc """
  从文件加载并替换模块：.beam → 直接 load_binary；.ex/.exs → 读源码编译替换。
  opts 同 replace/2。
  """
  def load_file(path, opts \\ []) when is_binary(path) do
    dispatch(:load_file, [path, opts], opts)
  end

  @doc "查看模块状态：loaded?/source/md5/old_code?。module 可为 atom 或字符串。"
  def status(module) do
    mod = to_module(module)
    loaded = :code.is_loaded(mod)

    case loaded do
      false ->
        %{ok: true, module: mod, loaded?: false, md5: nil, old_code?: false}

      {:file, file} ->
        %{
          ok: true,
          module: mod,
          loaded?: true,
          source: List.to_string(file),
          md5: module_md5(mod),
          old_code?: :erlang.check_old_code(mod)
        }

      _other ->
        %{
          ok: true,
          module: mod,
          loaded?: true,
          source: nil,
          md5: module_md5(mod),
          old_code?: :erlang.check_old_code(mod)
        }
    end
  end

  @doc "强制清除模块旧代码版本，返回包含 purged? 与 old_code_remaining? 的 map。"
  def purge(module) do
    mod = to_module(module)
    purged = :code.purge(mod)
    %{ok: true, module: mod, purged?: purged, old_code_remaining?: :erlang.check_old_code(mod)}
  end

  @doc "卸载模块（delete + purge），返回包含 deleted?/purged?/loaded? 的 map。"
  def unload(module) do
    mod = to_module(module)
    deleted = :code.delete(mod)
    purged = :code.purge(mod)
    %{ok: true, module: mod, deleted?: deleted, purged?: purged, loaded?: :code.is_loaded(mod) != false}
  end

  # ── 本地实现（也可被 RPC 到目标节点执行）──

  @doc false
  def replace_local(source, opts \\ []) do
    file = Keyword.get(opts, :file, "hot_reload.ex")
    force? = Keyword.get(opts, :force, false)

    try do
      compiled = Code.compile_string(source, file)
      results = Enum.map(compiled, fn {mod, _bin} -> load_swap(%{mod: mod}, force?) end)

      warnings =
        results
        |> Enum.flat_map(fn r -> r[:warnings] || [] end)
        |> Enum.uniq()

      %{
        ok: true,
        file: file,
        modules:
          Enum.map(results, fn r ->
            Map.delete(Map.put(Map.take(r, [:mod, :new_md5, :old_code?]), :module, r[:mod]), :mod)
          end),
        warnings: warnings
      }
    rescue
      e -> %{ok: false, error: Exception.message(e)}
    catch
      kind, reason -> %{ok: false, error: "#{kind}: #{inspect(reason)}"}
    end
  end

  @doc false
  def load_file_local(path, opts \\ []) do
    cond do
      String.ends_with?(path, ".beam") ->
        case File.read(path) do
          {:ok, binary} ->
            case beam_module(path) do
              {:ok, mod} -> load_binary_swap(%{module: mod, source: path}, mod, path, binary, opts)
              {:error, reason} -> %{ok: false, error: {:invalid_beam, reason}}
            end

          {:error, reason} ->
            %{ok: false, error: {:read_failed, reason}}
        end

      true ->
        case File.read(path) do
          {:ok, source} -> replace_local(source, Keyword.put(opts, :file, path))
          {:error, reason} -> %{ok: false, error: {:read_failed, reason}}
        end
    end
  end

  # ── 路由：本地 / RPC 到目标节点 ──

  defp dispatch(fun, args, opts) do
    target = target_node(Keyword.get(opts, :target, :local))

    if target == Node.self() do
      apply(__MODULE__, :"#{fun}_local", args)
    else
      rpc_call(target, fun, args)
    end
  end

  defp rpc_call(node, fun, args) do
    case :rpc.call(node, __MODULE__, :"#{fun}_local", args, @rpc_timeout) do
      {:badrpc, reason} -> %{ok: false, error: {:badrpc, reason}}
      result -> result
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp target_node(:local), do: Node.self()
  defp target_node(:main), do: Newbee.Host.main_node()
  defp target_node("local"), do: Node.self()
  defp target_node("main"), do: Newbee.Host.main_node()
  defp target_node(node) when is_atom(node), do: node
  defp target_node(node) when is_binary(node) and node != "", do: String.to_atom(node)

  # ── 加载细节 ──

  defp load_swap(%{mod: mod} = acc, force?) do
    # compile_string 已自动载入新代码；若旧版本仍被进程持有（old_code），
    # soft_purge 会失败——默认报错， force 则硬 purge。
    case :code.soft_purge(mod) do
      true ->
        Map.merge(acc, %{old_code?: false, new_md5: module_md5(mod)})

      false ->
        if force? do
          :code.purge(mod)
          Map.merge(acc, %{old_code?: false, new_md5: module_md5(mod), force_purged?: true})
        else
          %{ok: false, error: {:old_code_in_use, mod}, hint: "有进程仍在运行旧版本；确认后加 force: true 硬替换"}
        end
    end
  end

  defp load_binary_swap(acc, mod, path, binary, opts) do
    force? = Keyword.get(opts, :force, false)

    case :code.soft_purge(mod) do
      true ->
        case :code.load_binary(mod, String.to_charlist(path), binary) do
          {:module, ^mod} -> Map.merge(acc, %{ok: true, old_code?: false, new_md5: module_md5(mod)})
          other -> %{ok: false, error: {:load_binary_failed, other}}
        end

      false ->
        if force? do
          :code.purge(mod)

          case :code.load_binary(mod, String.to_charlist(path), binary) do
            {:module, ^mod} ->
              Map.merge(acc, %{ok: true, old_code?: false, new_md5: module_md5(mod), force_purged?: true})

            other ->
              %{ok: false, error: {:load_binary_failed, other}}
          end
        else
          %{ok: false, error: {:old_code_in_use, mod}, hint: "有进程仍在运行旧版本；确认后加 force: true 硬替换"}
        end
    end
  end

  defp module_md5(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} -> mod.module_info(:md5) |> Base.encode16(case: :lower)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp beam_module(path) do
    case :beam_lib.info(String.to_charlist(path))[:module] do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  defp to_module(mod) when is_atom(mod), do: mod

  defp to_module(mod) when is_binary(mod) do
    mod = String.trim_leading(mod, "Elixir.")
    Module.concat([mod])
  end
end
