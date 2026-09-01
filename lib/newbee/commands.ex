defmodule Newbee.Commands do
  @moduledoc """
  CLI/TUI 共用的命令处理 (DESIGN §5.3)。命令对当前 kernel pid 操作；
  /resume 需要重建 kernel ——由调用方传入 restart fun。
  """

  @commands ~w(/model /bindings /tokens /rules /status /dump /resume /reset /approve
    /reject /log /environment /evolve /autonomy /bundles /goal /loop /diff /image
    /undo /session /init /tools /permissions /compact /archive /attach /new /quit)

  def commands, do: @commands

  @doc "处理输入。返回文本提交、图片提交或控制命令。"
  @spec handle(String.t(), map()) ::
          :ok
          | :handled
          | :quit
          | :new
          | {:submit, String.t()}
          | {:image, String.t(), String.t()}
          | {:resume, String.t()}
          | {:resume_picker, list(map())}
          | {:shell, String.t()}
  def handle(input, ctx) do
    case String.trim(input) do
      "" -> :ok
      "/quit" -> :quit
      "!" <> cmd when cmd != "" -> {:shell, cmd}
      "/" <> _ = cmd -> run_command(cmd, ctx)
      text -> {:submit, expand_at_files(text)}
    end
  end

  @doc "执行 !shell 命令并渲染结果（CLI/TUI 共用）。返回输出文本。"
  def run_shell(cmd) do
    result = Newbee.Tools.Run.sh(cmd, timeout: 300_000)
    output = String.slice(result.output, 0, 8_000)

    case result.exit do
      0 -> "⎿ $ #{cmd}\n" <> output
      code -> "⎿ $ #{cmd} (exit #{code})\n" <> output
    end
  end

  @doc "codex 式 @文件语法：@path 展开为文件内容块（≤10KB）。"
  def expand_at_files(text) do
    Regex.replace(~r/@([\w\.\-\/]+)/, text, fn _, path ->
      if File.exists?(path) and File.regular?(path) do
        body = File.read!(path) |> String.slice(0, 10_240)
        "\n\n[文件 #{path}]\n```\n" <> body <> "\n```\n"
      else
        "@" <> path
      end
    end)
  end

  @doc "/resume 选择解析：数字编号（1 起，对应最近会话）或会话 id 精确/前缀。
  返回 {:ok, id} | {:candidates, ids} | :none。"
  def resolve(sel) do
    case Integer.parse(sel) do
      {n, ""} when n >= 1 ->
        case Newbee.Session.list_with_meta(20) |> Enum.at(n - 1) do
          nil -> :none
          meta -> {:ok, meta.id}
        end

      _ ->
        case Newbee.Session.find(sel) do
          [id] -> {:ok, id}
          ids when ids != [] -> {:candidates, ids}
          [] -> :none
        end
    end
  end

  defp run_command(cmd, ctx) do
    [name | rest] = String.split(cmd, " ", parts: 2)
    arg = List.first(rest) || ""
    run(String.trim_leading(name, "/"), arg, ctx)
  end

  defp run("reset", _, ctx) do
    Newbee.DEE.Evaluator.reset()
    ctx.say.("求值器节点已重建（绑定清空，热载工具重新加载）")
    :handled
  end

  defp run("bindings", _, ctx) do
    # 求值路由：EvaluatorPool（generation 路由）优先，具名 Evaluator 兜底
    case Newbee.Environment.EvaluatorPool.current() || Process.whereis(Newbee.DEE.Evaluator) do
      nil ->
        ctx.say.("（求值器未启动）")

      pid ->
        summary =
          if pid == Newbee.Environment.EvaluatorPool.current() do
            Newbee.Environment.EvaluatorPool.bindings_summary(pid)
          else
            Newbee.DEE.Evaluator.bindings_summary(pid)
          end

        case summary do
          [] ->
            ctx.say.("（空）")

          bs ->
            Enum.each(bs, fn b ->
              state_note = if b[:type] == :artifact_ref, do: " [已逐出→ArtifactRef]", else: ""
              ctx.say.("  #{b.name} : #{b.type} (#{b.size} bytes)#{state_note}")
            end)
        end
    end

    :handled
  end

  defp run("tokens", _arg, ctx) do
    usage = Newbee.Agent.Loop.usage(ctx.kernel)
    ctx.say.("usage: #{inspect(usage)}")

    tags =
      try do
        Newbee.Environment.Fitness.price_tags()
      rescue
        _ -> %{}
      end

    if tags != %{} do
      ctx.say.("价签（fitness 投影）:")

      Enum.each(tags, fn {rid, tag} ->
        ctx.say.("  #{rid}: #{tag}")
      end)
    end

    :handled
  end

  defp run("image", arg, ctx) do
    case String.split(String.trim(arg), " ", parts: 2) do
      [path] when path != "" ->
        {:image, path, ""}

      [path, prompt] when path != "" ->
        {:image, path, prompt}

      _ ->
        ctx.say.("用法: /image <图片路径> [补充说明]")
        :handled
    end
  end

  defp run("model", "", ctx) do
    Newbee.LLM.Config.describe() |> Enum.each(&ctx.say.("  " <> &1))
    ctx.say.("autonomy: #{Newbee.Environment.Autonomy.get()} · capability: #{Newbee.Permissions.get()}")
    ctx.say.("用法: /model <provider/model-id> 热切模型（不重启，下一轮即生效）")
    :handled
  end

  defp run("model", id, ctx) when id != "" do
    id = String.trim(id)

    case Newbee.LLM.Config.set_default_model(id) do
      :ok ->
        client = Newbee.LLM.Config.client_for()

        if ctx[:kernel] && Process.alive?(ctx.kernel) do
          case Newbee.Agent.Loop.switch_model(ctx.kernel, client) do
            :ok ->
              ctx.say.("✓ 已热切模型为 #{id}（#{client.model}），下一轮对话即生效，会话/绑定保留")
              :handled

            {:error, reason} ->
              ctx.say.("模型已落盘但热切失败: #{inspect(reason)}，重启后生效")
              :handled
          end
        else
          ctx.say.("已切换默认模型为 #{id}，重启后生效")
          :handled
        end

      {:error, reason} ->
        ctx.say.("切换失败: #{inspect(reason)}（格式：/model <provider>/<model-id> 或 /model <model-id> 保留当前 provider）")

        :handled
    end
  end

  defp run("rules", _, ctx) do
    case Newbee.DEE.Rules.list() do
      [] -> ctx.say.("（无沉睡规则）")
      rules -> Enum.each(rules, &ctx.say.("  [#{&1.id}] /#{&1.pattern}/ → #{&1.injection}"))
    end

    :handled
  end

  defp run("dump", _, ctx) do
    info = Newbee.DEE.Evaluator.info()
    ctx.say.("环境自画像（当前 active 组合树）")
    ctx.say.("  求值器: #{info.mode} #{inspect(info.node)} restarts=#{info.restarts} alive=#{info.alive}")

    if Process.whereis(Newbee.Environment.Coordinator) do
      env = Newbee.Environment.Coordinator.current()
      ctx.say.("  revision: #{env.revision} · checkpoint #{env.checkpoint} · autonomy #{env.autonomy}")
      ctx.say.("  active releases:")

      Enum.each(env.active, fn {plugin_id, release_id} ->
        tag =
          try do
            Newbee.Environment.Fitness.price_tag(release_id)
          rescue
            _ -> nil
          end

        ctx.say.("    #{plugin_id} @ #{release_id}#{if tag, do: " · " <> tag, else: ""}")
      end)

      if env.degraded != [] do
        ctx.say.("  ⚠ degraded revisions: #{inspect(env.degraded)}")
      end
    else
      ctx.say.("  Coordinator 未启动（无环境状态）")
    end

    ctx.say.("  沉睡规则: #{length(Newbee.DEE.Rules.list())} 条")
    ctx.say.("  会话: #{inspect(Newbee.Session.list() |> Enum.take(5))}")
    :handled
  end

  defp run("status", _, ctx) do
    ctx.say.(Newbee.Status.render(ctx[:client]))
    :handled
  end

  defp run("resume", "", _ctx) do
    {:resume_picker, Newbee.Session.list_with_meta(20)}
  end

  defp run("resume", id, _ctx) do
    id = String.trim(id)

    case Newbee.Session.find(id) do
      # 精确或唯一前缀 → 返回完整 id（会话恢复用）
      [found] -> {:resume, found}
      # 无匹配：原样透传（kernel 会报错提示）
      [] -> {:resume, id}
    end
  end

  # /new（codex 式）：开启全新会话。由调用方（CLI/TUI）停掉当前 kernel、
  # 以 session_id: nil 重建——消息历史与绑定都不带入新会话。
  defp run("new", _arg, _ctx) do
    :new
  end

  defp run("approve", arg, ctx) do
    arg = String.trim(arg)

    cond do
      # /approve <change_id>：manual 档下激活待批 Change（§8.1 授权事件）
      String.starts_with?(arg, "chg_") ->
        if Process.whereis(Newbee.Environment.Coordinator) do
          case Newbee.Environment.Coordinator.approve(arg) do
            :ok -> ctx.say.("✓ Change #{arg} 已激活（授权事件已入 Event Store）")
            {:error, reason} -> ctx.say.("激活失败: #{inspect(reason)}")
          end
        else
          ctx.say.("Coordinator 未启动")
        end

        :handled

      # /approve pending：列出待批 Change
      arg == "pending" ->
        if Process.whereis(Newbee.Environment.Coordinator) do
          pending =
            Newbee.Environment.Coordinator.changes()
            |> Enum.filter(&(&1.status in [:canary, :evaluating] and &1.evaluation_result != nil))

          if pending == [] do
            ctx.say.("（无待批 Change）")
          else
            Enum.each(pending, fn c ->
              ctx.say.("  #{c.change_id} [#{c.status}] #{c.reason} — /approve #{c.change_id} 激活")
            end)
          end
        end

        :handled

      true ->
        approve_staging(arg, ctx)
    end
  end

  defp run("reject", arg, ctx) do
    id = if arg == "", do: :all, else: String.to_integer(arg)

    try do
      case Newbee.Staging.reject(id) do
        {:ok, []} -> ctx.say.("（无暂存改动）")
        {:ok, dropped} -> ctx.say.("已丢弃: #{Enum.join(dropped, ", ")}")
        {:error, :not_staged} -> ctx.say.("没有对应暂存项")
        {:error, other} -> ctx.say.("reject 失败: #{inspect(other)}")
      end
    rescue
      e -> ctx.say.("reject 异常: #{inspect(e)}")
    catch
      :exit, reason -> ctx.say.("reject 超时: #{inspect(reason)}")
    end

    :handled
  end

  defp run("diff", _arg, ctx) do
    case System.cmd("git", ["diff", "--stat", "HEAD"], stderr_to_stdout: true) do
      {out, 0} when out != "" -> ctx.say.(String.trim(out) |> String.slice(0, 2_000))
      {_, 0} -> ctx.say.("（无改动）")
      {_, _} -> ctx.say.("git diff 不可用（非 git 仓库？）")
    end

    :handled
  end

  defp run("log", arg, ctx) do
    lines = Newbee.DebugLog.tail(if arg == "", do: 50, else: String.to_integer(arg))
    Enum.each(lines, &ctx.say.("  " <> &1))
    :handled
  end

  # /environment（§10）：版本图 / 回退。兼容映射旧 /snapshot /rollback。
  defp run("environment", arg, ctx) do
    [sub | rest] = String.split(String.trim(arg), " ", parts: 2)
    sub_arg = List.first(rest) || ""

    unless Process.whereis(Newbee.Environment.Coordinator) do
      ctx.say.("Coordinator 未启动")
      throw(:handled)
    end

    case sub do
      "revisions" ->
        revs = Newbee.Environment.Coordinator.revisions()
        current = Newbee.Environment.Coordinator.current()

        if revs == [] do
          ctx.say.("（无历史 revision——环境尚未变更）")
        else
          ctx.say.("版本图（当前 rev #{current.revision}）:")

          Enum.each(revs, fn r ->
            marker = if r["rev"] == current.revision, do: "▶", else: " "

            ctx.say.(
              " #{marker} rev #{r["rev"]} [#{r["health"]}] #{map_size(r["active"])} 插件 · change #{r["change_id"]} · #{r["created_at"]}"
            )
          end)
        end

      "rollback" ->
        case Integer.parse(String.trim(sub_arg)) do
          {n, ""} ->
            case Newbee.Environment.Coordinator.rollback({:revision, n}, "user /environment rollback #{n}") do
              {:ok, change} ->
                ctx.say.("已回退到 rev #{n}（change #{change.change_id}；回退只动环境指针，外部副作用不在恢复范围，§12）")

              {:error, reason} ->
                ctx.say.("回退失败: #{inspect(reason)}")
            end

          _ ->
            ctx.say.("用法: /environment rollback <rev>（/environment revisions 查看版本图）")
        end

      "" ->
        env = Newbee.Environment.Coordinator.current()
        ctx.say.("Environment: rev #{env.revision} · active #{map_size(env.active)} 插件 · autonomy #{env.autonomy}")
        ctx.say.("用法: /environment revisions · /environment rollback <rev>")

      other ->
        ctx.say.("未知子命令: #{other}（revisions | rollback <rev>）")
    end

    :handled
  catch
    :handled -> :handled
  end

  # 兼容映射：/snapshot → /environment revisions；/rollback <rev> → /environment rollback
  defp run("snapshot", _arg, ctx), do: run("environment", "revisions", ctx)
  defp run("rollback", arg, ctx), do: run("environment", "rollback " <> arg, ctx)

  defp run("evolve", hint, ctx) do
    if hint != "" do
      # /evolve <描述>：向 Adapter 投递 need（§10）
      {:ok, mid} = Newbee.Agent.Protocol.need(hint, sender: "user", urgency: :normal)
      ctx.say.("已投递 need（#{mid}）")
    end

    ctx.say.("adapter 开始一轮（need 消息 + JIT 热度 → 合成 → Verifier 门 → Autonomy 判定）…")

    case Newbee.Agent.Adapter.run_once() do
      {:skipped, reason} ->
        ctx.say.("跳过: #{reason}")

      {:error, reason} ->
        ctx.say.("失败: #{inspect(reason)}")

      {:suggested, proposals} ->
        ctx.say.("进化建议（autonomy=observe，未激活；/autonomy manual|autonomous 后过门才激活）:")

        Enum.each(proposals, fn p ->
          ctx.say.("  💡 #{p["type"]} #{p["id"] || p["name"] || inspect(p)}")
        end)

      {:processed, results} ->
        Enum.each(results, fn
          {:ok, change_id} -> ctx.say.("  📦 Change #{change_id} 已进入评测（/environment revisions 跟踪）")
          {:error, reason} -> ctx.say.("  ❌ #{inspect(reason)}")
        end)
    end

    :handled
  end

  defp run("init", _, ctx) do
    if File.exists?("NEWBEE.md") do
      ctx.say.("NEWBEE.md 已存在（跳过；删除后可重新生成）")
    else
      map = Newbee.Plugins.RepoMap.build(".")

      common =
        if File.exists?("mix.exs") do
          "- 测试: mix test\n- 编译: mix compile\n- 格式化: mix format"
        else
          "- 测试/编译: 按项目语言运行（例如 cargo test、pytest、go test）"
        end

      content =
        "# NEWBEE.md\n\n## 项目说明\n（由 newbee /init 生成，可编辑——本文件会被注入会话 prompt，§5.4）\n\n## 工程结构\n" <>
          map <>
          "\n\n## 常用命令\n" <> common <> "\n"

      File.write!("NEWBEE.md", content)
      ctx.say.("已生成 NEWBEE.md（会注入会话 prompt；同样支持 AGENTS.md / CLAUDE.md）")
    end

    :handled
  end

  defp run("tools", "", ctx) do
    # 插件库（§10）：含各 release 价签/fitness
    ctx.say.("插件库:")

    tags =
      try do
        Newbee.Environment.Fitness.price_tags()
      rescue
        _ -> %{}
      end

    active =
      if Process.whereis(Newbee.Environment.Coordinator) do
        Newbee.Environment.Coordinator.current().active
      else
        %{}
      end

    Enum.each(Newbee.Plugins.list(), fn t ->
      release_id = active[t.plugin_id]
      tag = if release_id, do: tags[release_id], else: nil
      state = if release_id, do: "active", else: "builtin"
      ctx.say.("  [#{t.kind}] #{t.plugin_id} (#{state})#{if tag, do: " " <> tag, else: ""}: #{t.summary}")
    end)

    ctx.say.("/tools <模块名> 看详情；按需 Newbee.read(\"tool://模块名\") 取全文")
    :handled
  end

  defp run("tools", name, ctx) do
    case Newbee.Plugins.describe(String.trim(name)) do
      %{name: n, summary: sum, plugin_id: pid} ->
        ctx.say.("#{n} [#{pid}]: #{sum}")

        mod = Newbee.Plugins.module_for(name)

        if mod do
          case :code.which(mod) do
            path when is_binary(path) or is_list(path) ->
              ctx.say.("  源码: #{if is_list(path), do: List.to_string(path), else: path}")

            _ ->
              :ok
          end
        end

      nil ->
        ctx.say.("未找到插件: #{name}")
    end

    :handled
  end

  defp run("permissions", "", ctx) do
    ctx.say.(
      "当前权限档位: #{Newbee.Permissions.get()}（可选: #{inspect(Newbee.Permissions.levels())}；lenient 放行+审计 / ask 危险操作询问 / deny 危险操作拒绝）"
    )

    :handled
  end

  defp run("permissions", arg, ctx) do
    level = String.to_atom(String.trim(arg))

    if level in Newbee.Permissions.levels() do
      Newbee.Permissions.set(level)
      ctx.say.("权限档位: #{level}")
    else
      ctx.say.("非法档位，可选: #{inspect(Newbee.Permissions.levels())}")
    end

    :handled
  end

  defp run("compact", _, ctx) do
    if ctx.kernel do
      case Newbee.Agent.Loop.compact(ctx.kernel) do
        {:ok, n} -> ctx.say.("已压缩 #{n} 条历史（环境状态与绑定不受影响，§5.3/§6.5）")
        {:error, e} -> ctx.say.("压缩失败: #{inspect(e)}")
      end
    else
      ctx.say.("（无 kernel 上下文）")
    end

    :handled
  end

  # /archive [关键词]：会话档案索引 / 全文检索（压缩历史的分层视图 + 检索入口，§6.6）
  defp run("archive", arg, ctx) do
    query = String.trim(arg)
    path = if query == "", do: "history://", else: "history://q/" <> query

    case Newbee.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.take(30)
        |> Enum.each(&ctx.say.(&1))

      {:error, e} ->
        ctx.say.("档案读取失败: #{inspect(e)}")
    end

    :handled
  end

  # ── 自主目标（/goal）：Kernel 已内置 set_goal/clear_goal/goal，这里接线 ──

  defp run("goal", arg, ctx) do
    if ctx.kernel do
      arg = String.trim(arg)
      cond do
        arg == "" or arg == "status" ->
          case Newbee.Agent.Loop.goal(ctx.kernel) do
            nil ->
              ctx.say.("（无自主目标）用法: /goal <目标> [--budget N] [--max-rounds N] | /goal pause|resume|clear|edit <新目标>|budget <N>")

            g ->
              budget = if g.token_budget, do: "#{g.tokens_used}/#{g.token_budget}", else: "#{g.tokens_used}/∞"
              ctx.say.("自主目标 [#{g.status}]: #{g.text}（#{g.rounds}/#{g.max_rounds} 轮 · budget #{budget} · idle #{g.idle}）")
              if g.status == :budget_limited, do: ctx.say.("  ⚠ 已达预算上限，已注入收尾提示；/goal budget <N> 可提升预算")
              if g.status == :blocked, do: ctx.say.("  ⛔ 三击阻塞，需 /goal resume 或 /goal edit")
          end

        arg == "clear" ->
          Newbee.Agent.Loop.clear_goal(ctx.kernel)
          ctx.say.("自主目标已取消")

        arg == "pause" ->
          case Newbee.Agent.Loop.set_goal_status(ctx.kernel, :paused) do
            :ok -> ctx.say.("已暂停自主目标")
            {:error, e} -> ctx.say.("暂停失败: #{inspect(e)}")
          end

        arg == "resume" ->
          case Newbee.Agent.Loop.set_goal_status(ctx.kernel, :active) do
            :ok -> ctx.say.("已恢复自主目标，继续推进")
            {:error, e} -> ctx.say.("恢复失败: #{inspect(e)}")
          end

        String.starts_with?(arg, "edit ") ->
          text = String.trim_leading(arg, "edit ") |> String.trim()
          case Newbee.Agent.Loop.update_goal(ctx.kernel, text) do
            :ok -> ctx.say.("已更新目标: #{text}")
            {:error, e} -> ctx.say.("更新失败: #{inspect(e)}")
          end

        String.starts_with?(arg, "budget ") ->
          b = String.trim_leading(arg, "budget ") |> String.trim()
          case Newbee.Agent.Loop.set_goal_budget(ctx.kernel, b) do
            :ok -> ctx.say.("已调整预算: #{b}")
            {:error, e} -> ctx.say.("调整失败: #{inspect(e)}")
          end

        true ->
          {text, opts} = parse_goal_args(arg)
          case Newbee.Agent.Loop.set_goal(ctx.kernel, text, opts) do
            :ok ->
              budget_hint = if opts[:token_budget], do: " budget=#{opts[:token_budget]}", else: ""
              ctx.say.("已启动自主目标#{budget_hint}（异步运行；/goal 查看状态 · /goal clear 取消）")

            {:error, reason} ->
              ctx.say.("启动失败: #{inspect(reason)}")
          end
      end
    else
      ctx.say.("（无 kernel 上下文，/goal 不可用）")
    end

    :handled
  end


  defp run("loop", arg, ctx) do
    if ctx.kernel do
      arg = String.trim(arg)
      if arg == "" do
        ctx.say.("用法: /loop <任务描述> [--iterations N] [--budget TOKENS]  (N≤20)")
      else
        {task, opts} = parse_loop_args(arg)
        # If goal active, hint
        case Newbee.Agent.Loop.goal(ctx.kernel) do
          %{status: :active} -> ctx.say.("⚠ 已有 active goal，loop 将与之并行；建议先 /goal pause")
          _ -> :ok
        end
        case Newbee.Agent.Loop.loop(ctx.kernel, task, opts) do
          {:done, summary} -> ctx.say.("Loop 完成: #{summary}")
          {:ask, q} -> ctx.say.("Loop 需要提问: #{q}")
          {:loop_done, n} -> ctx.say.("Loop 完成 #{n} 轮（未调用 done）")
          {:loop_budget, n} -> ctx.say.("Loop 预算触顶 (#{n} tokens)")
          {:error, e} -> ctx.say.("Loop 失败: #{inspect(e)}")
          other -> ctx.say.("Loop 结果: #{inspect(other)}")
        end
      end
    else
      ctx.say.("（无 kernel 上下文，/loop 不可用）")
    end
    :handled
  end



  # ── /undo：回退到上一 revision（§10：环境版本回退只恢复环境自身）──

  defp run("undo", _, ctx) do
    if Process.whereis(Newbee.Environment.Coordinator) do
      current = Newbee.Environment.Coordinator.current()

      if current.revision >= 1 do
        case Newbee.Environment.Coordinator.rollback({:revision, current.revision - 1}, "user /undo") do
          {:ok, change} ->
            ctx.say.("已回退到 rev #{current.revision - 1}（change #{change.change_id}）")
            ctx.say.("注意：回退只恢复环境自身；已发生的外部副作用不在恢复范围（§12 可逆性分级）")

          {:error, reason} ->
            ctx.say.("回退失败: #{inspect(reason)}")
        end
      else
        ctx.say.("（已在最早 revision，无可回退）")
      end
    else
      ctx.say.("Coordinator 未启动")
    end

    :handled
  end

  # ── /session：会话挂起/恢复（§5.3）──

  defp run("session", arg, ctx) do
    [cmd | rest] = String.split(String.trim(arg), " ", parts: 2)

    case cmd do
      "" ->
        case current_session(ctx.kernel) do
          nil ->
            ctx.say.("（无会话——kernel 以 session: false 启动）")

          s ->
            ctx.say.("当前会话: #{s.id}（/session save 固化绑定 · /session list 列出 · /session load <id> 恢复）")
        end

        :handled

      "save" ->
        case current_session(ctx.kernel) do
          nil ->
            ctx.say.("（无会话）")

          s ->
            binding = Newbee.DEE.Evaluator.dump_bindings()
            Newbee.Session.save_bindings(s, binding)
            ctx.say.("已保存会话 #{s.id} 的绑定快照（#{length(binding)} 个变量）")
        end

        :handled

      "list" ->
        {:resume_picker, Newbee.Session.list_with_meta(20)}

      "load" ->
        case rest do
          [id] -> {:resume, String.trim(id)}
          [] -> {:resume_picker, Newbee.Session.list_with_meta(20)}
        end

      other ->
        # 裸 id 直接恢复（/session <id> 等价 /resume <id>）
        {:resume, other}
    end
  end

  # /autonomy（§8.1）：Autonomy 档位 observe/manual/autonomous/emergency_stop。
  # 自治是挣来的：升 autonomous 前先检查证据，不足则提示（仍允许强制，但如实告知）。
  defp run("autonomy", arg, ctx) do
    alias Newbee.Environment.Autonomy

    case String.trim(arg) do
      "" ->
        ctx.say.("当前档位: #{Autonomy.get()}（可选: #{inspect(Autonomy.levels())}）")
        ctx.say.("  observe 只建议 · manual 过门后需 /approve · autonomous 自动激活 · emergency_stop 冻结")

      "emergency_stop" ->
        Newbee.Host.Shell.emergency_stop()
        ctx.say.("⛔ emergency_stop：环境变更已冻结，仅允许回退")

      "autonomous!" ->
        Autonomy.set(:autonomous)
        ctx.say.("已强制升 autonomous（安全网厚度不足，风险自负）")

      level_str ->
        level = String.to_atom(level_str)

        cond do
          level not in Autonomy.levels() ->
            ctx.say.("非法档位，可选: #{inspect(Autonomy.levels())}")

          level == :autonomous ->
            evidence =
              if Process.whereis(Newbee.Environment.Coordinator) do
                Newbee.Environment.Coordinator.autonomy_evidence()
              else
                %{verified_antibodies: 0, replay_coverage: 0.0, recent_changes: []}
              end

            if Autonomy.suggest_upgrade?(evidence) do
              Autonomy.set(:autonomous)

              ctx.say.(
                "✓ 安全网足够厚（已验证抗体 #{evidence.verified_antibodies}，回放覆盖 #{evidence.replay_coverage}）——已升 autonomous"
              )
            else
              ctx.say.("⚠ 自治是挣来的（§8.1）：当前证据 已验证抗体=#{evidence.verified_antibodies} 回放覆盖=#{evidence.replay_coverage}")
              ctx.say.("  未达建议阈值。确认仍要升级请再输入: /autonomy autonomous!")
            end

          true ->
            Autonomy.set(level)
            ctx.say.("Autonomy 档位: #{level}")
        end
    end

    :handled
  end

  # 兼容映射：/policy → /autonomy
  defp run("policy", arg, ctx), do: run("autonomy", arg, ctx)

  defp run("bundles", _, ctx) do
    case Newbee.GlobalStore.bundles() do
      [] ->
        ctx.say.("（基因库为空；P5：L3 工具+规则+prompt 打成 bundle 带 fitness 跨用户分享）")

      bundles ->
        Enum.each(
          bundles,
          &ctx.say.(
            "  #{&1["name"]}@#{&1["version"]} releases=#{length(&1["releases"] || [])} from=#{inspect(&1["provenance"])}"
          )
        )
    end

    :handled
  end

  # 兼容映射
  defp run("genes", arg, ctx), do: run("bundles", arg, ctx)

  defp run("bench", _, ctx) do
    ctx.say.("公开基准请用 mix 任务: mix newbee.bench（抗体回放 + 任务集）")
    :handled
  end

  defp run("attach", _, ctx) do
    ctx.say.("daemon 常驻中；重连请退出后运行: newbee attach（TUI 只是探视窗，§4.1）")
    :handled
  end

  defp run(unknown, _, ctx) do
    ctx.say.("未知命令: /#{unknown}（#{Enum.join(@commands, " ")}）")
    :handled
  end

  defp approve_staging(arg, ctx) do
    id = if arg == "", do: :all, else: String.to_integer(arg)

    try do
      case Newbee.Staging.approve(id) do
        {:ok, []} -> ctx.say.("（无暂存改动）")
        {:ok, written} -> ctx.say.("已落盘: #{Enum.join(written, ", ")}")
        {:error, :not_staged} -> ctx.say.("没有对应暂存项")
        {:error, {:outside_project, msg}} -> ctx.say.("有暂存项在工程树外，已拒绝落盘: #{msg}")
        {:error, :outside_project} -> ctx.say.("有暂存项在工程树外，已拒绝落盘")
        {:error, other} -> ctx.say.("approve 失败: #{inspect(other)}（暂存保留）")
      end
    rescue
      e -> ctx.say.("approve 异常: #{inspect(e)}（TUI 未退出，暂存保留）")
    catch
      :exit, reason -> ctx.say.("approve 超时: #{inspect(reason)}（TUI 未退出，暂存保留）")
    end

    :handled
  end

  defp current_session(nil), do: nil

  defp current_session(kernel) do
    case :sys.get_state(kernel) do
      %{session: %Newbee.Session{} = s} -> s
      _ -> nil
    end
  end

  defp parse_goal_args(arg) do
    # 支持尾缀 --budget N 和 --max-rounds N
    {text, budget} = case Regex.run(~r/^(.*)\s+--budget\s+(\d+)\s*$/, arg) do
      [_, t, b] -> {String.trim(t), String.to_integer(b)}
      _ -> {arg, nil}
    end
    {text, max_rounds} = case Regex.run(~r/^(.*)\s+--max-rounds\s+(\d+)\s*$/, text) do
      [_, t, n] -> {String.trim(t), String.to_integer(n)}
      _ -> {text, nil}
    end
    opts = []
    opts = if budget, do: Keyword.put(opts, :token_budget, budget), else: opts
    opts = if max_rounds, do: Keyword.put(opts, :max_rounds, max_rounds), else: opts
    {text, opts}
  end

  defp parse_loop_args(arg) do
    {task, it} = case Regex.run(~r/^(.*)\s+--iterations\s+(\d+)\s*$/, arg) do
      [_, t, n] -> {String.trim(t), String.to_integer(n)}
      _ -> {arg, nil}
    end
    {task, budget} = case Regex.run(~r/^(.*)\s+--budget\s+(\d+)\s*$/, task) do
      [_, t, b] -> {String.trim(t), String.to_integer(b)}
      _ -> {task, nil}
    end
    opts = []
    opts = if it, do: Keyword.put(opts, :iterations, it), else: opts
    opts = if budget, do: Keyword.put(opts, :token_budget, budget), else: opts
    {task, opts}
  end
end