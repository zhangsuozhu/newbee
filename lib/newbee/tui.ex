defmodule Newbee.TUI do
  @moduledoc """
  codex 式单列流式 TUI (DESIGN §5.1/§5.2)：全屏 ANSI 渲染。
  布局：上方滚动输出区 + 底部分隔线 + 输入行 + 状态栏。

  架构（M6 重写）：
  - Newbee.TUI.Key    按键解码（转义序列/UTF-8/粘贴）
  - Newbee.TUI.Line   行编辑（双宽光标/历史/横向滚动/Tab 补全）
  - Newbee.TUI.Screen 双缓冲渲染（diff 重画，无闪烁）
  - Newbee.Markdown   markdown 渲染（done/ask 摘要）

  终端底层（零 C 依赖的唯一可行组合）：
  - elixir wrapper 以 `erl -noshell` 启动：BEAM stdin=/dev/null 且失去 ctty，
    子进程 stty / /dev/tty 全部不可用；raw 模式由外层启动脚本预设
    （`stty raw -echo` + trap 恢复），见 bin/newbee
  - 按键经 IO.getn 走 BEAM tty_sl 端口读入，逐字节即时返回

  交互（对齐 codex / pi）：
  - Enter 发送 · `\` 续行 · ↑/↓ 历史 · Tab 补全（@路径 / 命令）
  - Esc 中断模型执行 · Ctrl-C 清输入/退出 · Ctrl-L 重绘
  - PgUp/PgDn 翻屏 · Ctrl-O 展开/折叠工具块
  """

  alias Newbee.TUI.{Key, Line, Screen}

  defstruct lines: [],
            line_ed: %Line{},
            kernel: nil,
            client: nil,
            busy: false,
            submit_pid: nil,
            submit_kind: nil,
            pending_inputs: [],
            picker: nil,
            screen: nil,
            page: 0,
            streaming: false,
            stream_kind: nil,
            render_pending: false,
            tool_blocks: %{},
            last_block_id: nil,
            think_block_id: nil,
            think_lines: %{},
            show_reasoning: true,
            expanded: %{},
            usage: %{},
            pane: nil,
            out: nil,
            awaiting_permission: false,
            text_buffer: <<>>,
            last_paint: 0,
            bindings_cache: [],
            bindings_cache_at: 0,
            spinner_idx: 0,
            turn_started_at: nil,
            shell_started_at: nil,
            search_mode: false,
            search_query: "",
            search_idx: 0,
            search_orig: "",
            turns: 0,
            steps: 0,
            llm_ms: 0,
            tool_ms: 0,
            llm_step_start: nil,
            tool_step_start: nil,
            awaiting_first_token: false,
            ft_sum_ms: 0,
            ft_count: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            cached_tokens: 0,
            cache_write_tokens: 0,
            uncached_prompt_tokens: 0

  @scrollback 5_000

  def start do
    client = Newbee.LLM.Config.client_for() |> Map.put(:interrupt_scope, Newbee.LLM.Client.new_interrupt_scope())

    unless client.api_key do
      IO.puts("\e[31m缺少 API key：检查 ~/.newbee/model.json\e[0m")
      System.halt(1)
    end

    unless tty?() do
      IO.puts("\e[31mTUI 需要真实终端（tty）。请直接运行 mix newbee 使用 CLI。\e[0m")
      System.halt(1)
    end

    Task.start(fn -> Newbee.LLM.Client.prewarm(client) end)
    Newbee.Bus.subscribe()

    {evaluator, owned?} = Newbee.Environment.Boot.session_evaluator()

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: evaluator,
        evaluator_owned: owned?,
        auto_antibodies: true,
        render: fn _ -> :ok end
      )

    # 输出走独立 fd 端口：IO.getn 挂起时 group leader 会排队所有输出
    # （"不输入就不输出"的根因），端口直写 tty 与输入解耦。
    out = Screen.open_port()

    # 备用屏 + 隐藏光标 + 括号粘贴模式（粘贴不再被逐键解释）
    Port.command(out, "\e[?1049h\e[?25l\e[?2004h")

    hist = Newbee.TUI.History.load()

    state = %__MODULE__{
      kernel: kernel,
      client: client,
      out: out,
      line_ed: %Line{hist: hist, hcur: length(hist)}
    }

    state =
      state
      |> push_line("\e[1mnewbee\e[0m TUI - #{client.model} · policy=#{Newbee.Environment.Autonomy.get()}")
      |> push_line("\e[2m命令: #{Enum.join(Newbee.Commands.commands(), " ")}\e[0m")
      |> push_line(
        "\e[2m↑↓ 历史 · Ctrl-R 搜历史 · PgUp/PgDn 翻屏 · Tab 补全 · Ctrl-O 展开代码 · Esc 中断 · Ctrl-C 退出 · Ctrl-L 重绘 · Ctrl-T 窗格/队列\e[0m"
      )
      |> push_line("\e[2msession: #{session_id(kernel)}\e[0m")

    parent = self()
    # 字节泵（独占阻塞读）+ 事件 reader（receive 驱动）：
    # reader 的 50ms 空闲超时消歧孤立 ESC——Esc 中断才能即时响应。
    # 泵必须把原始字节发给 reader，而不是发给 TUI 主循环；主循环只接收
    # reader 解码后的 {:key, ...} 事件，否则输入会被静默丢弃。
    reader = spawn_link(fn -> reader_loop(parent, <<>>, :normal, <<>>) end)
    spawn_link(fn -> pump(reader) end)

    try do
      loop(paint(state, true), reader)
    after
      # reader 此刻可能仍阻塞在 IO.getn：绝不能用 IO.write（会死锁到下一按键）
      Port.command(out, "\e[?2004l\e[?25h\e[?1049l")
      Newbee.Bus.unsubscribe()
    end
  end

  # ── 输入：字节泵 + 事件 reader（tty_sl 字节 -> 事件）──

  # 字节泵：独占阻塞读（IO.getn），字节即时消息化发给 reader。
  # 与 reader 分离后，reader 才能用 receive-timeout 消歧孤立 ESC。
  defp pump(parent) do
    case IO.getn("", 1) do
      :eof ->
        send(parent, {:tty_eof, :ok})

      {:error, _} ->
        :ok

      ch ->
        send(parent, {:tty, ch})
        pump(parent)
    end
  end

  # paste 态：累积可打印字符，直到 :paste_end
  defp reader_loop(parent, buf, :paste, paste_buf) do
    receive do
      {:tty, ch} ->
        {events, rest} = Key.feed(buf, ch)

        {paste_buf, events} =
          Enum.reduce(events, {paste_buf, []}, fn ev, {acc, evs} ->
            case ev do
              {:key, cp} when is_integer(cp) -> {acc <> <<cp::utf8>>, evs}
              :paste_end -> {acc, evs ++ [{:paste_done, acc}]}
              _ -> {acc, evs}
            end
          end)

        Enum.each(events, fn
          {:paste_done, text} -> send(parent, {:paste, text})
          other -> send(parent, other)
        end)

        if :lists.keymember(:paste_done, 1, events) do
          reader_loop(parent, rest, :normal, <<>>)
        else
          reader_loop(parent, rest, :paste, paste_buf)
        end

      {:tty_eof, :ok} ->
        send(parent, {:paste, paste_buf})
    end
  end

  defp reader_loop(parent, buf, :normal, _) do
    # 缓冲里只有孤立 ESC 时启用 50ms 空闲超时（xterm 同款消歧）：
    # 无后续字节 → 裸 Esc（中断即时响应）；有后续字节（方向键等）→ 正常解析
    timeout = if buf == <<27>>, do: 50, else: :infinity

    receive do
      {:tty, ch} ->
        {events, rest} = Key.feed(buf, ch)

        Enum.each(events, fn
          :paste_start -> send(parent, {:paste_start, :ok})
          other -> send(parent, other)
        end)

        if :paste_start in events do
          reader_loop(parent, rest, :paste, <<>>)
        else
          reader_loop(parent, rest, :normal, <<>>)
        end

      {:tty_eof, :ok} ->
        send(parent, {:key, :ctrl_d})
    after
      timeout ->
        # 孤立 ESC 空闲超时：Key.flush 按裸 Esc 发出
        {events, rest} = Key.flush(buf)
        Enum.each(events, &send(parent, &1))
        reader_loop(parent, rest, :normal, <<>>)
    end
  end

  # ── 主循环 ──

  defp loop(state, reader) do
    receive do
      # Esc 在 busy 时优先抢占：即使 mailbox 里已排了若干 :text/:tool_result，
      # 也先杀 evaluator/LLM，再丢弃滞后文本，避免"已取消还在流"
      {:key, key} when key in [:esc, :escape] and state.busy and is_nil(state.picker) ->
        Newbee.Agent.Loop.interrupt(state.kernel)

        if state.submit_kind == :shell and is_pid(state.submit_pid) do
          Process.exit(state.submit_pid, :kill)
        end

        state =
          if state.awaiting_permission do
            send(state.kernel, {:permission_reply, false})
            state |> Map.put(:awaiting_permission, false) |> push_line("\e[31m⏹ 已拒绝并中断\e[0m")
          else
            kind_hint =
              cond do
                state.submit_kind == :shell -> "shell 任务"
                state.streaming -> "模型推理/工具执行"
                true -> "当前任务"
              end

            state
            |> push_line("\e[31m⏹ 中断已触发 · 正在取消 #{kind_hint}…\e[0m \e[2m（若 1s 内未停止可再按 Esc）\e[0m")
          end

        # 丢弃已排队的滞后渲染事件，防"取消后仍吐字"
        state =
          flush_pending_events(state)
          |> Map.merge(%{busy: false, submit_pid: nil, submit_kind: nil})
          |> maybe_start_next()

        loop(paint(state, true), reader)

      # 中断后紧随的第二个 Esc 只消费，不得落入普通按键/退出路径。
      {:key, key} when key in [:esc, :escape] and not state.busy and is_nil(state.picker) ->
        loop(state, reader)

      {:key, key} ->
        if state.picker do
          case handle_picker_key(state, key) do
            :quit ->
              :ok

            {state, force} ->
              loop(paint(state, force), reader)
          end
        else
          if state.awaiting_permission do
            if key in [:esc, :escape, :ctrl_c] do
              # 已被上面的 guard 覆盖，此分支仅兜底
              Newbee.Agent.Loop.interrupt(state.kernel)
              send(state.kernel, {:permission_reply, false})
              state = state |> Map.put(:awaiting_permission, false) |> push_line("\e[31m⏹ 已拒绝并中断\e[0m")
              loop(paint(state), reader)
            else
              ok = key in [?y, ?Y] or key == :enter
              send(state.kernel, {:permission_reply, ok})

              state =
                state
                |> Map.put(:awaiting_permission, false)
                |> Map.put(:busy, true)
                |> push_line(if ok, do: "\e[32m✓ 已允许执行\e[0m", else: "\e[31m✗ 已拒绝执行\e[0m")

              loop(paint(state), reader)
            end
          else
            case handle_key(state, reader, key) do
              :quit -> :ok
              {state, force} -> loop(paint(state, force), reader)
            end
          end
        end

      {:paste, text} when byte_size(text) > 0 ->
        state = %{state | line_ed: Line.insert(state.line_ed, text)}
        loop(paint(state), reader)

      {:paste, _empty} ->
        loop(state, reader)

      {:newbee_event, topic, payload} ->
        # 单个事件的渲染异常不能杀掉主 TUI 进程；保留回合状态并显示诊断。
        if Newbee.LLM.Client.interrupted?(state.client) and topic in [:text, :reasoning, :tool_start] do
          loop(state, reader)
        else
          state = safe_render_event(state, topic, payload) |> schedule_paint()
          state = if topic == :turn_end, do: maybe_start_next(state), else: state
          loop(state, reader)
        end

      {:shell_done, cmd, result} ->
        output = String.slice(result.output, 0, 8_000)

        dur =
          if state.shell_started_at do
            secs = (System.monotonic_time(:millisecond) - state.shell_started_at) / 1000
            "\e[2m⏱ 用时 #{format_duration(secs)} · " <> now_hm() <> "\e[0m"
          else
            nil
          end

        state =
          state
          |> push_line(Newbee.TUI.Cards.shell_header(cmd))
          |> then(fn s -> Enum.reduce(String.split(output, "\n"), s, &push_line(&2, &1)) end)
          |> push_line(Newbee.TUI.Cards.shell_footer(result))

        state = if dur, do: push_line(state, dur), else: state
        state = %{state | busy: false, submit_pid: nil, submit_kind: nil, shell_started_at: nil} |> maybe_start_next()

        loop(paint(state), reader)

      {:paint, :now} ->
        loop(paint(state), reader)

      :spinner_tick ->
        if state.busy do
          Process.send_after(self(), :spinner_tick, 80)
          loop(paint(state), reader)
        else
          loop(state, reader)
        end
    end
  end

  # 普通按键处理（权限确认由 loop 先拦截）。返回 :quit | {state, force_paint?}。
  defp handle_key(state, reader, key) do
    if state.search_mode do
      # 搜索态：Ctrl-T 直接退出搜索并切窗格；Ctrl-R 退出搜索并切思考流，避免搜索独占
      case key do
        :ctrl_t ->
          state = %{state | search_mode: false, search_query: "", search_idx: 0, search_orig: ""}
          {%{state | pane: next_pane(state.pane)}, true}

        :ctrl_r ->
          state = %{state | search_mode: false, search_query: "", search_idx: 0, search_orig: ""}
          state = %{state | show_reasoning: not state.show_reasoning}
          {push_line(state, if(state.show_reasoning, do: "\e[2m思考流：显示\e[0m", else: "\e[2m思考流：隐藏\e[0m")), true}

        _ ->
          search_key(state, key)
      end
    else
      case key do
        :ctrl_a ->
          {%{state | line_ed: Line.home(state.line_ed)}, false}

        :ctrl_e ->
          {%{state | line_ed: Line.to_end(state.line_ed)}, false}

        :ctrl_b ->
          {%{state | line_ed: Line.left(state.line_ed)}, false}

        :ctrl_f ->
          {%{state | line_ed: Line.right(state.line_ed)}, false}

        :ctrl_h ->
          {%{state | line_ed: Line.backspace(state.line_ed)}, false}

        :ctrl_d ->
          if state.line_ed.text == "", do: :quit, else: {%{state | line_ed: Line.delete(state.line_ed)}, false}

        :ctrl_p ->
          {%{state | line_ed: Line.hist_prev(state.line_ed)}, false}

        :ctrl_n ->
          {%{state | line_ed: Line.hist_next(state.line_ed)}, false}

        :ctrl_c ->
          if state.line_ed.text == "", do: :quit, else: {%{state | line_ed: Line.clear(state.line_ed)}, false}

        :ctrl_l ->
          {state, true}

        :enter ->
          {submit(state, reader), false}

        :backspace ->
          {%{state | line_ed: Line.backspace(state.line_ed)}, false}

        :delete ->
          {%{state | line_ed: Line.delete(state.line_ed)}, false}

        :left ->
          {%{state | line_ed: Line.left(state.line_ed)}, false}

        :right ->
          {%{state | line_ed: Line.right(state.line_ed)}, false}

        :home ->
          {%{state | line_ed: Line.home(state.line_ed)}, false}

        :end ->
          {%{state | line_ed: Line.to_end(state.line_ed)}, false}

        :ctrl_u ->
          {%{state | line_ed: Line.cut_to_start(state.line_ed)}, false}

        :ctrl_k ->
          {%{state | line_ed: Line.cut_to_end(state.line_ed)}, false}

        :ctrl_y ->
          {%{state | line_ed: Line.yank(state.line_ed)}, false}

        :ctrl_t ->
          {%{state | pane: next_pane(state.pane)}, true}

        :ctrl_w ->
          {%{state | line_ed: Line.cut_word(state.line_ed)}, false}

        :ctrl_r ->
          q = state.line_ed.text
          matches = hist_matches(state, q)
          text = if matches == [], do: state.line_ed.text, else: Enum.at(matches, 0)
          ed = %{state.line_ed | text: text, cur: String.length(text)}

          {%{state | search_mode: true, search_query: q, search_idx: 0, search_orig: state.line_ed.text, line_ed: ed},
           true}

        :tab ->
          {%{state | line_ed: Line.complete(state.line_ed)}, false}

        :ctrl_o ->
          {toggle_block(state), true}

        :up ->
          {%{state | line_ed: Line.hist_prev(state.line_ed)}, false}

        :down ->
          {%{state | line_ed: Line.hist_next(state.line_ed)}, false}

        :page_up ->
          {%{state | page: min(state.page + 1, 50)}, true}

        :page_down ->
          {%{state | page: max(state.page - 1, 0)}, true}

        :escape ->
          if state.busy do
            Newbee.Agent.Loop.interrupt(state.kernel)

            if state.submit_kind == :shell and is_pid(state.submit_pid) do
              Process.exit(state.submit_pid, :kill)

              state =
                state
                |> push_line("\e[31m⏹ shell 已中断\e[0m")
                |> Map.merge(%{busy: false, submit_pid: nil, submit_kind: nil})
                |> maybe_start_next()

              {state, false}
            else
              {state |> push_line("\e[31m⏹ 已请求中断…\e[0m"), false}
            end
          else
            {%{state | line_ed: Line.clear(state.line_ed)}, false}
          end

        :esc ->
          if state.busy do
            Newbee.Agent.Loop.interrupt(state.kernel)

            if state.submit_kind == :shell and is_pid(state.submit_pid) do
              Process.exit(state.submit_pid, :kill)

              state =
                state
                |> push_line("\e[31m⏹ shell 已中断\e[0m")
                |> Map.merge(%{busy: false, submit_pid: nil, submit_kind: nil})
                |> maybe_start_next()

              {state, false}
            else
              {state |> push_line("\e[31m⏹ 已请求中断…\e[0m"), false}
            end
          else
            {%{state | line_ed: Line.clear(state.line_ed)}, false}
          end

        {:alt, ?b} ->
          {%{state | line_ed: Line.word_left(state.line_ed)}, false}

        {:alt, ?f} ->
          {%{state | line_ed: Line.word_right(state.line_ed)}, false}

        {:alt, ?d} ->
          {%{state | line_ed: Line.delete_word_forward(state.line_ed)}, false}

        63 ->
          if state.line_ed.text == "",
            do: {push_line(state, help_text()), true},
            else: {%{state | line_ed: Line.insert(state.line_ed, <<63::utf8>>)}, false}

        ch when is_integer(ch) ->
          {%{state | line_ed: Line.insert(state.line_ed, <<ch::utf8>>)}, false}

        _unknown ->
          {state, false}
      end
    end
  end

  defp hist_matches(state, q) do
    if q == "" do
      []
    else
      state.line_ed.hist
      |> Enum.reverse()
      |> Enum.filter(&String.contains?(&1, q))
    end
  end

  defp apply_search(state, q) do
    matches = hist_matches(state, q)
    text = if matches == [], do: state.search_orig, else: Enum.at(matches, 0)
    ed = %{state.line_ed | text: text, cur: String.length(text)}
    {%{state | search_query: q, search_idx: 0, line_ed: ed}, true}
  end

  defp search_key(state, :ctrl_r) do
    matches = hist_matches(state, state.search_query)

    if matches == [] do
      {state, true}
    else
      idx = rem(state.search_idx + 1, length(matches))
      text = Enum.at(matches, idx)
      ed = %{state.line_ed | text: text, cur: String.length(text)}
      {%{state | search_idx: idx, line_ed: ed}, true}
    end
  end

  defp search_key(state, :enter) do
    {%{state | search_mode: false, search_query: "", search_idx: 0, search_orig: ""}, true}
  end

  defp search_key(state, :escape) do
    ed = %{state.line_ed | text: state.search_orig, cur: String.length(state.search_orig)}
    {%{state | search_mode: false, search_query: "", search_idx: 0, search_orig: "", line_ed: ed}, true}
  end

  defp search_key(state, :ctrl_c) do
    search_key(state, :escape)
  end

  defp search_key(state, :backspace) do
    q = String.slice(state.search_query, 0, max(String.length(state.search_query) - 1, 0))
    apply_search(state, q)
  end

  defp search_key(state, ch) when is_integer(ch) do
    apply_search(state, state.search_query <> <<ch::utf8>>)
  end

  defp search_key(state, _), do: {state, true}

  # ── 提交 ──

  defp submit(state, reader), do: submit_text(state, reader, true)

  # 当前回合运行时不再把请求直接扔进 Kernel mailbox；显式保存在 TUI，
  # 这样用户能看到内容，Esc 取消当前回合后也不会丢失后续输入。
  defp submit_text(state, reader, record_history?) do
    text = String.trim_trailing(state.line_ed.text)

    if text == "" do
      state
    else
      if record_history?, do: Newbee.TUI.History.append(text)

      if state.busy do
        enqueue_input(state, text)
      else
        submit_now(state, reader, text)
      end
    end
  end

  defp enqueue_input(state, text) do
    n = length(state.pending_inputs) + 1

    state
    |> push_line("\e[2m⏳ 已排队 [##{n}] #{String.slice(text, 0, 160)}\e[0m")
    |> Map.put(:line_ed, %Line{hist: state.line_ed.hist, hcur: length(state.line_ed.hist)})
    |> Map.update!(:pending_inputs, &(&1 ++ [text]))
  end

  defp submit_now(state, reader, text) do
    case String.trim(text) do
      # TUI 内建命令：思考流开关（Ctrl+T 已让位给窗格切换）
      "/reasoning" ->
        state = %{state | show_reasoning: not state.show_reasoning}
        push_line(state, if(state.show_reasoning, do: "\e[2m思考流：显示\e[0m", else: "\e[2m思考流：隐藏\e[0m"))

      _ ->
        state =
          state
          |> push_line("\e[32m›\e[0m \e[2m[" <> now_hm() <> "]\e[0m " <> text)
          |> Map.put(:line_ed, %Line{hist: state.line_ed.hist, hcur: length(state.line_ed.hist)})
          |> Map.put(:busy, true)
          |> Map.put(:page, 0)
          |> Map.put(:turn_started_at, System.monotonic_time(:millisecond))
          |> Map.put(:llm_step_start, System.monotonic_time(:millisecond))
          |> Map.put(:awaiting_first_token, true)
          |> Map.update(:turns, 1, &(&1 + 1))

        state = paint(state)

        ctx =
          %{
            say: fn line -> send(self(), {:newbee_event, :tui_say, {:tui_say, line}}) end,
            kernel: state.kernel,
            client: state.client
          }

        case Newbee.Commands.handle(text, ctx) do
          :quit ->
            if is_pid(reader), do: send(reader, {:key, :ctrl_c}), else: send(self(), {:key, :ctrl_c})
            %{state | busy: false}

          :ok ->
            %{state | busy: false, turn_started_at: nil}

          :handled ->
            %{state | busy: false, turn_started_at: nil}

          {:shell, cmd} ->
            # !shell 也异步执行，否则主循环被同步 shell 卡住时无法处理 Esc。
            parent = self()

            shell_pid =
              spawn(fn ->
                result = Newbee.Tools.Run.sh(cmd, timeout: 300_000)
                send(parent, {:shell_done, cmd, result})
              end)

            %{state | submit_pid: shell_pid, submit_kind: :shell, shell_started_at: System.monotonic_time(:millisecond)}

          {:submit, text} ->
            run_submit(state, text)

          {:image, path, prompt} ->
            run_image_submit(state, path, prompt)

          :new ->
            GenServer.stop(state.kernel)
            {:ok, kernel2} = new_kernel(state.client)

            %{
              state
              | kernel: kernel2,
                busy: false,
                lines: [],
                expanded: %{},
                tool_blocks: %{},
                pending_inputs: [],
                picker: nil,
                page: 0
            }

          {:resume, id} ->
            {:ok, kernel2} = resume_kernel(state.client, id)
            lines = load_session_lines(id)
            %{state | kernel: kernel2, busy: false, lines: lines, expanded: %{}}

          {:resume_picker, metas} ->
            %{state | picker: %{items: metas, index: 0}, busy: false}
        end
    end
  end

  # 当前任务完成后按 FIFO 启动下一条；命令类输入也经过同一入口。
  defp maybe_start_next(%{busy: false, pending_inputs: [text | rest]} = state) do
    state =
      state
      |> Map.put(:pending_inputs, rest)
      |> Map.put(:line_ed, %{state.line_ed | text: text, cur: String.length(text)})
      |> push_line("\e[2m▶ 执行排队输入: #{String.slice(text, 0, 160)}\e[0m")
      |> submit_text(nil, false)

    if state.busy, do: state, else: maybe_start_next(state)
  end

  defp maybe_start_next(state), do: state

  defp flush_pending_events(state) do
    receive do
      {:newbee_event, topic, _} when topic in [:text, :reasoning, :tool_start, :tool_result, :stream_chunk] ->
        flush_pending_events(state)
    after
      0 -> state
    end
  end

  defp handle_picker_key(state, :up) do
    picker = %{state.picker | index: max(state.picker.index - 1, 0)}
    {%{state | picker: picker}, true}
  end

  defp handle_picker_key(state, :down) do
    last = max(length(state.picker.items) - 1, 0)
    picker = %{state.picker | index: min(state.picker.index + 1, last)}
    {%{state | picker: picker}, true}
  end

  defp handle_picker_key(state, :escape) do
    {push_line(%{state | picker: nil}, "\e[2m已取消会话选择\e[0m"), true}
  end

  defp handle_picker_key(_state, :ctrl_c), do: :quit

  defp handle_picker_key(state, :enter) do
    case Enum.at(state.picker.items, state.picker.index) do
      nil ->
        {%{state | picker: nil} |> push_line("\e[2m（没有可恢复的会话）\e[0m"), true}

      meta ->
        GenServer.stop(state.kernel)
        {:ok, kernel} = resume_kernel(state.client, meta.id)
        lines = load_session_lines(meta.id)
        {%{state | picker: nil, kernel: kernel, busy: false, lines: lines, expanded: %{}}, true}
    end
  end

  defp handle_picker_key(state, _key), do: {state, false}

  # Ctrl+T 窗格轮转：nil → 绑定 → 事件日志 → 工具块 → 队列 → nil
  defp next_pane(nil), do: :bindings
  defp next_pane(:bindings), do: :events
  defp next_pane(:events), do: :tools
  defp next_pane(:tools), do: :queue
  defp next_pane(:queue), do: nil

  defp run_submit(state, text) do
    # 异步跑 turn：主循环继续处理输入/中断
    caller =
      spawn_link(fn ->
        Newbee.Agent.Loop.submit(state.kernel, text)
      end)

    Process.send_after(self(), :spinner_tick, 80)
    %{state | busy: true, submit_pid: caller, submit_kind: :turn}
  end

  defp run_image_submit(state, path, prompt) do
    parent = self()

    caller =
      spawn_link(fn ->
        case Newbee.Agent.Loop.submit_image(state.kernel, path, prompt) do
          {:error, reason} ->
            send(parent, {:newbee_event, :error, {:error, reason}})
            send(parent, {:newbee_event, :turn_end, {:turn_end, :error, 0}})

          _reply ->
            :ok
        end
      end)

    Process.send_after(self(), :spinner_tick, 80)
    %{state | busy: true, submit_pid: caller, submit_kind: :turn}
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
    send(self(), {:newbee_event, :tui_say, {:tui_say, "已恢复会话 #{id} · #{meta.messages} 条消息 · #{meta.title}"}})
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

    send(self(), {:newbee_event, :tui_say, {:tui_say, "已开启新会话 #{session_id(kernel)}"}})
    {:ok, kernel}
  end

  # 历史回放统一走 Newbee.History（与 CLI /resume 同一渲染，对齐实时输出样式）。
  defp load_session_lines(id) do
    Newbee.Session.open(id)
    |> Newbee.Session.messages()
    |> Newbee.History.render_lines()
    |> Enum.take(-@scrollback)
  rescue
    _ -> []
  end

  @doc "追加一行到 transcript；重置 streaming 状态。"
  def push_line(%__MODULE__{} = state, line) do
    lines = (state.lines ++ [line]) |> Enum.take(-@scrollback)
    %{state | lines: lines, streaming: false, stream_kind: nil, text_buffer: <<>>, render_pending: false}
  end

  @doc """
  渲染一个总线事件。返回新 state。
    - :text      正文流（首 delta 开新行，后续追加；stream_kind=:text）
    - :reasoning 思考流（灰色，独立流）
    - 其余 topic 渲染成一行后 push_line
  """
  def render_event(%__MODULE__{} = state, :text, {:text, delta}) do
    state = finalize_think_block(state)

    {ft_sum_ms, ft_count, awaiting} =
      if state.awaiting_first_token and state.llm_step_start do
        now = System.monotonic_time(:millisecond)
        {state.ft_sum_ms + max(now - state.llm_step_start, 0), state.ft_count + 1, false}
      else
        {state.ft_sum_ms, state.ft_count, state.awaiting_first_token}
      end

    state = %{state | ft_sum_ms: ft_sum_ms, ft_count: ft_count, awaiting_first_token: awaiting}
    render_text_delta(state, delta)
  end

  # 思考流（对齐 dsh ReasoningRow）：默认折叠为单行摘要，Ctrl-O 展开全文。
  # 流式时单行原地更新「思考中…最新一行」；文本/工具/终态到来时收敛为
  # 「▸ Think (N 行): 首行」。/reasoning off 时完全不显示（但仍累积进块）。
  def render_event(%__MODULE__{} = state, :reasoning, {:reasoning, delta}) do
    state = flush_text_buffer(state)
    state = ensure_think_block(state)
    id = state.think_block_id
    block = state.tool_blocks[id]
    acc = (block.result || "") <> delta
    state = struct!(state, tool_blocks: Map.put(state.tool_blocks, id, %{block | result: acc}))

    if state.show_reasoning do
      replace_think_line(state, think_running_line(acc))
    else
      state
    end
  end

  def render_event(%__MODULE__{} = state, :usage, {:usage, usage}) do
    now = System.monotonic_time(:millisecond)
    llm_ms = if state.llm_step_start, do: state.llm_ms + max(now - state.llm_step_start, 0), else: state.llm_ms
    pt = to_num(usage["prompt_tokens"] || usage[:prompt_tokens]) || 0
    ct = to_num(usage["completion_tokens"] || usage[:completion_tokens]) || 0

    cr0 =
      to_num(usage["cache_read_tokens"] || usage[:cache_read_tokens] || usage["cached_tokens"] || usage[:cached_tokens]) ||
        0

    cr =
      if cr0 == 0,
        do:
          to_num(
            get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
              get_in(usage, [:prompt_tokens_details, :cached_tokens])
          ) || 0,
        else: cr0

    cw = to_num(usage["cache_write_tokens"] || usage[:cache_write_tokens]) || 0
    uncached = to_num(usage["uncached_prompt_tokens"] || usage[:uncached_prompt_tokens]) || max(pt - cr, 0)

    %{
      state
      | usage: merge_usage(state.usage, usage),
        llm_ms: llm_ms,
        llm_step_start: nil,
        steps: state.steps + 1,
        prompt_tokens: state.prompt_tokens + pt,
        completion_tokens: state.completion_tokens + ct,
        cached_tokens: state.cached_tokens + cr,
        cache_write_tokens: state.cache_write_tokens + cw,
        uncached_prompt_tokens: state.uncached_prompt_tokens + uncached
    }
  end

  def render_event(%__MODULE__{} = state, :tool_start, {:tool_start, name, title, code}) do
    state = finalize_think_block(state)
    now = System.monotonic_time(:millisecond)

    {llm_ms, llm_step_start} =
      if state.llm_step_start do
        {state.llm_ms + max(now - state.llm_step_start, 0), nil}
      else
        {state.llm_ms, nil}
      end

    state = %{state | llm_ms: llm_ms, llm_step_start: llm_step_start, tool_step_start: now}
    state = flush_text_buffer(state)
    id = :erlang.unique_integer([:positive])

    block = %{
      id: id,
      name: name,
      title: title,
      code: code,
      result: nil,
      warnings: nil,
      started_at: System.monotonic_time(:millisecond)
    }

    line = tool_block_line(block)
    %{push_line(state, line) | tool_blocks: Map.put(state.tool_blocks, id, block), last_block_id: id}
  end

  def render_event(%__MODULE__{} = state, :tool_result, {:tool_result, _name, text}) do
    now = System.monotonic_time(:millisecond)
    tool_ms = if state.tool_step_start, do: state.tool_ms + max(now - state.tool_step_start, 0), else: state.tool_ms
    state = %{state | tool_ms: tool_ms, tool_step_start: nil, llm_step_start: now, awaiting_first_token: true}
    state = flush_text_buffer(state)
    id = Map.get(state, :last_block_id)

    state =
      if id do
        case Map.get(state.tool_blocks, id) do
          nil -> state
          block -> %{state | tool_blocks: Map.put(state.tool_blocks, id, %{block | result: text})}
        end
      else
        state
      end

    line = Newbee.TUI.Cards.tool_footer(text)

    dur =
      if id do
        case Map.get(state.tool_blocks, id) do
          %{started_at: at} -> "\e[2m ⏱ #{format_duration((System.monotonic_time(:millisecond) - at) / 1000)}\e[0m"
          _ -> ""
        end
      else
        ""
      end

    state = push_line(state, line <> dur)
    refresh_bindings(state)
  end

  def render_event(%__MODULE__{} = state, :permission_ask, {:permission_ask, preview}) do
    first_line = preview |> String.split("\n") |> hd() |> String.slice(0, 80)

    state =
      push_line(state, "\e[33m? 允许执行以下代码？[y 允许 / 任意键拒绝]\e[0m \e[2m#{first_line}\e[0m")

    %{state | awaiting_permission: true, busy: true}
  end

  def render_event(%__MODULE__{} = state, :tool_warnings, {:tool_warnings, text}) do
    # 编译 warnings 徽标化：transcript 只留一行，详情存 tool_blocks 供 Ctrl-O 展开
    count = text |> String.split("\n", trim: true) |> length()
    badge = "\e[33m⚠ 警告 #{count} 条\e[0m\e[2m [Ctrl-O 展开工具块]\e[0m"
    state = push_line(flush_text_buffer(state), badge)

    # 把 warning 落到最近工具块的 result 尾部（折叠详情）
    case Map.get(state, :last_block_id) do
      nil ->
        state

      id ->
        case Map.get(state.tool_blocks, id) do
          nil -> state
          block -> %{state | tool_blocks: Map.put(state.tool_blocks, id, %{block | warnings: text})}
        end
    end
  end

  def render_event(%__MODULE__{} = state, :file_diff, {:file_diff, path, diff, stats}) do
    state = flush_text_buffer(state)
    # 内联 diff（§5.1）：行号 + 语法高亮，渲染逻辑在 Newbee.TUI.Cards.diff_card
    Enum.reduce(Newbee.TUI.Cards.diff_card(path, diff, stats), state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :tool_error, {:tool_error, text}) do
    state = flush_text_buffer(state)
    # 卡内错误详情行（状态徽章由紧随的 tool_result 脚给出）
    push_line(state, Newbee.TUI.Cards.error_line(text))
  end

  def render_event(%__MODULE__{} = state, :rule_hit, {:rule_hit, hits}) do
    state = flush_text_buffer(state)
    lines = Enum.map(hits, &"\e[33m⚑ 沉睡规则命中 [#{&1.id}]\e[0m \e[2m#{&1.injection}\e[0m")
    Enum.reduce(lines, state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :prompt_injection, {:prompt_injection, details}) do
    state = flush_text_buffer(state)
    source = details[:source] || "unknown"
    role = details[:role] || "system"
    timing = details[:timing] || "next_request"

    lines =
      [
        "\e[35m◆ Prompt 注入\e[0m \e[2msource=#{source} role=#{role} timing=#{timing}\e[0m",
        "\e[2m原因: #{details[:reason] || "未说明"}\e[0m"
      ] ++
        if(details[:trigger], do: ["\e[2m触发内容: #{details[:trigger]}\e[0m"], else: []) ++
        ["\e[2m实际注入:\n#{details[:content] || ""}\e[0m"]

    Enum.reduce(lines, state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :audit, {:audit, :dangerous_code, hits}) do
    push_line(state, "\e[31m⚖ 审计: 危险代码 #{inspect(hits)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :audit, {:audit, verdict, actor, target, ring}) do
    push_line(state, "\e[2m⚖ 审计: #{verdict} #{actor} → ring#{ring} #{inspect(target) |> String.slice(0, 60)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :error, {:error, e}) do
    state = flush_text_buffer(state)
    push_line(state, "\e[31m" <> Newbee.LLM.Client.format_error(e) <> "\e[0m")
  end

  def render_event(%__MODULE__{} = state, :done, {:done, summary}) do
    state = flush_text_buffer(state)
    push_line(state, "\e[1m● \e[0m" <> Newbee.Markdown.render(summary))
  end

  def render_event(%__MODULE__{} = state, :ask, {:ask, q}) do
    state = flush_text_buffer(state)
    push_line(state, "\e[33m? \e[0m" <> Newbee.Markdown.render(q))
  end

  def render_event(%__MODULE__{} = state, :interrupted, {:interrupted, content}) do
    state = flush_text_buffer(state)

    dur_str =
      if state.turn_started_at do
        secs = (System.monotonic_time(:millisecond) - state.turn_started_at) / 1000
        "\e[31m⏹ 已中断\e[0m \e[2m· 用时 #{format_duration(secs)} · 回合已取消，可继续输入\e[0m"
      else
        "\e[31m⏹ 已中断 · 回合已取消，可继续输入\e[0m"
      end

    state = push_line(state, dur_str)
    state = %{state | turn_started_at: nil, busy: false, streaming: false, submit_pid: nil, submit_kind: nil}
    state = if content && content != "", do: push_line(state, "\e[2m  #{content}\e[0m"), else: state
    state
  end

  def render_event(%__MODULE__{} = state, :turn_end, _) do
    state = state |> flush_text_buffer() |> finalize_think_block()
    state = refresh_bindings(state)

    dur_str =
      if state.turn_started_at do
        secs = (System.monotonic_time(:millisecond) - state.turn_started_at) / 1000
        "\e[2m⏱ 用时 #{format_duration(secs)}\e[0m"
      else
        nil
      end

    state = if dur_str, do: push_line(state, dur_str), else: state
    notify("newbee", "回合完成")
    %{state | busy: false, submit_pid: nil, submit_kind: nil, turn_started_at: nil}
  end

  def render_event(%__MODULE__{} = state, :tui_say, {:tui_say, text}) do
    Enum.reduce(String.split(text, "\n"), state, &push_line(&2, &1))
  end

  def render_event(%__MODULE__{} = state, :advisor_note, {:advisor_note, text}) do
    push_line(state, "\e[38;5;117m◉ advisor\e[0m #{text}")
  end

  def render_event(%__MODULE__{} = state, :worker_hint, {:worker_hint, sig}) do
    push_line(state, "\e[2m⚑ 进化线索已记录（重复失败模式）: #{String.slice(sig, 0, 60)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :compacted, {:compacted, n}) do
    push_line(state, "\e[2m⏳ 历史已压缩 #{n} 条（事件日志原样保留）\e[0m")
  end

  def render_event(%__MODULE__{} = state, :progress, {:progress, score, scores}) do
    push_line(state, "\e[2m进度 #{Float.round(score, 1)}/20 #{Newbee.Agent.Progress.render_scores(scores)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :progress_stall, {:progress_stall, scores}) do
    push_line(state, "\e[33m⚠ 进度停滞: #{Newbee.Agent.Progress.render_scores(scores)}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :goal_round, {:goal_round, round}) do
    push_line(state, "\e[2m（自主模式第 #{round} 轮）\e[0m")
  end

  def render_event(%__MODULE__{} = state, :goal_done, {:goal_done, summary}) do
    state = flush_text_buffer(state)
    push_line(state, "\e[1m● 目标完成\e[0m " <> summary)
  end

  def render_event(%__MODULE__{} = state, :goal_limit, {:goal_limit, n}) do
    push_line(state, "\e[31m⏹ 目标达到轮数上限 #{n}\e[0m")
  end

  def render_event(%__MODULE__{} = state, :goal_cancelled, _) do
    push_line(state, "\e[31m⏹ 目标已取消\e[0m")
  end

  def render_event(%__MODULE__{} = state, _topic, _payload) do
    state
  end

  defp safe_render_event(state, topic, payload) do
    render_event(state, topic, payload)
  rescue
    e ->
      Newbee.DebugLog.log(:event, "tui render failed topic=#{topic} error=#{Exception.message(e)}")
      push_line(state, "\e[31m事件渲染失败: #{topic}\e[0m")
  catch
    kind, reason ->
      Newbee.DebugLog.log(:event, "tui render failed topic=#{topic} #{kind}=#{inspect(reason)}")
      push_line(state, "\e[31m事件渲染失败: #{topic}\e[0m")
  end

  # ── 流式追加 ──

  # Flush 缓冲的 markdown 文本到显示行；流式行先显示原文，收尾时原位替换为渲染结果，
  # 避免列表等 markdown 在跨 chunk 换行时同时留下原文和 ANSI 渲染行。
  defp flush_text_buffer(%__MODULE__{streaming: true, stream_kind: :text, text_buffer: buffer} = state)
       when buffer != "" do
    state
    |> replace_last_line(Newbee.Markdown.render(buffer))
    |> Map.merge(%{text_buffer: <<>>, streaming: false, stream_kind: nil})
  end

  defp flush_text_buffer(%__MODULE__{streaming: true, stream_kind: :text} = state) do
    %{state | text_buffer: <<>>, streaming: false, stream_kind: nil}
  end

  defp flush_text_buffer(%__MODULE__{text_buffer: <<>>} = state), do: state

  defp flush_text_buffer(%__MODULE__{} = state) do
    if String.trim_leading(state.text_buffer) != <<>> do
      state
      |> push_line(Newbee.Markdown.render(state.text_buffer))
      |> Map.put(:text_buffer, <<>>)
    else
      %{state | text_buffer: <<>>}
    end
  end

  defp append_text(state, delta), do: append_text(state, delta, "")

  defp append_text(%__MODULE__{lines: lines} = state, delta, prefix) do
    %{state | lines: List.update_at(lines, -1, &(&1 <> prefix <> delta))}
  end

  defp merge_usage(a, b) when is_map(b) do
    Map.merge(a, b, fn _k, x, y -> (to_num(x) || 0) + (to_num(y) || 0) end)
  end

  defp merge_usage(a, _), do: a
  defp to_num(n) when is_number(n), do: n
  defp to_num(_), do: nil

  # ── 思考块（Think disclosure，对齐 dsh ReasoningRow）──

  # 确保有一个进行中的思考块：复用 tool_blocks 存储，kind: :think，
  # result 累积思考全文。transcript 只留一行摘要（占位行）。
  defp ensure_think_block(%__MODULE__{think_block_id: id} = state) when is_integer(id), do: state

  defp ensure_think_block(%__MODULE__{} = state) do
    id = :erlang.unique_integer([:positive])

    block = %{
      id: id,
      kind: :think,
      name: "think",
      title: "",
      code: "",
      result: "",
      warnings: nil,
      started_at: System.monotonic_time(:millisecond)
    }

    state = %{state | tool_blocks: Map.put(state.tool_blocks, id, block), last_block_id: id, think_block_id: id}

    if state.show_reasoning do
      state = push_line(state, think_running_line(""))
      %{state | think_lines: Map.put(state.think_lines, id, length(state.lines) - 1)}
    else
      state
    end
  end

  # 原地更新思考摘要行
  defp replace_think_line(%__MODULE__{think_block_id: id} = state, line) do
    case Map.get(state.think_lines, id) do
      nil -> state
      idx -> if idx < length(state.lines), do: %{state | lines: List.replace_at(state.lines, idx, line)}, else: state
    end
  end

  defp think_running_line(acc) do
    latest = acc |> String.trim_trailing() |> String.split("\n") |> List.last() |> String.trim()
    latest = if latest == "", do: "…", else: String.slice(latest, 0, 60)
    "\e[36m▸\e[0m \e[1mThink\e[0m \e[2m思考中…" <> latest <> "\e[0m"
  end

  defp think_final_line(acc) do
    ls = String.split(acc, "\n", trim: true)
    n = length(ls)
    first = ls |> List.first() |> Kernel.||("") |> String.trim() |> String.slice(0, 60)
    "\e[36m▸\e[0m \e[1mThink\e[0m \e[2m(#{n} 行): " <> first <> "\e[0m \e[2m[Ctrl-O 展开]\e[0m"
  end

  # 收敛：思考块结束（文本/工具/终态到来），摘要行从「思考中」切到首行摘要。
  defp finalize_think_block(%__MODULE__{think_block_id: nil} = state), do: state

  defp finalize_think_block(%__MODULE__{think_block_id: id} = state) do
    acc = get_in(state.tool_blocks, [id, Access.key(:result)]) || ""

    state =
      if state.show_reasoning and String.trim(acc) != "" do
        replace_think_line(state, think_final_line(acc))
      else
        state
      end

    %{state | think_block_id: nil}
  end

  # ── 工具块 ──

  # Ctrl-O 展开/折叠工具块：完整代码 + 完整结果追加进 transcript，再按收回（§5.1 折叠块）。
  # 展开块的行区间记在 state.expanded（block_id => {start, count}），折叠时按区间删除。
  defp toggle_block(state) do
    case state.last_block_id && Map.get(state.tool_blocks, state.last_block_id) do
      nil ->
        state

      block ->
        if Map.has_key?(state.expanded, block.id) do
          collapse_block(state, block.id)
        else
          expand_block(state, block)
        end
    end
  end

  defp render_text_delta(state, delta) do
    combined = state.text_buffer <> delta

    case String.split(combined, "\n") do
      [line] ->
        state =
          if state.streaming and state.stream_kind == :text and state.text_buffer != "" do
            append_text(state, delta)
          else
            push_line(state, line)
          end

        %{state | text_buffer: line, streaming: true, stream_kind: :text}

      parts ->
        {completed, [remaining]} = Enum.split(parts, -1)
        state = commit_text_lines(state, completed)

        if remaining == "" do
          %{state | text_buffer: <<>>, streaming: false, stream_kind: nil}
        else
          state
          |> push_line(remaining)
          |> Map.put(:text_buffer, remaining)
          |> Map.put(:streaming, true)
          |> Map.put(:stream_kind, :text)
        end
    end
  end

  defp commit_text_lines(
         %{streaming: true, stream_kind: :text, text_buffer: buffer} = state,
         [first | rest]
       )
       when buffer != "" do
    state = replace_last_line(state, Newbee.Markdown.render(first))
    Enum.reduce(rest, state, fn line, acc -> push_line(acc, Newbee.Markdown.render(line)) end)
  end

  defp commit_text_lines(state, lines) do
    Enum.reduce(lines, state, fn line, acc -> push_line(acc, Newbee.Markdown.render(line)) end)
  end

  defp replace_last_line(%__MODULE__{lines: lines} = state, line) do
    %{state | lines: List.replace_at(lines, -1, line)}
  end

  defp expand_block(state, block) do
    start = length(state.lines)

    state =
      state
      |> push_line("")
      |> push_line("\e[36m┌─\e[0m \e[1m⏺ 完整代码 [#{block.name} #{block.title}]\e[0m")

    # 整体先高亮再分行：跨行 heredoc/字符串的颜色不断裂
    state =
      Enum.reduce(String.split(Newbee.TUI.Highlight.elixir(block.code), "\n"), state, &push_line(&2, &1))

    state =
      case block.result do
        nil ->
          state

        result ->
          state
          |> push_line("\e[36m└─⎿\e[0m 完整结果")
          |> then(fn s -> Enum.reduce(String.split(result, "\n"), s, &push_line(&2, &1)) end)
      end

    count = length(state.lines) - start
    %{state | expanded: Map.put(state.expanded, block.id, {start, count})}
  end

  defp collapse_block(state, block_id) do
    case Map.get(state.expanded, block_id) do
      nil ->
        state

      {start, count} ->
        {head, tail} = Enum.split(state.lines, start)
        lines = head ++ Enum.drop(tail, count)

        # 移除区间之后的其它展开块，起始索引同步下移 count
        expanded =
          state.expanded
          |> Map.delete(block_id)
          |> Enum.reduce(%{}, fn {id, {s, c}}, acc ->
            if s > start, do: Map.put(acc, id, {s - count, c}), else: Map.put(acc, id, {s, c})
          end)

        # 删除区间之后若有思考块占位行，其索引同步前移 count
        think_lines =
          Enum.reduce(state.think_lines, %{}, fn {id, tidx}, acc ->
            if tidx > start, do: Map.put(acc, id, tidx - count), else: Map.put(acc, id, tidx)
          end)

        %{state | lines: lines, expanded: expanded, think_lines: think_lines}
    end
  end

  # ── 工具块卡片（渲染逻辑在 Newbee.TUI.Cards，TUI/CLI 共用）──

  defp tool_block_line(block) do
    header = Newbee.TUI.Cards.tool_header(block.name, block.title)
    header <> (Newbee.TUI.Cards.tool_preview(block.code) || "")
  end

  # ── 渲染 ──

  defp schedule_paint(state) do
    now = System.monotonic_time(:millisecond)
    # 16ms≈60fps，忙时 spinner 每帧都有机会转；闲时 30ms 也够平滑
    thresh = if state.busy, do: 16, else: 30

    if now - state.last_paint > thresh do
      send(self(), {:paint, :now})
      %{state | last_paint: now}
    else
      unless state.render_pending do
        Process.send_after(self(), {:paint, :now}, thresh + 5)
      end

      %{state | render_pending: true}
    end
  end

  defp paint(state, force \\ false) do
    # spinner 动画：忙时每帧递增，闲时归零
    state = if state.busy, do: %{state | spinner_idx: state.spinner_idx + 1}, else: %{state | spinner_idx: 0}
    # 绑定缓存：busy 时跳过查询，避免 GenServer 排队卡 paint；闲时 500ms TTL
    {_, state} = cached_bindings(state)
    {cols, rows} = terminal_size()
    {input_view, cur_row, cur_col} = input_view(state)
    input_rows = max(String.split(input_view, "\n") |> length(), 1)
    line_no = rows - input_rows + cur_row
    status = {status_line(state), {line_no, cur_col}}
    lines = state.lines ++ pane_lines(state.pane, state) ++ picker_lines(state.picker)

    screen =
      if state.screen == nil or force or state.screen.cols != cols or state.screen.input_rows != input_rows do
        Screen.paint_full(state.out, lines, input_view, status, cols, rows, state.page)
      else
        Screen.paint_delta(state.screen, lines, input_view, status, cols, rows, state.page)
      end

    %{state | screen: screen, render_pending: false}
  end

  # Ctrl-T 窗格：绑定清单 / 事件日志 / 工具块

  defp pane_lines(:bindings, state) do
    # 模型/工具运行时 evaluator 正在占用 GenServer，不排队同步查询。
    bs = if state.busy, do: [], else: safe_bindings_summary() || []
    ["\e[1;36m[窗格] 绑定 (#{length(bs)})\e[0m" | Enum.map(bs, &"  #{&1.name} : #{&1.type} (#{&1.size} bytes)")]
  end

  defp pane_lines(:events, _state) do
    events = Newbee.EventLog.read(20)

    [
      "\e[1;36m[窗格] 事件日志 (最近 20)\e[0m"
      | Enum.map(events, &"  [#{&1["topic"]}] #{inspect(&1["event"]) |> String.slice(0, 60)}")
    ]
  end

  defp pane_lines(:tools, state) do
    blocks = Map.values(state.tool_blocks)

    [
      "\e[1;36m[窗格] 工具块 (#{length(blocks)})\e[0m"
      | Enum.map(blocks, &"  #{&1.name}: #{&1.title} (#{String.slice(to_string(&1.code || ""), 0, 60)})")
    ]
  end

  defp pane_lines(:queue, state) do
    lines =
      state.pending_inputs
      |> Enum.with_index(1)
      |> Enum.map(fn {text, i} -> "  [#{i}] #{String.slice(text, 0, 200)}" end)

    ["\e[1;36m[窗格] 输入队列 (#{length(lines)})\e[0m" | lines]
  end

  defp pane_lines(nil, _state), do: []

  defp picker_lines(nil), do: []

  defp picker_lines(%{items: items, index: index}) do
    header = "\e[1;33m[会话选择] ↑/↓ 移动 · Enter 恢复 · Esc 取消 (#{length(items)})\e[0m"

    rows =
      items
      |> Enum.with_index()
      |> Enum.map(fn {meta, i} ->
        marker = if i == index, do: "\e[36m❯\e[0m", else: " "
        "#{marker} [#{i + 1}] #{meta.id} · #{meta.when_str} · #{meta.messages} 条 · #{meta.title}"
      end)

    [header | rows]
  end

  defp notify(title, msg) do
    # 桌面通知（可选）：长任务完成提醒，失败静默
    case System.find_executable("notify-send") do
      nil -> :ok
      _ -> spawn(fn -> System.cmd("notify-send", [title, msg], stderr_to_stdout: true) end)
    end

    :ok
  end

  # 首帧可能早于 evaluator peer 完成启动；状态栏/窗格不能把一次超时升级成 TUI 崩溃。
  defp safe_bindings_summary do
    case Newbee.Environment.EvaluatorPool.current() || Process.whereis(Newbee.DEE.Evaluator) do
      nil ->
        nil

      pid ->
        try do
          case Newbee.DEE.Evaluator.bindings_summary(pid, 50) do
            bs when is_list(bs) -> bs
            _ -> nil
          end
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end
    end
  end

  defp now_hm do
    {{_, _, _}, {h, m, _}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()
  end

  defp format_duration(secs) when secs > 0 and secs < 0.05, do: "<0.1s"
  defp format_duration(secs) when secs < 60, do: :io_lib.format("~.1fs", [secs]) |> IO.iodata_to_binary()

  defp format_duration(secs) do
    m = trunc(secs / 60)
    s = secs - m * 60
    :io_lib.format("~wm ~.1fs", [m, s]) |> IO.iodata_to_binary()
  end

  defp help_text do
    "help: Enter send | Esc interrupt | Tab complete | Ctrl-A/E home/end | Alt-B/F word jump\n" <>
      "      Ctrl-U/K cut | Ctrl-Y paste | Ctrl-W/Alt-D delete word | PgUp/Dn scroll | Ctrl-T pane | /reasoning 思考流 | Ctrl-R 历史搜索"
  end

  # 强制刷新一次 bindings（tool_result/turn_end 后调用：求值器此刻空闲，查询不会排队超时）。
  # 查询期间临时放开 busy 只是为了允许 bindings_summary；不能把该临时状态泄回 TUI，
  # 否则自主目标每次工具返回后都会被显示成“空闲”，用户会误以为驱动停止。
  defp refresh_bindings(state) do
    was_busy = state.busy
    {bs, _query_state} = cached_bindings(%{state | bindings_cache_at: 0, busy: false})
    %{state | bindings_cache: bs, bindings_cache_at: System.monotonic_time(:millisecond), busy: was_busy}
  end

  # 缓存 bindings（500ms TTL + busy 时跳过查询，避免每帧 GenServer.call 卡 paint）
  @bindings_ttl 500
  defp cached_bindings(state) do
    now = System.monotonic_time(:millisecond)

    if state.busy do
      {state.bindings_cache, state}
    else
      if state.bindings_cache_at != 0 and now - state.bindings_cache_at < @bindings_ttl and state.bindings_cache != nil do
        {state.bindings_cache, state}
      else
        case safe_bindings_summary() do
          nil ->
            {state.bindings_cache || [], state}

          bs ->
            {bs, %{state | bindings_cache: bs, bindings_cache_at: now}}
        end
      end
    end
  end

  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  defp spinner(state) do
    if state.busy, do: Enum.at(@spinner, rem(state.spinner_idx, length(@spinner))) <> " ", else: ""
  end

  defp status_line(state) do
    bs = state.bindings_cache || []
    bindings = length(bs)
    dots = spinner(state)

    # —— 轮·步 ——
    turns = Map.get(state, :turns, 0)
    steps = Map.get(state, :steps, 0)
    seg_turn = if turns > 0 or steps > 0, do: "#{turns} 轮 · #{steps} 步", else: nil

    # —— LLM/工具耗时（累计 + 忙时含当前段）——
    {live_llm, live_tool} =
      if state.busy do
        now = System.monotonic_time(:millisecond)
        extra_llm = if state.llm_step_start, do: max(now - state.llm_step_start, 0), else: 0
        extra_tool = if state.tool_step_start, do: max(now - state.tool_step_start, 0), else: 0
        {state.llm_ms + extra_llm, state.tool_ms + extra_tool}
      else
        {state.llm_ms, state.tool_ms}
      end

    seg_time =
      if live_llm > 0 or live_tool > 0,
        do: "LLM #{format_duration(live_llm / 1000)} · 工具 #{format_duration(live_tool / 1000)}",
        else: nil

    # —— 首 token · 速率 ——
    ft_str = if state.ft_count > 0, do: "首 token #{format_duration(state.ft_sum_ms / state.ft_count / 1000)}", else: nil

    rate_str =
      if live_llm > 0 and state.completion_tokens > 0 do
        "#{Float.round(state.completion_tokens / (live_llm / 1000), 1)} tok/s"
      end

    seg_speed =
      case Enum.reject([ft_str, rate_str], &is_nil/1) do
        [] -> nil
        xs -> Enum.join(xs, " · ")
      end

    # —— 缓存 ——
    cache_str =
      if state.prompt_tokens > 0 do
        pct = state.cached_tokens * 100.0 / state.prompt_tokens
        formatted = :io_lib.format("~.2f", [pct]) |> IO.iodata_to_binary()
        "缓存 " <> formatted <> "% · 写入 " <> human_tok(state.cache_write_tokens)
      end

    # —— 输入/输出 ——
    seg_io =
      if state.prompt_tokens > 0 or state.completion_tokens > 0 do
        "入 #{human_tok(state.prompt_tokens)} · 出 #{human_tok(state.completion_tokens)}"
      end

    segments = Enum.reject([seg_turn, seg_time, seg_speed, cache_str, seg_io], &is_nil/1)
    dashboard = if segments == [], do: nil, else: Enum.join(segments, " | ")

    status_badge =
      cond do
        state.awaiting_permission -> "\e[35m? 等待确认\e[0m"
        state.busy and state.submit_kind == :shell -> "\e[33m$ shell#{elapsed_str(state)}\e[0m"
        state.busy -> "\e[33m▶ 运行#{elapsed_str(state)}\e[0m"
        true -> "\e[32m● 空闲\e[0m"
      end

    page_hint = if state.page > 0, do: " ↕#{state.page}", else: ""
    q = length(state.pending_inputs)
    qpart = if q > 0, do: " q:#{q}", else: ""

    left = "[2m#{dots}#{state.client.model} · newbee[0m"
    right_core = "bind:#{bindings}#{qpart} #{Newbee.Environment.Autonomy.get()}"
    right = "\e[2m#{page_hint}\e[0m#{status_badge}\e[2m #{right_core}\e[0m"

    cols = max(terminal_cols(), 40)
    lw = visible_len(left)
    rw = visible_len(right)
    dw = if dashboard, do: visible_len(dashboard), else: 0

    cond do
      dashboard != nil and cols >= lw + dw + rw + 8 ->
        gap1 = max(div(cols - lw - dw - rw, 2), 1)
        gap2 = max(cols - lw - dw - rw - gap1, 1)
        left <> String.duplicate(" ", gap1) <> "\e[36m" <> dashboard <> "\e[0m" <> String.duplicate(" ", gap2) <> right

      dashboard != nil and cols >= lw + dw + 4 ->
        pad = max(cols - lw - dw - 2, 1)
        left <> String.duplicate(" ", pad) <> "\e[36m" <> dashboard <> "\e[0m"

      true ->
        {left, lw} =
          if cols < lw + rw + 4 do
            visible_left = left |> String.replace(~r/\e\[[0-9;]*m/, "")
            keep = max(cols - rw - 6, 8)
            truncated = String.slice(visible_left, 0, keep) <> "…"
            {"\e[2m#{truncated}\e[0m", keep + 1}
          else
            {left, lw}
          end

        pad = max(cols - lw - rw - 2, 1)
        left <> String.duplicate(" ", pad) <> right
    end
  end

  defp elapsed_str(state) do
    if state.busy and state.turn_started_at do
      secs = (System.monotonic_time(:millisecond) - state.turn_started_at) / 1000
      " #{format_duration(secs)}"
    else
      ""
    end
  end

  defp human_tok(n) when is_integer(n) and n >= 1_000_000_000,
    do: :io_lib.format("~.1fB", [n / 1_000_000_000]) |> IO.iodata_to_binary()

  defp human_tok(n) when is_integer(n) and n >= 1_000_000,
    do: :io_lib.format("~.1fM", [n / 1_000_000]) |> IO.iodata_to_binary()

  defp human_tok(n) when is_integer(n) and n >= 1_000, do: :io_lib.format("~.1fK", [n / 1_000]) |> IO.iodata_to_binary()
  defp human_tok(n), do: to_string(n || 0)
  # 剥 ANSI 后按可见宽度算（用于分栏对齐）
  defp visible_len(s) do
    s |> String.replace(~r/\e\[[0-9;]*m/, "") |> Line.width()
  end

  defp input_view(state) do
    if state.search_mode do
      q = state.search_query
      prefix = "\e[33m(reverse-i-search)`" <> q <> "':\e[0m "
      {prefix <> state.line_ed.text, 0, 2 + Newbee.TUI.Line.width(q) + 2}
    else
      if state.line_ed.text == "" and not state.busy do
        {"\e[2m试试 /model /bindings /compact  ·  @文件  ·  !shell  ·  ?帮助\e[0m", 0, 2}
      else
        prefix = if state.busy, do: "\e[33m…\e[0m ", else: "\e[32m›\e[0m "
        row = Line.cursor_row(state.line_ed)
        {line, cur_col} = Line.scroll_view(state.line_ed, terminal_cols() - 4)
        # 多行：第一行带前缀，后续行两空格缩进
        text =
          line
          |> String.split("\n")
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {l, i} -> if i == 0, do: prefix <> l, else: "  " <> l end)

        {text, row, 2 + cur_col}
      end
    end
  end

  defp terminal_size do
    # erl -noshell 下无法 ioctl；尺寸由 bin/newbee 探测注入（NEWBEE_ROWS/COLS），
    # 回退到交互 shell 的 COLUMNS/LINES，最后 80x24
    cols = int_env("NEWBEE_COLS") || int_env("COLUMNS") || 80
    rows = int_env("NEWBEE_ROWS") || int_env("LINES") || 24
    {cols, rows}
  end

  defp terminal_cols do
    int_env("NEWBEE_COLS") || int_env("COLUMNS") || 80
  end

  defp int_env(name) do
    case System.get_env(name) do
      nil ->
        nil

      "" ->
        nil

      v ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
    end
  end

  defp tty? do
    case :file.read_link(~c"/proc/self/fd/0") do
      {:ok, target} ->
        target = List.to_string(target)
        not String.starts_with?(target, "/dev/null") and not String.starts_with?(target, "pipe")

      _ ->
        true
    end
  end

  defp session_id(kernel) do
    :sys.get_state(kernel).session
    |> case do
      nil -> "(off)"
      s -> s.id
    end
  end
end
