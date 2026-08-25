defmodule Newbee.Daemon do
  @moduledoc """
  常驻 daemon (DESIGN §3.8) ⭐：环境是常驻生命体，TUI 只是探视窗。

  - 订阅事件总线，后台记录环境活动；
  - 定时触发 adapter（heartbeat）：need 消息 + JIT 热度 → 合成候选 →
    Verifier 门 → 按 Autonomy 档位经 Coordinator 激活（无旁路）；
  - 关掉 TUI 只是 detach，环境继续存活、记忆、进化；
  - `newbee attach` 随时接回。
  """

  use GenServer
  require Logger

  @evolve_interval :timer.minutes(10)
  @evolve_debounce 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "立即触发一轮 adapter 进化（/evolve 也走这里）。"
  def evolve_now do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :evolve_now)
    else
      spawn(fn -> run_adapter_cycle() end)
    end

    :ok
  end

  @impl true
  def init(_) do
    if Process.whereis(Newbee.Bus) do
      Newbee.Bus.subscribe()
    end

    Process.send_after(self(), :evolve_tick, @evolve_interval)
    {:ok, %{evolve_timer: nil, adapter_ref: nil, cycle_pending: false, error_times: []}}
  end

  @impl true
  def handle_cast(:evolve_now, state) do
    {:noreply, start_or_queue_cycle(state)}
  end

  @impl true
  def handle_info(:evolve_tick, state) do
    Process.send_after(self(), :evolve_tick, @evolve_interval)
    {:noreply, start_or_queue_cycle(state)}
  end

  def handle_info(:evolve_debounced, state) do
    {:noreply, state |> Map.put(:evolve_timer, nil) |> start_or_queue_cycle()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{adapter_ref: ref} = state) do
    state = %{state | adapter_ref: nil}

    if state.cycle_pending do
      {:noreply, state |> Map.put(:cycle_pending, false) |> start_or_queue_cycle()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:newbee_event, :prompt_injection, _event}, state) do
    # 注入事实已经同步落 EventStore；短暂去抖后立即让 JIT 判断是否达到优化阈值。
    if state.evolve_timer do
      {:noreply, state}
    else
      timer = Process.send_after(self(), :evolve_debounced, @evolve_debounce)
      {:noreply, %{state | evolve_timer: timer}}
    end
  end

  def handle_info({:newbee_event, :tool_error, _event}, state) do
    # TCE [G2]: tool_error 风暴即时触发——10min heartbeat 对"坏工具持续烧钱"太慢。
    # 滑窗计数: 60s 内 >=3 次错误 → debounce 触发进化（deopt/修复 need）。
    now = System.monotonic_time(:millisecond)
    window = [now | Map.get(state, :error_times, [])]
              |> Enum.filter(fn t -> now - t < 60_000 end)

    if length(window) >= 3 do
      if state.evolve_timer do
        {:noreply, %{state | error_times: window}}
      else
        timer = Process.send_after(self(), :evolve_debounced, @evolve_debounce)
        {:noreply, %{state | evolve_timer: timer, error_times: []}}
      end
    else
      {:noreply, %{state | error_times: window}}
    end
  end

  def handle_info({:newbee_event, topic, event}, state) do
    # 审计/进化事件记日志（EventLog 已落盘；这里只打 Logger）
    if topic in [:change_activated, :change_rejected, :change_rolled_back, :revision_advanced, :revision_degraded] do
      Logger.info("daemon event #{topic}: #{inspect(event, limit: 4)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_or_queue_cycle(%{adapter_ref: nil} = state) do
    {_pid, ref} = spawn_monitor(fn -> run_adapter_cycle() end)
    %{state | adapter_ref: ref}
  end

  defp start_or_queue_cycle(state), do: %{state | cycle_pending: true}

  defp run_adapter_cycle do
    case Newbee.Agent.Adapter.run_once() do
      {:skipped, reason} ->
        Logger.info("adapter skipped: #{reason}")

      {:suggested, proposals} ->
        # 档位 observe：只产出建议，不激活
        Logger.info("adapter suggestions (#{length(proposals)}): #{inspect(proposals, limit: 3)}")

      {:processed, results} ->
        Logger.info("adapter cycle: #{inspect(results, limit: 6)}")

      other ->
        Logger.warning("adapter cycle: #{inspect(other)}")
    end
  rescue
    error ->
      Logger.error("adapter cycle crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      :error
  catch
    kind, reason ->
      Logger.error("adapter cycle halted: #{inspect({kind, reason})}")
      :error
  end

  @doc """
  `mix newbee daemon` 入口：确保 Daemon GenServer 在跑（监督树已带则复用，
  否则自行 start_link 拉起，不绕过 GenServer），随后常驻阻塞（Ctrl-C 退出）。
  """
  def start do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end

    IO.puts("newbee daemon: 常驻中（每 #{div(@evolve_interval, 60_000)} 分钟检查一次进化线索）")
    IO.puts("Ctrl-C 退出。环境与记忆继续保留在项目 .newbee/")
    Process.sleep(:infinity)
  end
end
