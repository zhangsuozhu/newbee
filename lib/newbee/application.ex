defmodule Newbee.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    ensure_builtin_tool_contracts!()

    # test 环境不自动启动 Coordinator/Daemon（避免污染 cwd 的 .newbee；
    # 测试按需 start_link 并在 tmp 目录运行）
    children =
      [
        Newbee.Bus,
        Newbee.EventLog,
        Newbee.DEE.Rules,
        Newbee.Staging,
        Newbee.Environment.PluginSupervisor,
        Newbee.SessionEvaluators,
        Newbee.Web.Auth.SessionWriter,
        {Registry, keys: :unique, name: Newbee.Web.SessionRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Newbee.Web.SessionSup},
        Newbee.Collaboration.Capability
      ] ++
        if Mix.env() == :test do
          []
        else
          [
            Newbee.Collaboration.Coordinator,
            Newbee.Environment.Coordinator,
            Newbee.Environment.ContextQuality.Collector,
            Newbee.Daemon,
            Newbee.HotReloader
          ]
        end

    # Web 认证/挑战表：由 Application 主进程持有，避免随 Plug 请求进程退出而销毁
    Newbee.Web.Auth.create_table()
    Newbee.Web.WebAuthn.create_table()
    Newbee.Web.Pair.create_table()
    Newbee.Web.QuickAccess.create_table()

    opts = [strategy: :one_for_one, name: Newbee.Supervisor]
    result = Supervisor.start_link(children, opts)

    # 会话索引自愈：启动后异步修补截断的 .index.json（P0）
    if Mix.env() != :test do
      Task.start(fn ->
        try do
          Newbee.Session.repair_index()
        rescue
          _ -> :ok
        end
      end)
    end

    result
  end


  defp ensure_builtin_tool_contracts! do
    case Newbee.Environment.ToolContract.validate_builtins() do
      :ok -> :ok
      {:error, reasons} -> raise "builtin tool contract violation: " <> inspect(reasons)
    end
  end
end
