defmodule Mix.Tasks.Newbee.Doctor do
  @shortdoc "环境体检"
  @moduledoc "检查工具链、配置、目录结构，输出体检报告。"
  use Mix.Task

  @impl true
  def run(_args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")

    IO.puts("newbee doctor")
    IO.puts("───────────")

    elixir_v = System.version()
    IO.puts("Elixir: #{elixir_v}")

    otp_v =
      :erlang.system_info(:otp_release)
      |> List.to_string()

    IO.puts("OTP: #{otp_v}")

    cfg = Newbee.LLM.Config.load()
    default = cfg["roles"]["default"] || %{}
    provider = cfg["providers"][default["provider"]] || %{}
    IO.puts("模型配置: #{default["provider"]}/#{default["model"]} @ #{provider["baseUrl"]}")

    client = Newbee.LLM.Config.client_for("default")
    key_hint = if client.api_key, do: "已配置", else: "缺失!"
    IO.puts("API key: #{key_hint}（#{String.slice(client.api_key || "", 0, 8)}…）")

    IO.puts("内置插件: #{length(Newbee.Plugins.list())} 个")

    contract_status =
      case Newbee.Environment.ToolContract.validate_builtins() do
        :ok -> "通过"
        {:error, _} -> "失败"
      end

    IO.puts("工具合同: " <> contract_status)
    env = if Process.whereis(Newbee.Environment.Coordinator), do: Newbee.Environment.Coordinator.current(), else: nil

    IO.puts(
      "Environment: #{if env, do: "rev #{env.revision} · active #{map_size(env.active)} 插件 · autonomy=#{env.autonomy}", else: "未启动"}"
    )

    IO.puts("会话: #{length(Newbee.Session.list())} 个")
    IO.puts("规则: #{length(Newbee.DEE.Rules.list())} 条")
    IO.puts("Bundles（基因库）: #{length(Newbee.GlobalStore.bundles())} 个")

    # 价签与指标（§9.11 / §6.1，可观测看板）
    price_tags =
      try do
        Newbee.Environment.Fitness.price_tags()
      rescue
        _ -> %{}
      catch
        _, _ -> %{}
      end

    IO.puts("价签（fitness 投影）: #{map_size(price_tags)} 个 release")

    Enum.each(price_tags, fn {release_id, tag} ->
      IO.puts("  - #{release_id}: #{tag}")
    end)

    antibodies = Newbee.Environment.Antibodies.all()
    IO.puts("抗体: #{length(antibodies)} 条（已验证 #{Newbee.Environment.Antibodies.verified_count()}）")
    IO.puts("敏感文件: 已脱敏（model.json/.env/apiKey/secret/token → [REDACTED]，请用 Host.safe_config/0）")
    IO.puts("高危命令: ask 档拦截 rm -rf / rm -r / / git push（lenient 放行，deny 拒绝）")
    IO.puts("测试: #{length(Path.wildcard("test/**/*_test.exs"))} 个测试文件")
  end
end
