defmodule Newbee.CLI do
  @moduledoc """
  M1 极简 CLI（codex 式单列流式，DESIGN §5.1）。
  渲染订阅事件总线（§4.6），主循环同步提交；命令走 Newbee.Commands。
  """

  def start do
    client = Newbee.LLM.Config.client_for() |> Map.put(:interrupt_scope, Newbee.LLM.Client.new_interrupt_scope())

    unless client.api_key do
      IO.puts("\e[31m缺少 API key：检查 ~/.newbee/model.json\e[0m")
      System.halt(1)
    end

    IO.puts("\e[1mnewbee\e[0m — 会自我进化的 Elixir 编程 Agent")
    IO.puts("\e[2mmodel: #{client.model} · policy: #{Newbee.Environment.Autonomy.get()} · cwd: #{File.cwd!()}\e[0m")
    IO.puts("命令: #{Enum.join(Newbee.Commands.commands(), " ")}")

    # 预热：假 IP 代理 TLS 握手慢，先建立连接入池复用
    Task.start(fn -> Newbee.LLM.Client.prewarm(client) end)

    Newbee.Bus.subscribe()
    spawn_link(fn -> printer(<<>>) end)

    {evaluator, owned?} = Newbee.Environment.Boot.session_evaluator()

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: evaluator,
        evaluator_owned: owned?,
        auto_antibodies: true,
        render: fn _ -> :ok end
      )

    IO.puts("\e[2msession: #{session_id(kernel)}\e[0m")

    loop(kernel, client)
  end

  # ── 事件打印（独立进程，实时流式） ──

  defp printer(buffer) do
    receive do
      {:newbee_event, :text, {:text, delta}} ->
        printer(buffer_and_print_md(buffer, delta))

      {:newbee_event, :reasoning, {:reasoning, delta}} ->
        buf = flush_buffer(buffer)
        IO.write("[2m" <> delta <> "[0m")
        printer(buf)

      {:newbee_event, :tool_start, {:tool_start, "run_elixir", title, code}} ->
        buf = flush_buffer(buffer)
        line = Newbee.TUI.Cards.tool_header("run_elixir", title) <> (Newbee.TUI.Cards.tool_preview(code) || "")
        IO.puts("
" <> line)
        printer(buf)

      {:newbee_event, :tool_result, {:tool_result, _, text}} ->
        buf = flush_buffer(buffer)
        IO.puts(Newbee.TUI.Cards.tool_footer(text) <> "
")
        printer(buf)

      {:newbee_event, :tool_error, {:tool_error, text}} ->
        buf = flush_buffer(buffer)
        IO.puts(Newbee.TUI.Cards.error_line(text))
        printer(buf)

      {:newbee_event, :file_diff, {:file_diff, path, diff, stats}} ->
        buf = flush_buffer(buffer)
        IO.puts("
")
        Enum.each(Newbee.TUI.Cards.diff_card(path, diff, stats), &IO.puts/1)
        printer(buf)

      {:newbee_event, :permission_ask, {:permission_ask, preview}} ->
        buf = flush_buffer(buffer)
        first = preview |> String.split("
") |> hd() |> String.slice(0, 80)
        IO.puts("
[33m? 允许执行？[y 允许 / 其他拒绝][0m [2m#{first}[0m")
        Newbee.Sound.play(:ask)
        printer(buf)

      {:newbee_event, :advisor_note, {:advisor_note, text}} ->
        buf = flush_buffer(buffer)
        IO.puts("
[38;5;117m\u25C9 advisor[0m #{text}")
        printer(buf)

      {:newbee_event, :worker_hint, {:worker_hint, sig}} ->
        buf = flush_buffer(buffer)
        IO.puts("[2m\u2691 进化线索已记录: #{String.slice(sig, 0, 60)}[0m")
        printer(buf)

      {:newbee_event, :compacted, {:compacted, n}} ->
        buf = flush_buffer(buffer)
        IO.puts("[2m\u23F3 历史已压缩 #{n} 条[0m")
        printer(buf)

      {:newbee_event, :rule_hit, {:rule_hit, hits}} ->
        buf = flush_buffer(buffer)

        Enum.each(hits, fn r ->
          IO.puts("[33m\u2691 沉睡规则命中 [#{r.id}][0m [2m#{r.injection}[0m")
        end)

        printer(buf)

      {:newbee_event, :prompt_injection, {:prompt_injection, details}} ->
        buf = flush_buffer(buffer)
        source = details[:source] || "unknown"
        role = details[:role] || "system"
        timing = details[:timing] || "next_request"
        IO.puts("\n\e[35m◆ Prompt 注入\e[0m source=#{source} role=#{role} timing=#{timing}")
        IO.puts("\e[2m原因: #{details[:reason] || "未说明"}\e[0m")

        if details[:trigger], do: IO.puts("\e[2m触发内容:\n#{details[:trigger]}\e[0m")
        IO.puts("\e[2m实际注入:\n#{details[:content] || ""}\e[0m\n")
        printer(buf)

      {:newbee_event, :audit, {:audit, verdict, actor, target, ring}} ->
        buf = flush_buffer(buffer)
        IO.puts("[2m\u2696 审计: #{verdict} #{actor} \u2192 ring#{ring} #{inspect(target) |> String.slice(0, 60)}[0m")
        printer(buf)

      {:newbee_event, :audit, {:audit, :dangerous_code, hits}} ->
        buf = flush_buffer(buffer)
        IO.puts("[31m\u2696 审计: 危险代码模式 #{inspect(hits)}[0m")
        printer(buf)

      {:newbee_event, :error, {:error, e}} ->
        buf = flush_buffer(buffer)
        IO.puts("\e[31m" <> Newbee.LLM.Client.format_error(e) <> "\e[0m")
        printer(buf)

      {:newbee_event, _, _} ->
        printer(flush_buffer(buffer))
    end
  end

  # ── 行缓冲 Markdown 渲染 ──

  defp buffer_and_print_md(buffer, delta) do
    combined = buffer <> delta

    case String.split(combined, "\n") do
      [_] ->
        combined

      parts ->
        {completed, [remaining]} = Enum.split(parts, -1)

        Enum.each(completed, fn line ->
          IO.write(Newbee.Markdown.render(line) <> "\n")
        end)

        remaining
    end
  end

  defp flush_buffer(<<>>), do: <<>>

  defp flush_buffer(buffer) do
    if String.trim_leading(buffer) != <<>> do
      IO.write(Newbee.Markdown.render(buffer))
    end

    <<>>
  end

  # ── 输入循环 ──

  defp loop(kernel, client) do
    case IO.gets("\e[32m›\e[0m ") do
      nil ->
        :ok

      input ->
        # 权限确认流（§8 ask 档）：kernel 在等待确认时，输入即 y/n 回复
        if Newbee.Agent.Loop.awaiting_permission?(kernel) do
          ok = String.trim(input) in ["y", "Y", "yes", "YES"]
          send(kernel, {:permission_reply, ok})
          IO.puts(if ok, do: "✓ 已允许执行", else: "✗ 已拒绝执行")
          loop(kernel, client)
        else
          ctx = %{say: &IO.puts/1, client: client}

          case Newbee.Commands.handle(input, ctx |> Map.put(:kernel, kernel)) do
            :quit ->
              System.halt(0)

            :ok ->
              loop(kernel, client)

            :handled ->
              loop(kernel, client)

            :new ->
              GenServer.stop(kernel)
              {:ok, kernel2} = new_kernel(client)
              loop(kernel2, client)

            {:resume, id} ->
              {:ok, kernel2} = resume_kernel(client, id)
              loop(kernel2, client)

            {:resume_picker, metas} ->
              print_metas(metas)

              case IO.gets("\e[36m选择编号或 id 前缀（回车取消）›\e[0m ") do
                nil ->
                  loop(kernel, client)

                sel ->
                  sel = String.trim(sel)

                  if sel == "" do
                    loop(kernel, client)
                  else
                    case Newbee.Commands.resolve(sel) do
                      {:ok, id} ->
                        GenServer.stop(kernel)
                        {:ok, kernel2} = resume_kernel(client, id)
                        loop(kernel2, client)

                      {:candidates, ids} ->
                        IO.puts("匹配多个: #{Enum.join(ids, " ")}")
                        loop(kernel, client)

                      :none ->
                        IO.puts("没有匹配的会话")
                        loop(kernel, client)
                    end
                  end
              end

            {:submit, text} ->
              run_submit(kernel, text)
              loop(kernel, client)

            {:image, path, prompt} ->
              run_image_submit(kernel, path, prompt)
              loop(kernel, client)

            {:shell, cmd} ->
              # !shell 命令卡片（与 TUI 一致）
              result = Newbee.Tools.Run.sh(cmd, timeout: 300_000)
              output = String.slice(result.output, 0, 8_000)
              IO.puts("\n" <> Newbee.TUI.Cards.shell_header(cmd))
              Enum.each(String.split(output, "\n"), &IO.puts/1)
              IO.puts(Newbee.TUI.Cards.shell_footer(result))
              loop(kernel, client)
          end
        end
    end
  end

  @doc "恢复会话并进入交互循环（mix newbee -r <id>）。"
  def resume(id) do
    client = Newbee.LLM.Config.client_for() |> Map.put(:interrupt_scope, Newbee.LLM.Client.new_interrupt_scope())
    Newbee.Bus.subscribe()
    spawn_link(fn -> printer(<<>>) end)
    {:ok, kernel} = resume_kernel(client, id)
    loop(kernel, client)
  end

  defp resume_kernel(client, id) do
    {evaluator, owned?} = Newbee.Environment.Boot.session_evaluator(session_id: id)

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: evaluator,
        evaluator_owned: owned?,
        session_id: id,
        auto_antibodies: true,
        render: fn _ -> :ok end
      )

    meta = Newbee.Session.meta(id)
    IO.puts("\e[2m已恢复会话 #{id} · #{meta.messages} 条消息 · #{meta.title}\e[0m")
    IO.puts("\e[2m──── 历史回放 ────\e[0m")

    Newbee.Session.open(id)
    |> Newbee.Session.messages()
    |> Newbee.History.render_lines()
    |> Enum.each(&IO.puts/1)

    IO.puts("\e[2m──── 继续对话 ────\e[0m")
    {:ok, kernel}
  end

  # /new：停掉旧 kernel，以 session_id: nil 起全新会话（全新消息历史与绑定）。
  defp new_kernel(client) do
    {evaluator, owned?} = Newbee.Environment.Boot.session_evaluator()

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: evaluator,
        evaluator_owned: owned?,
        auto_antibodies: true,
        render: fn _ -> :ok end
      )

    IO.puts("\e[2m已开启新会话\e[0m")
    {:ok, kernel}
  end

  defp print_metas(metas) do
    IO.puts("最近会话:")

    Enum.with_index(metas, 1)
    |> Enum.each(fn {m, i} ->
      IO.puts("  [#{i}] #{m.id} · #{m.when_str} · #{m.messages} 条 · #{m.title}")
    end)
  end

  defp run_submit(kernel, text) do
    result =
      case Newbee.Agent.Loop.submit(kernel, text) do
        {:done, summary} ->
          IO.puts("\n\e[1m● \e[0m" <> Newbee.Markdown.render(summary) <> "\n")
          :done

        {:ask, q} ->
          IO.puts("\n\e[33m? \e[0m" <> Newbee.Markdown.render(q) <> "\n")
          :ask

        {:text, _} ->
          IO.puts("")
          :info

        {:error, e} ->
          IO.puts("\e[31merror: #{inspect(e)}\e[0m")
          :error

        {:interrupted, _} ->
          IO.puts("")
          :interrupted

        {:done, summary, _next} ->
          IO.puts("\n\e[1m● \e[0m" <> Newbee.Markdown.render(summary) <> "\n")
          :done

        _other ->
          IO.puts("")
          :info
      end

    Newbee.Sound.play(result)

    # 暂存区有改动时提示
    case Newbee.Staging.list() do
      [] ->
        :ok

      staged ->
        IO.puts("\e[36m◆ #{length(staged)} 项改动待批准:\e[0m")
        IO.puts(Newbee.Staging.render())
        IO.puts("\e[2m/approve 全部落盘 · /reject 丢弃\e[0m")
    end
  end

  defp run_image_submit(kernel, path, prompt) do
    result =
      case Newbee.Agent.Loop.submit_image(kernel, path, prompt) do
        {:done, summary} ->
          IO.puts("\n\e[1m● \e[0m" <> Newbee.Markdown.render(summary) <> "\n")
          :done

        {:ask, q} ->
          IO.puts("\n\e[33m? \e[0m" <> Newbee.Markdown.render(q) <> "\n")
          :ask

        {:text, _} ->
          IO.puts("")
          :info

        {:error, e} ->
          IO.puts("\e[31m图片错误: #{inspect(e)}\e[0m")
          :error

        {:interrupted, _} ->
          IO.puts("")
          :interrupted

        {:done, summary, _next} ->
          IO.puts("\n\e[1m● \e[0m" <> Newbee.Markdown.render(summary) <> "\n")
          :done

        _other ->
          IO.puts("")
          :info
      end

    Newbee.Sound.play(result)
  end

  defp session_id(kernel) do
    :sys.get_state(kernel).session
    |> case do
      nil -> "(off)"
      s -> s.id
    end
  end
end
