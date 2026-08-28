defmodule Newbee.Environment.CapabilityGate do
  @moduledoc """
  能力门（DESIGN §3.2/§5）：Plugin 的 `capabilities` 声明式能力清单
  （fs/shell/net/push…），**Host 按此校验，未声明的能力在 tools/pre-execute
  被物理拒绝**。

  执行模型：模型代码（run_elixir）调用插件模块前，本门检查：

  1. 被调用的模块必须映射到 **active release 图**中的插件——不在图里的
     插件被物理拒绝（环境收敛方向：只有 active 的能力存在）；
  2. 该插件 release 声明的 capabilities 必须**覆盖**模块的副作用类别
     （`Fs`→:fs、`Run`/`Git`→:shell、`Http`→:net …）；
  3. Coordinator 未运行（standalone 模式）时门放行——无环境则无 active 图，
     能力边界退化为 Host Safety（凭证/路径，§8.1 硬边界依然生效）。

  宽松策略管"行为"，宿主契约管"能力"，后者不依赖模型自觉（§5）。
  """

  alias Newbee.Environment.Coordinator

  # 模块 → 所需能力类别
  @module_capabilities %{
    "Newbee.Tools.Fs" => [:fs],
    "Newbee.Tools.Edit" => [:fs],
    "Newbee.Tools.Structural" => [:fs],
    "Newbee.Tools.Run" => [:shell],
    "Newbee.Tools.Git" => [:shell, :fs],
    "Newbee.Tools.Scaffold" => [:shell, :fs],
    "Newbee.Tools.Http" => [:net],
    "Newbee.Tools.Search" => [:fs],
    "Newbee.Tools.Json" => [],
    "Newbee.Tools.Introspect" => [],
    "Newbee.Tools.HotReload" => [],
    "Newbee.Tools.JSpace" => [:fs],
    "Newbee.Tools.Media" => [:fs],
    "Newbee.Plugins.RepoMap" => [:fs]
  }

  @doc """
  tools/pre-execute 检查。返回 :ok | {:deny, reason}。
  """
  def check(code) when is_binary(code) do
    case Process.whereis(Coordinator) do
      nil ->
        # standalone：无 active 图可校验，门放行（Host Safety 硬边界仍在）
        :ok

      _pid ->
        check_against_active(code, Coordinator.current().active)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp check_against_active(code, active) do
    referenced = referenced_modules(code)

    Enum.reduce_while(referenced, :ok, fn mod_str, :ok ->
      case Newbee.Plugins.plugin_id_for(Module.concat([mod_str])) do
        nil ->
          {:cont, :ok}

        plugin_id ->
          case Map.fetch(active, plugin_id) do
            :error ->
              {:halt, {:deny, {:plugin_not_active, plugin_id}}}

            {:ok, release_id} ->
              check_capabilities(mod_str, plugin_id, release_id)
              |> case do
                :ok -> {:cont, :ok}
                {:deny, _} = deny -> {:halt, deny}
              end
          end
      end
    end)
  end

  defp check_capabilities(mod_str, plugin_id, release_id) do
    required = Map.get(@module_capabilities, mod_str, [])

    declared =
      case Newbee.Environment.PluginManager.fetch_or_builtin(release_id) do
        {:ok, release} -> release.capabilities
        _ -> []
      end

    missing = required -- declared

    if missing == [] do
      :ok
    else
      {:deny, {:capability_not_declared, plugin_id, missing}}
    end
  end

  # 代码中引用的新蜜蜂插件模块（文本扫描；AST 级见 Structural 工具）
  defp referenced_modules(code) do
    ~r/Newbee\.(Tools|DEE|Plugins)\.[A-Z][\w.]*/
    |> Regex.scan(code)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end
end
