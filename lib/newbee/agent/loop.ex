defmodule Newbee.Agent.Loop do
  @moduledoc """
  主循环 (DESIGN §4.1)：组装 prompt → LLM → run_elixir → 压缩回填 → 循环，
  直到 done / ask / 无工具调用。每轮事件通过 render 回调流出。
  """
  use GenServer

  defstruct messages: [],
            client: nil,
            evaluator: nil,
            render: nil,
            client_fun: nil,
            usage: %{},
            steps: 0,
            session: nil,
            progress: nil,
            goal: nil,
            auto_antibodies: false,
            error_sigs: %{},
            advisor: nil,
            advisor_client: nil,
            context_window: 128_000,
            compaction_threshold: 0.8,
            compaction_retain: 0.16,
            compaction_max_tokens: 1_024,
            auto_compact: true,
            # 会话工作目录根（WebUI 选定）；nil = 主节点 File.cwd!
            root: nil,
            # 宿主进程 monitor 引用（web 会话进程）；宿主死亡 → kernel 自停，
            # 链式触发会话私有求值器释放（见 evaluator_owned / Evaluator.monitor_owner）
            owner: nil

  # ── API ──

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "提交一段用户输入，同步执行整个 turn，返回 {:done, summary} | {:ask, q} | {:text, body} | {:error, e}"
  def submit(kernel, text), do: GenServer.call(kernel, {:submit, text}, :infinity)
  @doc "提交多张 data URL 图片 + 文本给视觉模型分析（WebUI 多模态入口）。"
  def submit_images(kernel, data_urls, text \\ ""),
    do: GenServer.call(kernel, {:submit_images, data_urls, text}, :infinity)

  @doc "提交本地图片给视觉模型分析。"
  def submit_image(kernel, path, prompt \\ nil), do: GenServer.call(kernel, {:submit_image, path, prompt}, :infinity)
  @doc "设定自主目标（/goal）：注入目标并异步启动自主循环，直到达成/取消/达上限。"
  def set_goal(kernel, text, opts \\ []), do: GenServer.call(kernel, {:set_goal, text, opts}, :infinity)

  @doc "清除自主目标（/goal clear）。"
  def clear_goal(kernel), do: GenServer.call(kernel, :clear_goal)

  @doc "查询自主目标状态：nil | %{text, rounds, max_rounds, idle}。"
  def goal(kernel), do: GenServer.call(kernel, :goal)

  def usage(kernel), do: GenServer.call(kernel, :usage)

  @doc "热切模型：不丢会话/绑定/消息，只换 LLM client 与流式入口。返回 :ok | {:error, reason}。"
  def switch_model(kernel, client) when is_map(client) do
    GenServer.call(kernel, {:switch_model, client}, 5_000)
  end

  @doc """
  热更新上下文窗口（WebUI 模型弹窗实时生效）。n 为正整数覆盖值；nil 清除覆盖，
  回退 provider 元数据自动探测。不触发 model_switched 事件，只更新压缩阈值口径。
  """
  def set_context_window(kernel, n) when is_integer(n) and n > 0 do
    GenServer.call(kernel, {:set_context_window, n}, 15_000)
  end

  def set_context_window(kernel, nil), do: GenServer.call(kernel, {:set_context_window, nil}, 15_000)

  @doc "中断本会话的模型请求或代码求值（会话级隔离，不影响其它会话）。"
  def interrupt(kernel) do
    # 非阻塞控制面：不能向正在 handle_call/2 中运行的 Loop 发 call。
    # 直接查 SessionEvaluators 拿本会话的 {evaluator, scope}：
    # ① LLM 中断：置位本会话 scope 的 persistent_term flag（其它会话无此 scope）；
    # ② Eval 中断：杀本会话 evaluator 的当前 cell。
    case Newbee.SessionEvaluators.lookup(kernel) do
      {:ok, {evaluator, scope}} ->
        if scope, do: :persistent_term.put({Newbee.LLM.Client, {:interrupt, scope}}, true)
        Newbee.DEE.Evaluator.interrupt(evaluator)

      {:ok, evaluator} when is_pid(evaluator) ->
        Newbee.DEE.Evaluator.interrupt(evaluator)

      :error ->
        :ok
    end

    # 兜底：查表失败（evaluator 非 pid / 未注册）时，从 kernel state 拿 client scope
    # 直接置 LLM flag。:sys.get_state 在 Loop 忙时会排队，用短超时保护不阻塞控制面。
    if Process.alive?(kernel) do
      try do
        state = :sys.get_state(kernel, 200)
        scope = Map.get(state.client, :interrupt_scope)
        if scope, do: :persistent_term.put({Newbee.LLM.Client, {:interrupt, scope}}, true)
      catch
        :exit, _ -> :ok
      end
    end

    # 双保险：同时给 kernel 发消息，Loop 处理 mailbox 时用自己的 client 自置 flag。
    if Process.alive?(kernel), do: send(kernel, :interrupt_llm)

    :ok
  end

  @doc "压缩对话历史（/compact，§9/§6.5）：旧消息 LLM 摘要，保留最近 8 条原文。"
  def compact(kernel), do: GenServer.call(kernel, :compact, 300_000)

  @impl true
  def init(opts) do
    client = Keyword.fetch!(opts, :client)
    render = Keyword.get(opts, :render, fn _ -> :ok end)
    evaluator = Keyword.get(opts, :evaluator, Newbee.DEE.Evaluator)
    root = Keyword.get(opts, :root)

    # 会话级隔离：每个会话一个中断 scope（注入 client），evaluator 注册到
    # SessionEvaluators（key = 本 Loop pid），interrupt 只作用本会话。
    client =
      if Map.get(client, :interrupt_scope),
        do: client,
        else: Map.put(client, :interrupt_scope, Newbee.LLM.Client.new_interrupt_scope())

    if is_pid(evaluator), do: Newbee.SessionEvaluators.register(self(), {evaluator, Map.get(client, :interrupt_scope)})

    # 资源随会话释放（epmd 残留事故修复）：
    # 1. owner（web 会话进程）死亡（删除会话/崩溃）→ 本 kernel 自停（见 handle_info DOWN）；
    # 2. evaluator_owned: true 时把本 kernel 登记为求值器宿主，kernel 停止/崩溃
    #    → 求值器自停 → terminate 停掉 primary/standby peer 节点。
    #    具名共享兜底求值器（Newbee.DEE.Evaluator）绝不可标 owned——会误杀其它会话。
    owner_ref =
      case Keyword.get(opts, :owner) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    if Keyword.get(opts, :evaluator_owned, false) and is_pid(evaluator) do
      Newbee.DEE.Evaluator.monitor_owner(evaluator, self())
    end

    client_fun =
      Keyword.get(opts, :client_fun, fn messages, on_text, on_reasoning ->
        Newbee.LLM.Client.stream_chat(client, messages, on_text, on_reasoning)
      end)

    # 进度监控（LLM-as-a-Verifier 落地）：每 every 步对轨迹前缀打连续分，
    # 停滞时注入干预提醒。client 默认走 model.json 的 verifier role（无则回退 default）。
    progress =
      case Keyword.get(opts, :progress, false) do
        false ->
          nil

        p when is_map(p) or is_list(p) ->
          %{
            client: Map.get(p, :client) || Newbee.LLM.Config.client_for("verifier"),
            every: Map.get(p, :every, 5),
            scale: Map.get(p, :scale, :letters),
            window: Map.get(p, :window, 5),
            min_steps: Map.get(p, :min_steps, 3),
            threshold: Map.get(p, :threshold, 0.0),
            complete_fn: Map.get(p, :complete_fn),
            final_check: Map.get(p, :final_check, false),
            done_threshold: Map.get(p, :done_threshold, 12),
            final_checked: false,
            final_score: nil,
            scores: [],
            injected: false
          }
      end

    session =
      if Keyword.get(opts, :session, true) do
        s = Newbee.Session.open(Keyword.get(opts, :session_id))
        # 恢复 = 物化视图重建（§4.6）：transcript 只增不删，压缩只是账本上的切点；
        # 视图 = 基底 + 段汇总消息 + 切点后原文。无压缩账本的旧会话逐字节兼容。
        prior =
          try do
            s |> Newbee.Archive.view() |> repair_history()
          rescue
            _ -> s |> Newbee.Session.messages() |> repair_history()
          end

        {s, prior}
      else
        {nil, []}
      end

    {session, prior_messages} = session

    # J-Space：登记当前会话，供 Newbee.Tools.JSpace 定位 ledger
    if session, do: Newbee.Session.set_current(session.id)

    # 恢复会话：消息已载入，绑定灌回求值器（tombstone 项自然跳过；ETF 优先，死句柄仅值还原）
    if session && prior_messages != [] do
      bindings = Newbee.Session.load_bindings(session)

      if bindings != [] do
        Newbee.DEE.Evaluator.restore_bindings(evaluator, bindings)
      end

      # 跨版/环境差异提示：beam_snapshot.json 与当前 OTP/Elixir 不一致时在日志留痕
      check_beam_snapshot(session)
    end

    prompt =
      case session do
        nil ->
          system_prompt(root)

        session ->
          Newbee.Session.system_prompt(session) || Newbee.Session.save_system_prompt(session, system_prompt(root))
      end

    # 同一 session 的 system prompt 是请求头：首次生成后持久化，恢复时逐字复用。
    # 历史消息只追加，因而后续请求可作为上一次请求的 provider cache prefix extension。
    # advisor（§3.8 可选第三角色）：只读旁观的第二模型，默认关闭
    advisor =
      case Keyword.get(opts, :advisor, false) do
        false -> nil
        true -> Newbee.LLM.Config.client_for("advisor")
      end

    # J-Space 恢复协议：会话边界 = 长间隔，有 ledger 则注入恢复提醒（§?）
    recovery =
      if session && prior_messages != [] && Newbee.Tools.JSpace.exists?(session.id) do
        [%{"role" => "system", "content" => jspace_recovery_reminder()}]
      else
        []
      end

    {:ok,
     %__MODULE__{
       messages: [%{"role" => "system", "content" => prompt}] ++ recovery ++ prior_messages,
       client: client,
       evaluator: evaluator,
       owner: owner_ref,
       render: render,
       client_fun: client_fun,
       session: session,
       progress: progress,
       auto_antibodies: Keyword.get(opts, :auto_antibodies, false),
       advisor: advisor,
       advisor_client: advisor,
       context_window: Keyword.get_lazy(opts, :context_window, fn -> Newbee.LLM.Client.context_window(client) end),
       compaction_threshold: Keyword.get(opts, :compaction_threshold, 0.8),
       compaction_retain: Keyword.get(opts, :compaction_retain, 0.16),
       compaction_max_tokens: Keyword.get(opts, :compaction_max_tokens, 1_024),
       auto_compact: Keyword.get(opts, :auto_compact, true),
       root: Keyword.get(opts, :root)
     }}
  end

  @impl true
  def handle_call({:submit_image, _path, _prompt}, _from, %{client: %{vision: false}} = state) do
    {:reply, {:error, {:image, :vision_not_supported}}, state}
  end

  def handle_call({:submit_image, path, prompt}, _from, state) do
    case Newbee.LLM.Image.message(path, prompt) do
      {:ok, message} ->
        submit_message(state, message)

      {:error, reason} ->
        {:reply, {:error, {:image, reason}}, state}
    end
  end

  def handle_call({:submit_images, _data_urls, _text}, _from, %{client: %{vision: false}} = state) do
    {:reply, {:error, {:image, :vision_not_supported}}, state}
  end

  def handle_call({:submit_images, data_urls, text}, _from, state) do
    case Newbee.LLM.Image.message_with_images(data_urls, text) do
      {:ok, message} ->
        submit_message(state, message)

      {:error, reason} ->
        {:reply, {:error, {:image, reason}}, state}
    end
  end

  def handle_call({:submit, text}, _from, state) do
    submit_message(state, %{"role" => "user", "content" => text})
  end

  def handle_call(:usage, _from, state), do: {:reply, state.usage, state}

  def handle_call(:compact, _from, state) do
    {state, count} = compact_state(state, 8)
    {:reply, {:ok, count}, state}
  end

  def handle_call({:set_goal, text, opts}, _from, state) do
    text = String.trim(text)
    max_rounds = Keyword.get(opts, :max_rounds, 50)

    if text == "" do
      {:reply, {:error, :empty_goal}, state}
    else
      state =
        state
        |> inject_prompt(%{"role" => "system", "content" => goal_system_prompt(text)}, %{
          source: "goal_start",
          reason: "启动自主目标模式",
          timing: "current_turn"
        })
        |> push_msg(%{"role" => "user", "content" => "（自主目标模式启动）目标：#{text}\n请开始自主工作，直到达成目标。"})

      goal = %{
        text: text,
        rounds: 0,
        max_rounds: max_rounds,
        idle: 0,
        msg_len: length(state.messages),
        error_retries: 0,
        max_error_retries: Keyword.get(opts, :max_error_retries, 3),
        retry_delay: Keyword.get(opts, :retry_delay, 250)
      }

      emit(state, {:goal_start, text})
      send(self(), :goal_next)
      {:reply, :ok, %{state | goal: goal}}
    end
  end

  def handle_call(:clear_goal, _from, state) do
    if state.goal, do: emit(state, {:goal_cancelled, :user})
    {:reply, :ok, %{state | goal: nil}}
  end

  def handle_call(:goal, _from, state), do: {:reply, state.goal, state}

  def handle_call({:switch_model, client}, _from, state) do
    # 不丢会话/绑定/消息/中断 scope，仅替换后续 turn 所用的 client 与 client_fun。
    # 求值器节点不动，当前 turn 仍用旧 client 完成，下次 submit 即生效。
    client = Map.put(client, :interrupt_scope, Map.get(state.client, :interrupt_scope))

    client_fun = fn messages, on_text, on_reasoning ->
      Newbee.LLM.Client.stream_chat(client, messages, on_text, on_reasoning)
    end

    emit(state, {:model_switched, client.model})

    {:reply, :ok,
     %{state | client: client, client_fun: client_fun, context_window: Newbee.LLM.Client.context_window(client)}}
  end

  # 热更新上下文窗口（contextWindows 覆盖变更实时生效）：只替换 client 上的
  # context_window 字段并重算压缩口径；不发 model_switched，不动其它状态。
  # n = nil 表示清除覆盖，回退 provider 元数据/默认 256K。
  def handle_call({:set_context_window, n}, _from, state) do
    client = Map.put(state.client, :context_window, n)

    client_fun = fn messages, on_text, on_reasoning ->
      Newbee.LLM.Client.stream_chat(client, messages, on_text, on_reasoning)
    end

    {:reply, :ok,
     %{state | client: client, client_fun: client_fun, context_window: Newbee.LLM.Client.context_window(client)}}
  end

  defp submit_message(state, message) do
    # 注意：不能在回合开始清中断标志——execute_calls 阶段的中断检查依赖它。
    # 热加载中的 Loop 可能已持有启动前写入的空 assistant；提交前清掉，避免再次触发上游 400。
    t0 = :erlang.monotonic_time(:millisecond)
    state = %{state | messages: repair_history(drop_empty_assistant_messages(state.messages))}
    state = push_msg(state, message)
    state = maybe_history_recall(state, message)
    # 回合开始清本会话中断标志（per-session scope，无跨会话竞态）。
    # 标志语义 = "本回合内是否收到 Esc"；execute_calls 阶段的中断检查依赖它。
    Newbee.LLM.Client.clear_interrupt(state.client)
    {reply, state} = run_turn(state, 1)
    {reply, state} = after_turn(reply, state)
    persist_bindings(state)
    ms = :erlang.monotonic_time(:millisecond) - t0
    Newbee.DebugLog.log(:submit, "done in #{ms}ms reply=#{elem(reply, 0)}")
    emit(state, {:turn_end, elem(reply, 0), ms})
    flush_bus()
    {:reply, reply, state}
  end

  # 自主目标循环：异步驱动（每轮之间可处理 mailbox，/goal clear 可插入取消）。
  @impl true
  # 宿主（web 会话进程）死亡：kernel 自停；会话私有求值器经 monitor_owner 链式随停。
  # GenServer.stop 的 :normal 退出不会经 link 传播，必须靠这个 monitor 兜底。
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner: ref} = state) when ref != nil do
    Newbee.DebugLog.log(:kernel, "owner down reason=#{inspect(reason)}; stopping kernel")
    {:stop, :normal, state}
  end

  def handle_info(:interrupt_llm, state) do
    scope = Map.get(state.client, :interrupt_scope)
    if scope, do: :persistent_term.put({Newbee.LLM.Client, {:interrupt, scope}}, true)
    {:noreply, state}
  end

  def handle_info(:goal_next, state) do
    if state.goal do
      Newbee.LLM.Client.clear_interrupt(state.client)
      {reply, state} = run_turn(state, 1)
      {_reply, state} = after_turn(reply, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  rescue
    e ->
      Newbee.DebugLog.log(:goal, "goal loop crashed: #{inspect(e)}")
      emit(state, {:goal_cancelled, :crash})
      {:noreply, %{state | goal: nil}}
  end

  # ── 自主目标（/goal）：turn 出口统一处理 ──

  # 非目标模式：原样返回
  defp after_turn(reply, %{goal: nil} = state), do: {reply, state}

  # 目标模式：模型以纯文本结束 → 自动开始下一轮（轮数上限 + 停滞提醒保护）
  defp after_turn({:text, content}, state) do
    g = state.goal
    added = Enum.slice(state.messages, g.msg_len, length(state.messages) - g.msg_len)
    idle = if Enum.any?(added, &(&1["role"] == "tool")), do: 0, else: g.idle + 1
    rounds = g.rounds + 1
    state = %{state | goal: %{g | rounds: rounds, idle: idle, error_retries: 0}}

    if rounds >= g.max_rounds do
      emit(state, {:goal_limit, g.max_rounds})
      {{:goal_limit, g.max_rounds}, %{state | goal: nil}}
    else
      emit(state, {:goal_round, rounds})

      state =
        if idle >= 3 do
          inject_prompt(state, %{"role" => "system", "content" => goal_idle_reminder(rounds)}, %{
            source: "goal_idle",
            reason: "自主目标连续多轮没有工具进展",
            timing: "next_request",
            round: rounds
          })
          |> then(fn s -> %{s | goal: %{s.goal | idle: 0}} end)
        else
          state
        end

      state =
        inject_prompt(state, %{"role" => "system", "content" => goal_continue_msg(rounds)}, %{
          source: "goal_continue",
          reason: "自主目标尚未确认完成",
          timing: "next_request",
          round: rounds
        })
        |> then(fn s -> %{s | goal: %{s.goal | msg_len: length(s.messages)}} end)

      send(self(), :goal_next)
      {{:text, content}, state}
    end
  end

  defp after_turn({:done, summary}, state) do
    emit(state, {:goal_done, summary})
    maybe_extract_lesson(state, summary)
    {{:done, summary}, %{state | goal: nil}}
  end

  defp after_turn({:ask, question}, state) do
    # 目标保留：用户回答后的 submit 出口会自动续跑
    emit(state, {:goal_ask, question})
    {{:ask, question}, %{state | goal: %{state.goal | error_retries: 0}}}
  end

  defp after_turn({:interrupted, content}, state) do
    emit(state, {:goal_cancelled, :interrupted})
    {{:interrupted, content}, %{state | goal: nil}}
  end

  defp after_turn({:error, e}, state) do
    g = state.goal

    if retryable_goal_error?(e) and g.error_retries < g.max_error_retries do
      retries = g.error_retries + 1
      state = %{state | goal: %{g | error_retries: retries}}
      emit(state, {:goal_retry, retries})
      Process.send_after(self(), :goal_next, g.retry_delay)
      {{:error, e}, state}
    else
      emit(state, {:goal_cancelled, :error})
      {{:error, e}, %{state | goal: nil}}
    end
  end

  defp retryable_goal_error?({:stream_error, _reason, _content}), do: true
  defp retryable_goal_error?({:stream_error, _reason}), do: true
  defp retryable_goal_error?({:upstream_error, _reason}), do: true
  defp retryable_goal_error?(:upstream_error), do: true

  defp retryable_goal_error?({:http_error, status, _body}) when status in [400, 408, 425, 429, 500, 502, 503, 529],
    do: true

  defp retryable_goal_error?({:http_error, _status, _body}), do: false
  defp retryable_goal_error?({:error, %Req.TransportError{}}), do: true
  defp retryable_goal_error?(_), do: false

  defp goal_system_prompt(text) do
    """
    [自主目标模式] 你被赋予一个明确的完成目标，需要自主、持续地工作直到达成。

    目标：#{text}

    工作纪律：
    - 持续工作：一轮结束后若目标未达成，系统会自动开启下一轮，无需等待用户。
    - 每轮要有实质进展：运行代码、跑测试、修改文件、验证结果。
    - 达成目标后：调用 done 工具，附上完成总结（做了什么、如何验证）。
    - 未达成前不要调用 done，也不要仅用文字结束回合。
    - 确实需要用户决策时用 ask；能自主解决的就自主解决。
    """
  end

  defp goal_continue_msg(round) do
    "（自主模式第 #{round} 轮：目标未确认达成，请继续工作。达成后调用 done 并附总结。）"
  end

  defp goal_idle_reminder(round) do
    "（自主模式第 #{round} 轮：你已连续多轮没有调用工具、没有实质进展。" <>
      "请立即采取行动：检查/运行/修改/验证。若目标已达成请调用 done。）"
  end

  # ── 档案召回（查询感知 rehydration，§6.6）──

  # 用户输入与已压缩档案强相关时，注入一行指针提示（只指路，不推载荷——
  # 细节仍走 Newbee.read("history://…") 拉取，光头原则不破）。
  # 确定性打分（词元命中数），无档案/词元不足/求值失败一律静默跳过。
  defp maybe_history_recall(%{session: nil} = state, _message), do: state

  defp maybe_history_recall(state, message) do
    text = message["content"]

    with %{session: session} <- state,
         true <- is_binary(text) and byte_size(text) >= 12,
         true <- Newbee.Archive.archived?(session),
         hits when is_list(hits) and hits != [] <- Newbee.Archive.recall(session, text) do
      inject_prompt(state, %{"role" => "system", "content" => recall_hint(hits)}, %{
        source: "history_recall",
        reason: "用户输入命中已压缩档案",
        timing: "current_turn",
        hits: length(hits)
      })
    else
      _ -> state
    end
  rescue
    _ -> state
  end

  defp recall_hint(hits) do
    "[档案召回] 你这条输入与已压缩的早期对话相关。需要细节时拉取：" <>
      "Newbee.read(\"history://s/<段id>\") 看该段摘要，Newbee.read(\"history://q/关键词\") 检索全文。\n" <>
      Enum.map_join(hits, "\n", &"  #{&1}")
  end

  # ── turn 循环 ──

  # 步数不设硬上限（§8 放行+审计：硬杀会误伤长任务，如自改代码）。
  # 失控保护 = 每 25 步审计告警（事件流可见，用户可 Ctrl-C）。
  defp run_turn(state, step) do
    if rem(step, 25) == 0 do
      Newbee.DebugLog.log(:turn, "step #{step}: long turn (uncapped, audited)")
      emit(state, {:turn_long, step})
    end

    state = maybe_auto_compact(state)
    state = %{state | messages: repair_history(state.messages)}
    Newbee.DebugLog.log(:turn, "step #{step} messages=#{length(state.messages)}")
    on_text = fn delta -> emit(state, {:text, delta}) end
    on_reasoning = fn delta -> emit(state, {:reasoning, delta}) end

    # I1：记录本次路由请求的可缓存前缀快照（Archive 摘要路径消费）。
    # 标准 LLM client + 会话才写；注入函数/无会话 no-op。
    Newbee.RequestEnvelope.record(state.session, state.client, state.messages)

    case call_client(state.client_fun, state.messages, on_text, on_reasoning) do
      {:ok, msg, usage} ->
        Newbee.DebugLog.log(:turn, "step #{step} llm ok calls=#{length(msg["tool_calls"] || [])}")
        emit(state, {:usage, Map.put(usage, "model", client_model(state.client))})
        state = %{state | usage: merge_usage(state.usage, usage)}

        # 上游（DeepSeek/OpenRouter 系）拒绝 content 为空的 assistant 消息（400）：
        # 模型偶发返回"空正文且无工具调用"（只吐思考流/空串），该消息一旦落进
        # transcript，后续整个历史请求都会 400 卡死。空回复无信息量，不进历史
        # （同时也保持原 msg 继续走下方空文本回合结束逻辑）。
        state =
          if empty_assistant_msg?(msg) do
            Newbee.DebugLog.log(:turn, "step #{step} empty assistant response dropped")
            state
          else
            push_msg(state, msg)
          end

        case Newbee.Codec.extract_tool_calls(msg) do
          [] ->
            # 降级通道 (§4.2)：模型偶发在正文输出 ```elixir 代码块时容错执行
            case Newbee.Codec.FallbackParser.extract(msg["content"] || "") do
              {[], _cleaned} ->
                Newbee.DebugLog.log(:turn, "step #{step} no tool calls, turn end")

                # 流监控（§4.5）：正文 + 思考流一并检查沉睡规则（scope 分流见 stream_rule_hits）
                case stream_rule_hits(msg) do
                  [] ->
                    {{:text, msg["content"]}, state}

                  hits ->
                    # 沉睡规则命中正文（§4.5 流监控）：注入提醒，模型下轮纠正
                    emit(state, {:rule_hit, hits})
                    # 规则命中热度（§8.5 profiling 输入）
                    Newbee.Environment.UsageTracker.observe_rules(hits)
                    injections = Enum.map_join(hits, "\n", &("- [" <> &1.id <> "] " <> &1.injection))
                    reminder = %{"role" => "system", "content" => "[沉睡规则注入] " <> injections}

                    state =
                      inject_prompt(state, reminder, %{
                        source: "sleeping_rule",
                        reason: "模型可见正文或隐藏思考流命中沉睡规则",
                        timing: "next_user_turn",
                        step: step,
                        trigger: visible_rule_trigger(msg["content"] || "", hits),
                        rules: rule_audit_details(hits)
                      })

                    {{:text, msg["content"]}, state}
                end

              {blocks, cleaned} ->
                Newbee.DebugLog.log(:turn, "step #{step} fallback: #{length(blocks)} elixir blocks")
                execute_fallback(blocks, cleaned, state, step)
            end

          calls ->
            case execute_calls(calls, state) do
              {:halt, reply, state} -> {reply, state}
              {:cont, state} -> run_turn(state, step + 1)
            end
        end

      {:interrupted, content} ->
        # Esc 中断：终止整个 turn（部分生成的 assistant 消息不入历史，
        # 避免悬空 tool_calls 触发 DeepSeek 400）
        Newbee.DebugLog.log(:turn, "step #{step} interrupted")
        emit(state, {:interrupted, content})
        {{:interrupted, content}, state}

      {:error, e} ->
        Newbee.DebugLog.log(:turn, "step #{step} llm error #{inspect(e)}")
        emit(state, {:error, e})
        {{:error, e}, state}
    end
  end

  # 降级通道：执行正文里的 elixir 块（按 run_elixir 语义），结果回填后继续循环 + 温和纠偏
  defp execute_fallback(blocks, cleaned, state, step) do
    result =
      Enum.reduce_while(blocks, {:cont, state, []}, fn code, {:cont, st, acc} ->
        if Newbee.LLM.Client.interrupted?(st.client) do
          emit(st, {:interrupted, nil})
          {:halt, {:halt, {:interrupted, nil}, st}}
        else
          emit(st, {:tool_start, "run_elixir(fallback)", "", code})
          tool_started_at = System.monotonic_time(:millisecond)
          eval_result = Newbee.DEE.Evaluator.eval(st.evaluator, code)

          if Newbee.LLM.Client.interrupted?(st.client) or eval_interrupted?(eval_result) do
            emit(st, {:interrupted, nil})
            {:halt, {:halt, {:interrupted, nil}, st}}
          else
            rendered = Newbee.DEE.Result.render(eval_result)
            duration_ms = System.monotonic_time(:millisecond) - tool_started_at
            emit(st, {:tool_result, "run_elixir", rendered, duration_ms})
            tool_msg = %{"role" => "tool", "tool_call_id" => "fallback-#{step}", "content" => rendered}
            {:cont, push_msg(st, tool_msg), acc ++ [eval_result]}
          end
        end
      end)

    case result do
      {:halt, reply, state} ->
        {reply, state}

      {:cont, state, results} ->
        all_ok? = Enum.all?(results, &(&1.status == :ok))

        # 温和纠偏：提示模型用 run_elixir 工具（DESIGN §4.2）
        reminder = %{"role" => "system", "content" => Newbee.Codec.FallbackParser.correction_reminder()}

        state =
          if all_ok? do
            # 全部成功：清理后的正文继续（块已执行）
            if String.trim(cleaned) == "" do
              inject_prompt(state, reminder, %{
                source: "fallback_parser",
                reason: "模型用正文代码块代替 run_elixir 工具调用",
                timing: "current_turn_retry",
                step: step
              })
            else
              state
              |> push_msg(%{"role" => "assistant", "content" => cleaned})
              |> inject_prompt(reminder, %{
                source: "fallback_parser",
                reason: "模型用正文代码块代替 run_elixir 工具调用",
                timing: "current_turn_retry",
                step: step
              })
            end
          else
            # 有失败：保留原文 + 错误已在 tool 消息里
            state
            |> push_msg(%{"role" => "assistant", "content" => cleaned})
            |> inject_prompt(reminder, %{
              source: "fallback_parser",
              reason: "正文代码块执行失败，要求改用工具调用重试",
              timing: "current_turn_retry",
              step: step
            })
          end

        run_turn(state, step + 1)
    end
  end

  defp call_client(fun, messages, on_text, on_reasoning) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 3} -> fun.(messages, on_text, on_reasoning)
      {:arity, 2} -> fun.(messages, on_text)
    end
  end

  defp execute_calls(calls, state) do
    Enum.reduce_while(calls, {:cont, state}, fn call, {:cont, state} ->
      if Newbee.LLM.Client.interrupted?(state.client) do
        # Esc 中断发生在工具执行阶段：不再发起下一个工具调用
        {:halt, {:halt, {:interrupted, nil}, state}}
      else
        t0 = System.monotonic_time(:millisecond)
        Newbee.DebugLog.log(:tool, "start #{call.name} id=#{call.id} args=#{String.slice(inspect(call.args), 0, 200)}")

        result =
          case call.name do
            "run_elixir" ->
              code = call.args["code"] || ""
              title = call.args["title"] || ""

              case check_rules(code, :code) do
                [] ->
                  # tools/pre-execute 门（§3.2/§4.6 live 拦截点）：
                  # 能力声明校验（物理拒绝）→ Capability Policy（行为策略）
                  case Newbee.Environment.CapabilityGate.check(code) do
                    {:deny, reason} ->
                      rendered = "✗ error\n⛔ 能力门拒绝：#{inspect(reason)}（插件不在 active 图或未声明该能力，§3.2）"
                      emit(state, {:tool_error, rendered})
                      Newbee.Bus.emit(:audit, {:audit, :capability_denied, reason})

                      tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => rendered}
                      {:cont, {:cont, push_msg(state, tool_msg)}}

                    :ok ->
                      check_permissions_and_run(state, call, code, title)
                  end

                hits ->
                  emit(state, {:rule_hit, hits})
                  # 规则命中热度（§8.5 profiling 输入）
                  Newbee.Environment.UsageTracker.observe_rules(hits)
                  injections = Enum.map_join(hits, "\n", &("- [" <> &1.id <> "] " <> &1.injection))

                  tool_msg = %{
                    "role" => "tool",
                    "tool_call_id" => call.id,
                    "content" => "⛔ 未执行——命中环境规则，请先按以下提醒修正再重试:\n" <> injections
                  }

                  reminder = %{
                    "role" => "system",
                    "content" => "[沉睡规则注入] 你刚才的代码命中了以下环境规则:\n" <> injections
                  }

                  state =
                    state
                    |> push_msg(tool_msg)
                    |> inject_prompt(reminder, %{
                      source: "sleeping_rule",
                      reason: "run_elixir 代码命中执行前规则",
                      timing: "current_turn_retry",
                      trigger: String.slice(code, 0, 1_000),
                      rules: rule_audit_details(hits)
                    })

                  {:cont, {:cont, state}}
              end

            "done" ->
              summary = call.args["summary"] || ""
              tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => "✓ done"}

              case final_check(state) do
                {:done, state} ->
                  # emit(:done) 不发——由 WSession broadcast_turn_end 统一发送
                  # 避免前端收到两个 done 事件导致渲染两个空圆点
                  # 持久化 done 总结到 transcript（不入 LLM 历史，仅 UI 历史），
                  # 否则刷新后 session.history 读不到最后一条总结
                  if state.session do
                    Newbee.Session.append(state.session, %{
                      "role" => "assistant",
                      "content" => summary,
                      "done" => true
                    })
                  end

                  # DeepSeek 严格校验：带 tool_calls 的 assistant 后必须跟齐 tool 响应，
                  # 否则下一回合 400（此前 done/ask 从不回填，历史必然悬空）
                  {:halt, {:halt, {:done, summary}, push_msg(state, tool_msg)}}

                {:retry, state, reminder} ->
                  emit(state, {:final_check_low, state.progress.final_score})
                  # 低分：注入提醒 + 让循环继续，模型重新评估后再 done
                  state =
                    state
                    |> push_msg(tool_msg)
                    |> inject_prompt(%{"role" => "user", "content" => reminder}, %{
                      source: "final_verifier",
                      reason: "终局验证分数低于完成阈值",
                      timing: "current_turn_retry",
                      score: state.progress.final_score
                    })

                  {:cont, {:cont, state}}
              end

            "ask" ->
              question = call.args["question"] || ""
              emit(state, {:ask, question})
              tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => "（等待用户回答）"}
              {:halt, {:halt, {:ask, question}, push_msg(state, tool_msg)}}

            other ->
              tool_msg = %{
                "role" => "tool",
                "tool_call_id" => call.id,
                "content" => "✗ unknown tool: #{other}"
              }

              {:cont, {:cont, push_msg(state, tool_msg)}}
          end

        Newbee.DebugLog.log(:tool, "done #{call.name} in #{System.monotonic_time(:millisecond) - t0}ms")
        result
      end
    end)
    |> case do
      {:cont, state} -> {:cont, state}
      {:halt, reply, state} -> {:halt, reply, state}
    end
  end

  # 宽松沙箱（§8 放行+审计）：危险模式不拦，但写事件日志留证
  @dangerous ~w(:init.stop System.halt :erlang.halt :code.delete :code.purge File.rm_rf!)

  # assistant 消息"空"= 无正文（含空白）且无工具调用。上游（DeepSeek/OpenRouter 系）
  # 直接拒绝这类消息（400），它们对模型也毫无信息量。
  defp empty_assistant_msg?(%{"role" => "assistant", "content" => content} = msg) do
    tool_calls = msg["tool_calls"] || []

    if is_binary(content) do
      String.trim(content) == "" and tool_calls == []
    else
      tool_calls == []
    end
  end

  defp empty_assistant_msg?(_), do: false
  defp drop_empty_assistant_messages(messages), do: Enum.reject(messages, &empty_assistant_msg?/1)

  # 崩溃/中断会在 transcript 留下悬空 tool_calls（DeepSeek 严格校验直接 400）。
  # 载入时修补：缺响应的补占位 tool 消息，孤立 tool 消息丢弃；
  # 顺带丢弃空 assistant 消息（否则整段历史请求被上游 400 拒）。
  defp repair_history(messages) do
    messages = Enum.reject(messages, &empty_assistant_msg?/1)

    {chunks, pending} =
      Enum.map_reduce(messages, [], fn msg, pending ->
        case msg do
          %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) and calls != [] ->
            {tool_placeholders(pending) ++ [msg], Enum.map(calls, & &1["id"])}

          %{"role" => "tool", "tool_call_id" => id} ->
            if id in pending, do: {[msg], pending -- [id]}, else: {[], pending}

          _ ->
            {tool_placeholders(pending) ++ [msg], []}
        end
      end)

    Enum.concat(chunks) ++ tool_placeholders(pending)
  end

  defp tool_placeholders(ids) do
    Enum.map(ids, fn id ->
      %{"role" => "tool", "tool_call_id" => id, "content" => "（该工具调用因进程重启/中断未完成，结果已丢失）"}
    end)
  end

  defp audit_dangerous(code) do
    hits = Enum.filter(@dangerous, &String.contains?(code, &1))
    reversibility = Newbee.Trust.reversibility(code)

    if hits != [] or reversibility != :none do
      if Process.whereis(Newbee.Bus) do
        Newbee.Bus.emit(:audit, {:audit, :dangerous_code, hits, reversibility})
      end
    end

    # 不可逆副作用：执行前必须单独确认（§12 可逆性分级）——
    # capability deny 档已由 Permissions 拦截；这里只打审计标签
    if reversibility == :irreversible do
      Newbee.DebugLog.log(:audit, "irreversible side effect: #{String.slice(code, 0, 120)}")
    end
  end

  defp check_rules(text, scope) do
    if Process.whereis(Newbee.DEE.Rules) do
      Newbee.DEE.Rules.check(text, scope)
    else
      []
    end
  end

  # 流监控（§4.5）：:all 规则看 content+reasoning 全文（旧行为）；
  # :content 规则只看 outer 正文（J-Space：稠密符号/marker 不得泄进输出，
  # 思考流是 inner 允许稠密）。合并去重。
  defp stream_rule_hits(msg) do
    content = msg["content"] || ""
    reasoning = msg["reasoning"] || ""

    (check_rules(content <> "\n" <> reasoning, :all) ++ check_rules(content, :content))
    |> Enum.uniq_by(& &1.id)
  end

  defp merge_usage(a, b) when is_map(b) do
    Map.merge(a, b, fn _k, x, y -> (to_num(x) || 0) + (to_num(y) || 0) end)
  end

  defp to_num(n) when is_number(n), do: n
  defp to_num(_), do: nil
  defp client_model(%{model: m}), do: m
  defp client_model(_), do: "unknown"

  # J-Space 恢复协议（长间隔/压缩/会话边界后）：重读 ledger + 前提 + invariants
  defp jspace_recovery_reminder do
    "[J-Space 恢复] 长间隔/压缩后：重读 ledger、前提、invariants，声明 pass 与 next。\n" <>
      "  Newbee.Tools.JSpace.resume()            # 前提 + invariants + 全 ledger\n" <>
      "  Newbee.Tools.JSpace.seam()              # 每个 seam 重读\n" <>
      "  Newbee.Tools.JSpace.note(next: \"...\")   # Next 不许空"
  end

  # 记忆抽取管线（§6.4.3 简化版）：任务完成时把 {任务, 总结} 追加到 lessons 记忆
  defp maybe_extract_lesson(_state, summary) when not is_binary(summary) or summary == "", do: :ok

  defp maybe_extract_lesson(state, summary) do
    task = build_task(state.messages) |> String.slice(0, 100)
    path = Path.join(System.user_home!(), ".newbee/memory/lessons.md")
    File.mkdir_p!(Path.dirname(path))
    entry = "## #{task}\n#{summary}\n"

    case File.read(path) do
      {:ok, body} ->
        unless String.contains?(body, "## #{task}") do
          # 上限：保留最近约 60 个条目（按行截断）
          lines = (String.split(body, "\n") ++ String.split(entry, "\n")) |> Enum.take(-120)
          File.write!(path, Enum.join(lines, "\n") <> "\n")
        end

      _ ->
        File.write!(path, entry)
    end
  rescue
    _ -> :ok
  end

  # ── 权限确认（§8 ask 档）──

  # 等待 TUI/CLI 的权限回复（普通消息；超时 120s 默认拒绝）。
  # persistent_term 标记按 kernel 进程隔离（key 带 pid）：多会话并存时
  # A 会话等待权限不会让 B 会话的 state 也报 awaiting_permission（跨会话串扰）。
  @permission_key {__MODULE__, :awaiting_permission}

  @doc "查询指定 kernel 当前是否在等待权限确认。"
  def awaiting_permission?(kernel) when is_pid(kernel),
    do: :persistent_term.get({@permission_key, kernel}, false)

  defp await_permission do
    key = {@permission_key, self()}
    :persistent_term.put(key, true)

    result =
      receive do
        {:permission_reply, ok} -> ok
      after
        120_000 -> false
      end

    :persistent_term.erase(key)
    result
  end

  # Capability Policy（§8.1）：lenient 放行 / ask 询问 / deny 拒绝
  defp check_permissions_and_run(state, call, code, title) do
    case Newbee.Permissions.check(code) do
      {:deny, _} ->
        rendered = "✗ error\n⛔ 权限档位 deny：代码含危险操作，已拒绝执行"
        emit(state, {:tool_error, rendered})

        tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => rendered}
        {:cont, {:cont, push_msg(state, tool_msg)}}

      :ask ->
        preview = code |> String.slice(0, 300)
        emit(state, {:permission_ask, {:permission_ask, preview}})

        if await_permission() do
          execute_run_elixir(state, call, code, title)
        else
          rendered = "✗ error\n⛔ 用户拒绝执行该操作（权限档位 ask）"
          emit(state, {:tool_error, rendered})

          tool_msg = %{"role" => "tool", "tool_call_id" => call.id, "content" => rendered}
          {:cont, {:cont, push_msg(state, tool_msg)}}
        end

      :ok ->
        execute_run_elixir(state, call, code, title)
    end
  end

  # 权限放行后的真实执行（与 ask 拒绝路径分离，避免重复代码）
  defp execute_run_elixir(state, call, code, title) do
    audit_dangerous(code)
    emit(state, {:tool_start, "run_elixir", title, code})
    tool_started_at = System.monotonic_time(:millisecond)
    Newbee.DebugLog.log(:tool, "eval start #{title}")

    eval_result =
      try do
        Newbee.DEE.Evaluator.eval(state.evaluator, code)
      rescue
        e ->
          Newbee.DebugLog.log(:tool, "eval raised #{inspect(e)}")
          %{status: :error, error: inspect(e), output: ""}
      end

    if Newbee.LLM.Client.interrupted?(state.client) or eval_interrupted?(eval_result) do
      Newbee.DebugLog.log(:tool, "eval interrupted title=#{title}")
      emit(state, {:interrupted, nil})
      {:halt, {:halt, {:interrupted, nil}, state}}
    else
      Newbee.DebugLog.log(:tool, "eval done status=#{eval_result.status} title=#{title}")
      # warning 单独徽标化：transcript 不刷屏，Bus 另发 :tool_warnings 供 TUI 折叠
      warnings = Map.get(eval_result, :warnings, "")
      if warnings != "" and warnings != nil, do: emit(state, {:tool_warnings, warnings})
      rendered = Newbee.DEE.Result.render(eval_result)

      if eval_result.status == :error do
        emit(state, {:tool_error, rendered})
        maybe_auto_antibody(state, code, eval_result)
        {state, hints} = maybe_worker_hint(state, eval_result)
        Enum.each(hints, &emit(state, {:worker_hint, &1}))
      end

      duration_ms = System.monotonic_time(:millisecond) - tool_started_at

      Newbee.Environment.UsageTracker.observe_code(code, %{
        success: eval_result.status == :ok,
        latency_ms: duration_ms,
        output_bytes: byte_size(rendered),
        task_type: "run_elixir"
      })

      emit(state, {:tool_result, "run_elixir", rendered, duration_ms})

      # §12 结构隔离：工具输出是不可信内容，包 envelope（origin/hash/trust）
      # 后再进 tool 消息——永不拼接成 system/user 角色
      tool_msg = Newbee.Trust.tool_message(call.id, rendered, "tool:run_elixir")

      {:cont, {:cont, state |> push_msg(tool_msg) |> maybe_progress() |> maybe_advisor()}}
    end
  end

  defp eval_interrupted?(%{status: :error, error: "interrupted"}), do: true
  defp eval_interrupted?(_), do: false

  defp maybe_advisor(%{advisor: nil} = state), do: state

  defp maybe_advisor(state) do
    if rem(state.steps, 3) == 0 do
      text =
        state.messages
        |> Enum.reverse()
        |> Enum.find_value(fn m ->
          if m["role"] == "assistant" and is_binary(m["content"]) and m["content"] != "" do
            m["content"]
          end
        end)

      if text do
        prompt =
          "你是只读 advisor。下面是一段编程 agent 的最近输出，用一句话指出 concern 或 blocker；没有则只回 OK：\n" <>
            String.slice(text, 0, 1500)

        case Newbee.LLM.Client.complete(state.advisor_client, [%{"role" => "user", "content" => prompt}]) do
          {:ok, content, _} ->
            content = if is_binary(content), do: String.trim(content), else: ""

            if content != "" and content != "OK" and content != "ok" do
              emit(state, {:advisor_note, content})
            end

          _ ->
            :ok
        end
      end
    end

    state
  end

  # worker 供线索（§6.6）：同一错误签名第 2 次出现时自动写一条进化线索
  defp maybe_worker_hint(state, result) do
    case error_pattern(result) do
      nil ->
        {state, []}

      sig ->
        n = Map.get(state.error_sigs, sig, 0) + 1
        state = %{state | error_sigs: Map.put(state.error_sigs, sig, n)}

        if n == 2 do
          Newbee.Agent.Worker.need(
            "run_elixir 反复失败（第 #{n} 次）: #{String.slice(sig, 0, 80)}",
            evidence: %{error_sig: String.slice(sig, 0, 200), count: n}
          )

          {state, [sig]}
        else
          {state, []}
        end
    end
  end

  # ── 事件与持久化 ──

  defp emit(state, event) do
    # TUI/Web/指标等观察者不属于回合核心；观察者异常只能丢事件，不能杀掉 Loop。
    safe_render(state.render, event)

    if Process.whereis(Newbee.Bus) do
      # §4.6：durable topic（turn/*、tool/*、usage、progress、rule_hit …）经
      # Events.emit 先落 EventStore 再广播；text/reasoning delta 等 live 事件
      # 只发 Bus。standalone（无项目 store 注册）时 Events.emit 优雅降级只发 Bus。
      safe_event_emit(elem(event, 0), event)
    end
  end

  defp safe_render(render, event) do
    render.(event)
  rescue
    e -> Newbee.DebugLog.log(:event, "observer failed event=#{inspect(event, limit: 3)} error=#{Exception.message(e)}")
  catch
    kind, reason ->
      Newbee.DebugLog.log(:event, "observer failed event=#{inspect(event, limit: 3)} #{kind}=#{inspect(reason)}")
  end

  defp safe_event_emit(topic, event) do
    Newbee.Events.emit(topic, event)
  rescue
    e -> Newbee.DebugLog.log(:event, "bus emit failed topic=#{topic} error=#{Exception.message(e)}")
  catch
    kind, reason -> Newbee.DebugLog.log(:event, "bus emit failed topic=#{topic} #{kind}=#{inspect(reason)}")
  end

  # 同步屏障：对 Bus 发起一次同步调用，令其按 FIFO 处理完本进程先前投递的
  # 所有 cast（广播），从而保证事件在调用返回前已送达订阅者信箱。
  defp flush_bus do
    if Process.whereis(Newbee.Bus) do
      try do
        Newbee.Bus.subscribers()
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp inject_prompt(state, message, details) do
    audit_prompt_injection(state, message, details)
    push_msg(state, message)
  end

  defp audit_prompt_injection(state, message, details) do
    event =
      details
      |> Map.new()
      |> Map.merge(%{
        role: message["role"] || "system",
        content: message["content"] || "",
        session_id: if(state.session, do: state.session.id, else: nil)
      })

    emit(state, {:prompt_injection, event})
    state
  end

  # 只展示可见正文中的触发内容。规则若只命中 reasoning，不把隐藏思考复制到审计事件。
  defp visible_rule_trigger(content, hits) do
    visible? =
      Enum.any?(hits, fn rule ->
        case Regex.compile(rule.pattern) do
          {:ok, regex} -> Regex.match?(regex, content)
          {:error, _} -> false
        end
      end)

    if visible?, do: String.slice(content, 0, 1_000), else: "（命中位于隐藏思考流，内容不展示）"
  end

  defp rule_audit_details(hits) do
    Enum.map(hits, &Map.take(&1, [:id, :pattern, :injection, :scope, :source]))
  end

  defp push_msg(state, msg) do
    msg = sanitize_msg(msg)
    if state.session, do: Newbee.Session.append(state.session, msg)
    %{state | messages: state.messages ++ [msg]}
  end

  # 兜底：任何入会话消息都必须是合法 UTF-8，否则 Jason 编码崩溃
  defp sanitize_msg(msg) when is_map(msg) do
    Map.new(msg, fn
      {k, v} when is_binary(v) -> {k, Newbee.DEE.Result.sanitize(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &sanitize_msg/1)}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize_msg(other), do: other

  # 对话摘要（§6.5 物化视图的维护操作）：旧消息 → 要点摘要
  defp summarize_conversation(client, messages, max_tokens) do
    prompt =
      "把以下 agent 对话压缩为要点摘要（任务、关键决策、文件改动、测试结果；≤500 字，中文）：\n" <>
        Enum.map_join(messages, "\n", fn m ->
          "#{m["role"]}: #{message_content_text(m["content"])}"
          |> String.slice(0, 240)
        end)

    case Newbee.LLM.Client.complete(client, [%{"role" => "user", "content" => prompt}],
           extra: %{max_tokens: max_tokens}
         ) do
      {:ok, content, _} when is_binary(content) and content != "" -> content
      _ -> "（摘要失败，历史已截断）"
    end
  rescue
    _ -> "（摘要失败，历史已截断）"
  end

  # Automatic pressure check follows deepseek-harness: compact before the request,
  # at a configurable fraction of the model window.
  defp maybe_auto_compact(%{auto_compact: false} = state), do: state

  defp maybe_auto_compact(state) do
    pressure = estimate_request_tokens(state.messages)
    limit = trunc(state.context_window * state.compaction_threshold)

    if pressure >= limit and length(state.messages) > 2 do
      retain = max(trunc(state.context_window * state.compaction_retain), 512)
      {state, count} = compact_state(state, retain)
      if count > 0, do: Newbee.DebugLog.log(:compact, "automatic pressure=#{pressure}/#{limit}")
      state
    else
      state
    end
  end

  defp estimate_request_tokens(messages) do
    div(byte_size(Jason.encode!(messages)) + 2, 3) + 2_000
  rescue
    _ -> Enum.count(messages) * 100
  end

  defp estimate_message_tokens(message) do
    div(byte_size(Jason.encode!(message)) + 2, 3) + 8
  end

  # 压缩（§4.6 视图维护）：有会话走 Archive——transcript 永不覆写，归档区间成为
  # 可寻址段（history:// 拉取），汇总消息由段 digest 确定性装配，LLM 只在蒸馏新段
  # 时用一次。无会话（session: false 的测试/ephemeral 模式）退回旧的内存压扁路径。
  defp compact_state(%{session: nil} = state, retain_target) do
    body = tl(state.messages)
    {old, recent} = split_for_retention(body, retain_target)

    if old == [] do
      {state, 0}
    else
      summary = summarize_conversation(state.client, old, state.compaction_max_tokens)
      summary_msg = %{"role" => "system", "content" => "（以下为较早对话的压缩摘要，细节已丢失）\n" <> summary}
      messages = repair_history([hd(state.messages), summary_msg | recent])
      emit(state, {:compacted, length(old)})
      Newbee.DebugLog.log(:compact, "compacted #{length(old)} messages (ephemeral, no session)")
      {%{state | messages: messages}, length(old)}
    end
  end

  defp compact_state(state, retain_target) do
    # base = 本会话 system 基底（messages 头部，不进 transcript）。
    # 传给 Archive：摘要请求走 envelope 重放真实请求前缀（详见 prefix-cache 方案）。
    base = hd(state.messages)

    opts = [
      retain: retain_target,
      client: state.client,
      envelope: Newbee.RequestEnvelope.load(state.session),
      trigger: if(retain_target <= 64, do: "manual", else: "auto")
    ]

    case Newbee.Archive.compact(state.session, opts) do
      {:ok, %{view: view, archived: n}} ->
        # view = [汇总消息 | 近期原文]；头部补回本会话 system 基底（不进 transcript）
        messages = [base | view] |> repair_history()

        messages =
          if Newbee.Tools.JSpace.exists?(state.session.id) do
            [hd(messages), %{"role" => "system", "content" => jspace_recovery_reminder()} | tl(messages)]
          else
            messages
          end

        emit(state, {:compacted, n})
        Newbee.DebugLog.log(:compact, "archived #{n} messages → segment (append-only transcript)")
        {%{state | messages: messages}, n}

      :noop ->
        {state, 0}
    end
  rescue
    e ->
      # Archive 故障绝不伤会话：退回内存压扁（transcript 未动，仍可下次重试）
      Newbee.DebugLog.log(:compact, "archive failed #{inspect(e)}; fallback to ephemeral squash")
      compact_state(%{state | session: nil}, retain_target)
  end

  defp split_for_retention(messages, count) when count <= 64 do
    Enum.split(messages, max(length(messages) - count, 0))
  end

  defp split_for_retention(messages, target) do
    {recent, _tokens} =
      Enum.reduce(Enum.reverse(messages), {[], 0}, fn message, {keep, tokens} ->
        cost = estimate_message_tokens(message)
        if keep != [] and tokens + cost > target, do: {keep, tokens}, else: {[message | keep], tokens + cost}
      end)

    Enum.split(messages, max(length(messages) - length(recent), 0))
  end

  defp message_content_text(parts) when is_list(parts), do: Enum.find_value(parts, "[图片]", &image_text_part/1)
  defp message_content_text(_), do: ""

  defp image_text_part(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp image_text_part(_), do: nil

  # ── 终局验证（LLM-as-a-Verifier）──

  # done 前的终局检查：分数 ≥ 阈值直接 done；低分注入提醒让模型重新评估（仅一次）。
  defp final_check(%{progress: nil} = state), do: {:done, state}

  defp final_check(state) do
    p = state.progress

    if p.final_check and not p.final_checked do
      task = build_task(state.messages)
      traj = build_traj(state.messages)

      score_opts = if p.complete_fn, do: [scale: p.scale, complete_fn: p.complete_fn], else: [scale: p.scale]

      result =
        try do
          Newbee.Agent.Progress.score(p.client, task, traj, score_opts)
        rescue
          e -> %{score: nil, error: inspect(e)}
        end

      case result do
        %{score: s, criteria: criteria} when is_number(s) ->
          state = %{state | progress: %{p | final_checked: true, final_score: s}}
          emit(state, {:final_check, s})

          # 判分失败（criteria 全 error）视为无法判断：不阻塞完成
          if criteria != [] and Enum.all?(criteria, &(&1.method == :error)) do
            {:done, state}
          else
            if s >= p.done_threshold do
              {:done, state}
            else
              reminder =
                "[终局验证] 你的完成分数 #{Float.round(s, 1)}/20 低于阈值 #{p.done_threshold}。" <>
                  "请重新检查是否真正满足所有任务要求（输出格式、错误处理、测试通过）。" <>
                  "确认无误后再调用 done，或继续修正。"

              {:retry, state, reminder}
            end
          end

        _ ->
          # 判分失败不阻塞完成
          {:done, %{state | progress: %{p | final_checked: true}}}
      end
    else
      {:done, state}
    end
  end

  # ── 进度监控（LLM-as-a-Verifier）──

  defp maybe_progress(%{progress: nil} = state), do: state

  defp maybe_progress(state) do
    steps = state.steps + 1
    state = %{state | steps: steps}

    if rem(steps, state.progress.every) == 0 do
      do_progress_check(state)
    else
      state
    end
  end

  # 每 every 步对轨迹前缀打一次连续分；连续停滞则注入干预提醒（只注入一次）。
  defp do_progress_check(state) do
    p = state.progress
    task = build_task(state.messages)
    traj = build_traj(state.messages)

    score_opts = if p.complete_fn, do: [scale: p.scale, complete_fn: p.complete_fn], else: [scale: p.scale]

    result =
      try do
        Newbee.Agent.Progress.score(p.client, task, traj, score_opts)
      rescue
        e -> %{score: nil, variance: nil, error: inspect(e)}
      end

    case result do
      %{score: s} when is_number(s) ->
        scores = p.scores ++ [s]
        emit(state, {:progress, s, scores})
        Newbee.DebugLog.log(:progress, "score=#{Float.round(s, 2)} trend=#{inspect(scores)}")

        if Newbee.Agent.Progress.stalled?(scores,
             window: p.window,
             min_steps: p.min_steps,
             threshold: p.threshold
           ) and not p.injected do
          emit(state, {:progress_stall, scores})
          reminder = progress_reminder(scores)
          Newbee.DebugLog.log(:progress, "stalled, injecting reminder")

          %{state | progress: %{p | scores: scores, injected: true}}
          |> inject_prompt(%{"role" => "user", "content" => reminder}, %{
            source: "progress_stall",
            reason: "连续轨迹评分显示进度停滞",
            timing: "current_turn_retry",
            scores: scores
          })
        else
          %{state | progress: %{p | scores: scores}}
        end

      _ ->
        Newbee.DebugLog.log(:progress, "score failed: #{inspect(result)}")
        state
    end
  end

  # 从消息历史提取任务描述（第一条 user 消息）
  defp build_task(messages) do
    messages
    |> Enum.find_value(fn m -> if m["role"] == "user" and is_binary(m["content"]), do: m["content"] end)
    |> case do
      nil -> "(无任务描述)"
      t -> String.slice(t, 0, 800)
    end
  end

  # 从消息历史提取轨迹前缀：run_elixir 工具结果（压缩）
  defp build_traj(messages) do
    messages
    |> Enum.filter(fn m -> m["role"] == "tool" and is_binary(m["content"]) end)
    |> Enum.map(fn m ->
      m["content"]
      |> String.replace(
        "

",
        "
"
      )
      |> String.slice(0, 300)
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} -> "step #{i}: #{c}" end)
    |> Enum.join("
")
  end

  defp progress_reminder(scores) do
    trend = Newbee.Agent.Progress.render_scores(scores)

    "[进度监控] 检测到进度停滞（最近分数趋势：#{trend}）。
" <>
      "你最近的步骤没有取得实质进展。请停下来重新评估：是否在绕路（安装无关依赖、反复尝试同一方案、在错误方向深挖）？
" <>
      "建议：回退到最近的高分状态（可用 git rollback 或重新梳理），换一个更直接的路径。"
  end

  defp persist_bindings(%{session: nil}), do: :ok

  defp persist_bindings(state) do
    binding = Newbee.DEE.Evaluator.dump_bindings(state.evaluator)
    Newbee.Session.save_bindings(state.session, binding)
  rescue
    _ -> :ok
  end

  defp check_beam_snapshot(session) do
    path = Path.join(session.dir, "beam_snapshot.json")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, snap} ->
            cur_otp = :erlang.system_info(:otp_release) |> List.to_string()
            cur_elixir = System.version()
            saved_otp = snap["otp"] || snap[:otp]
            saved_elixir = snap["elixir"] || snap[:elixir]

            if saved_otp && saved_otp != cur_otp do
              Newbee.DebugLog.log(:resume, "OTP 差异: dump=#{saved_otp} 当前=#{cur_otp}（ETS/Port 句柄可能已失效）")
            end

            if saved_elixir && saved_elixir != cur_elixir do
              Newbee.DebugLog.log(:resume, "Elixir 差异: dump=#{saved_elixir} 当前=#{cur_elixir}")
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── 失败抗体自动生成（§6.3）──

  # run_elixir 真实失败沉淀一条回归断言。仅 opt-in（CLI/TUI 开启，测试关闭）。
  # 同代码去重；provenance=auto 的抗体在回放时"不再复现即过期删除"（见
  # Bench.replay），不会因瞬态失败误伤进化门。
  defp maybe_auto_antibody(%{auto_antibodies: false}, _code, _result), do: :ok

  defp maybe_auto_antibody(_state, code, result) do
    with pattern when is_binary(pattern) and pattern != "" <- error_pattern(result) do
      id =
        "auto-" <>
          (:crypto.hash(:md5, code) |> Base.encode16(case: :lower) |> binary_part(0, 12))

      exists? =
        Newbee.Environment.Antibodies.all()
        |> Enum.any?(&(&1["id"] == id))

      unless exists? do
        Newbee.Environment.Antibodies.observe(
          id,
          %{
            input: code,
            error: pattern,
            task: "run_elixir failure (auto)",
            check: %{"kind" => "expect_error", "pattern" => pattern}
          },
          provenance: "auto"
        )

        Newbee.DebugLog.log(:antibody, "auto antibody #{id}: #{String.slice(pattern, 0, 60)}")
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # 错误首行（去 ANSI）作为稳定签名；无错误文本不沉淀
  defp error_pattern(%{error: error}) when is_binary(error) do
    error
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z~]/, "")
    |> String.split("\n")
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> nil
      line -> line |> String.trim() |> String.slice(0, 80) |> Regex.escape()
    end
  end

  defp error_pattern(_), do: nil

  # ── system prompt = 环境物化视图（§4.6）──

  # 唯一视图构建器是 Environment.Projection：system 基底 + 项目记忆 +
  # RepoMap + 工具价签 + 记忆 Guidance + 绑定摘要 + module_ready/迁移
  # 摘要通知 + 沉睡规则挂载表。Coordinator 未运行时通知/绑定自动跳过。
  defp system_prompt(root) do
    Newbee.Environment.Projection.build(%{root: root || File.cwd!()}).prompt
  end
end
