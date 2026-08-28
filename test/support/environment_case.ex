defmodule Newbee.EnvironmentCase do
  @moduledoc """
  环境测试基座：tmp 项目目录 + File.cd!（Store 以 cwd 为项目根）。

  ⚠️ File.cwd 是 VM 全局——用此基座的测试必须 async: false。
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Newbee.EnvironmentCase
    end
  end

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "newbee_env_#{System.system_time(:native)}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    original_cwd = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      # File.cwd! 是 VM 全局：后续用例可能已 cd 走，只有当前 cwd 仍是本用例 tmp 时才回退，
      # 否则会把别的用例的工作目录劫持回主仓库
      if File.cwd!() == tmp do
        File.cd!(original_cwd)
      end

      File.rm_rf(tmp)
    end)

    # 无论测试内部是否重启过 Coordinator，退出时按名字兜底停止（防泄漏）
    on_exit(fn ->
      case Process.whereis(Newbee.Environment.Coordinator) do
        nil -> :ok
        pid -> Newbee.EnvironmentCase.stop_coordinator(pid)
      end
    end)

    {:ok, project_dir: tmp}
  end

  @doc "启动具名 Coordinator（默认名，供 CapabilityGate/Worker 等全局引用）。"
  def start_coordinator!(opts \\ []) do
    # 测试要求干净实例：残留的旧 Coordinator 持有已删除 tmp 目录的路径，
    # 复用会导致 write_atomic! ENOENT 崩溃 → 先停旧的再起新的
    case Process.whereis(Newbee.Environment.Coordinator) do
      nil ->
        :ok

      stale ->
        Newbee.EnvironmentCase.stop_coordinator(stale)
        Process.sleep(50)
    end

    {:ok, pid} = Newbee.Environment.Coordinator.start(Keyword.put_new(opts, :autonomy, :manual))
    pid
  end

  def stop_coordinator(pid) do
    if Process.alive?(pid) do
      # 正常停 3s；卡在长 call（如 materialize 60s）则强杀，
      # 否则进程活着时后续 rm_rf(tmp) 会让它写已删目录而崩溃
      case GenServer.stop(pid, :normal, 3_000) do
        :ok -> :ok
        _ -> Process.exit(pid, :kill)
      end
    end

    Newbee.Events.unregister_store()
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "一个符合 ToolContract 的合法 tool release 源码。"
  def tool_source(mod_name \\ "DemoTool", plugin_id \\ "tool.demo") do
    """
    defmodule Newbee.Plugins.#{mod_name} do
      @moduledoc "Demo deterministic tool.\n\n## 可跑示例\n    Newbee.Plugins.#{mod_name}.hello()"
      @behaviour Newbee.Environment.PluginContract

      @impl true
      def id, do: "#{plugin_id}"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def dependencies, do: []
      @impl true
      def describe do
        %{
          kind: :tool,
          summary: "Demo deterministic tool",
          when_to_use: "environment lifecycle tests need a harmless tool",
          avoid_when: "do not use outside tests",
          capabilities: [],
          effects: [],
          error_contract: %{recoverable: :none, unexpected: :raise},
          api: [%{name: :hello, arity: 0, returns: ":world", errors: "none"}],
          examples: ["Newbee.Plugins.#{mod_name}.hello()"]
        }
      end

      @doc "Return :world."
      def hello, do: :world
    end
    """
  end

  @doc "一个合法的 rule release 源码。"
  def rule_source(id \\ "demo", pattern \\ "foo", injection \\ "别写 foo") do
    slug = String.replace(id, ~r/[^a-z0-9]/, "_")

    """
    defmodule Newbee.Plugins.Rules.#{Macro.camelize(slug)} do
      @moduledoc "demo rule"
      @behaviour Newbee.Environment.PluginContract

      @impl true
      def id, do: "rule.#{slug}"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def describe, do: %{kind: :rule, pattern: #{inspect(pattern)}, injection: #{inspect(injection)}, scope: :all}
      @impl true
      def dependencies, do: []
    end
    """
  end
end
