defmodule Newbee.Agent.Adapter do
  @moduledoc """
  Adapter Agent（DESIGN §7.1）：后台进化 Agent（0..1 个）。

  - **读**：事件流 + 指标 + need 消息（worker 的便宜线索）；
  - **做所有贵的事**：诊断 → 合成候选 release → 自测 → Verifier 门；
  - **按 Autonomy 档位激活/canary**（走 Coordinator，绝不直接碰 active manifest）；
  - 收负反馈 → 修订或回退；
  - **隔离边界**：不接管用户任务、不碰 worker 的 transcript/bindings；
    上下文、evaluator、token 预算各自独立；
  - JIT 晋升（L1→L2→L3）与 deopt 走同一 Change 生命周期（§8.5）。

  分工原则：**worker 供信号，adapter 做合成，评价层做裁判。**
  adapter 可提评价计划，不能伪造评价结果（§8.2）。
  """

  require Logger

  alias Newbee.Agent.Protocol
  alias Newbee.Environment.{Autonomy, Coordinator, Jit}

  @doc """
  一轮进化循环：收集信号 → 合成提案 → 逐提案走 Change 生命周期。
  client_fun 可注入（测试用假客户端）。返回每个提案的处理结果。
  """
  def run_once(opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)

    if Process.whereis(coordinator) == nil do
      {:error, :coordinator_down}
    else
      # adapter 独立预算（§7.1）：信号/提案数量封顶，不烧 worker 的 token
      max_signals = Keyword.get(opts, :max_signals, 10)
      max_proposals = Keyword.get(opts, :max_proposals, 3)

      signals = collect_signals(opts) |> Enum.take(max_signals)

      if signals == [] do
        {:skipped, :no_signals}
      else
        proposals = synthesize(signals, opts) |> Enum.take(max_proposals)

        if Autonomy.get() == :observe do
          {:suggested, proposals}
        else
          results = Enum.map(proposals, &process_proposal(&1, coordinator, opts))
          {:processed, results}
        end
      end
    end
  rescue
    error ->
      Logger.error("adapter run failed: #{Exception.format(:error, error, __STACKTRACE__)}")
      {:error, {:exception, error}}
  end

  # ── 信号收集：事件流 + JIT 热度 + need 消息 ──

  def collect_signals(opts \\ []) do
    needs =
      Protocol.messages(kind: :need)
      |> Enum.map(fn m ->
        %{
          type: :need,
          capability: m["payload"]["capability"],
          evidence: m["payload"]["evidence"],
          urgency: m["payload"]["urgency"]
        }
      end)

    jit_hot =
      case Keyword.get(opts, :events) do
        nil ->
          # TCE v2 [F3]: 默认走 PatternStore 后验（LCB 排序 + 校准成本调整），
          # PatternStore 为空时回退旧事件流点估计
          case Jit.tce_hot_needs() do
            [] ->
              events =
                try do
                  Newbee.EventStore.replay(Newbee.Environment.Store.path(:events), 0)
                rescue
                  _ -> []
                catch
                  _, _ -> []
                end

              Jit.hot_needs(events, Keyword.get(opts, :jit_opts, []))

            needs_tce ->
              needs_tce
          end

        events ->
          # 显式传事件流时保持旧行为（测试兼容）
          Jit.hot_needs(events, Keyword.get(opts, :jit_opts, []))
      end
      |> Enum.map(fn n -> %{type: :jit_hot, capability: n.capability, evidence: n.evidence, urgency: n.urgency} end)

    hints = Keyword.get(opts, :hints, []) |> Enum.map(&%{type: :hint, capability: &1, urgency: :low})

    needs ++ jit_hot ++ hints
  end

  # ── 合成（贵的事：诊断 + 候选生成，独立上下文与预算）──

  @doc "让 adapter 角色模型把信号合成为提案（JSON 数组）。"
  def synthesize(signals, opts) do
    client_fun =
      Keyword.get(opts, :client_fun, fn messages ->
        client = Newbee.LLM.Config.client_for("adapter")

        case Newbee.LLM.Client.stream_chat(client, messages, fn _ -> :ok end) do
          {:ok, msg, _usage} -> {:ok, msg["content"] || ""}
          {:error, e} -> {:error, e}
        end
      end)

    prompt = """
    你是 newbee 的 adapter（环境进化工程师）。根据 worker 信号产出环境进化提案。
    只输出 JSON 数组，每项：
      {"type":"rule","id":"...","pattern":"正则","injection":"命中时注入给模型的提醒"}
      {"type":"tool","id":"...","name":"模块短名","source":"完整 Elixir 模块源码（实现 PluginContract + ToolContract）"}
      {"type":"prompt","id":"...","note":"L1 教训（what/when/why ≤2KB）"}

    工具提案纪律：先以 Newbee.Environment.ToolContract.template(Module, plugin_id) 为骨架。
    describe 必须声明 summary/when_to_use/avoid_when/capabilities/effects/error_contract/api/examples；
    api 必须与真实公开导出完全一致，helper 用 defp，示例必须调用真实 API。
    不得重复已有高层工具；avoid_when 必须写清与现有能力的边界。

    纪律（§3.4 补丁纪律）：小、有据（引用信号证据）、可评价。不确定就不要产出。
    信号：#{inspect(signals, limit: 8)}
    """

    case client_fun.([%{"role" => "user", "content" => prompt}]) do
      {:ok, content} ->
        parse_proposals(content)

      {:error, e} ->
        Logger.warning("adapter synthesize failed: #{inspect(e)}")
        []
    end
  end

  defp parse_proposals(content) do
    content
    |> String.split(~r/```[a-z]*/, trim: true)
    |> Enum.find_value(fn chunk ->
      case Jason.decode(String.trim(chunk)) do
        {:ok, list} when is_list(list) -> list
        _ -> nil
      end
    end)
    |> case do
      nil -> []
      list -> list
    end
  rescue
    _ -> []
  end

  # ── 提案 → Change 生命周期（无旁路！）──

  @doc """
  单个提案走完整生命周期：
  propose_change → candidate_ready → （异步 Verifier）→ Autonomy 判定激活。
  返回 {:ok, change_id} | {:error, reason}。
  """
  def process_proposal(proposal, coordinator \\ Coordinator, opts \\ []) do
    with {:ok, attrs} <- proposal_to_release(proposal),
         {:ok, change} <-
           Coordinator.propose_change(coordinator, %{
             reason: "adapter: #{proposal["id"]}",
             evidence: [%{proposal: proposal["id"], type: proposal["type"]}],
             author_agent: :adapter
           }),
         {:ok, release} <- Coordinator.candidate_ready(coordinator, change.change_id, attrs, opts) do
      Protocol.candidate_ready(change.change_id, release.plugin_id, release.release_id, %{
        "ring" => Autonomy.ring_of(release.kind)
      })

      {:ok, change.change_id}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc "提案转 release attrs（校验；不合法提案在这里被挡）。"
  def proposal_to_release(%{"type" => "rule", "id" => id, "pattern" => pattern, "injection" => injection}) do
    case Regex.compile(pattern) do
      {:ok, _} ->
        source = rule_source(id, pattern, injection)

        {:ok,
         %{
           plugin_id: "rule." <> slug(id),
           kind: :rule,
           source_files: %{"#{slug(id)}.ex" => source},
           usage: injection
         }}

      {:error, _} ->
        {:error, :bad_regex}
    end
  end

  def proposal_to_release(%{"type" => "tool", "id" => id, "name" => name, "source" => source}) do
    case Newbee.Environment.PluginContract.validate_source(source, :tool) do
      {:ok, %{envelope: envelope}} ->
        summary = contract_field(envelope.describe, :summary)

        {:ok,
         %{
           plugin_id: "tool." <> slug(id || name),
           kind: :tool,
           source_files: %{"#{slug(name)}.ex" => source},
           usage: summary,
           capabilities: envelope.capabilities || [],
           effects: envelope.effects || []
         }}

      {:error, reasons} ->
        {:error, {:contract_violation, reasons}}
    end
  end

  def proposal_to_release(%{"type" => "prompt", "id" => id, "note" => note}) do
    {:ok,
     %{
       plugin_id: "prompt." <> slug(id),
       kind: :prompt,
       source_files: %{},
       usage: note
     }}
  end

  def proposal_to_release(other), do: {:error, {:malformed_proposal, other}}

  @doc """
  deopt 检查（§8.5）：L3 工具判退化 → 发起降级 Change（回上级形态 release，
  知识不丢）。返回 [{:deopted, release_id} | {:keep, release_id}]。
  """
  def check_deopts(release_ids, coordinator \\ Newbee.Environment.Coordinator) when is_list(release_ids) do
    Enum.map(release_ids, fn rid ->
      case Jit.deopt_decision(rid) do
        {:deopt, target_form, reason} ->
          Logger.info("deopt #{rid} → #{target_form}: #{reason}")
          # 发起降级 Change（§8.5 知识不丢：L3 降回 L2 形态）
          coordinator
          |> Newbee.Environment.Coordinator.propose_change(%{
            reason: "deopt #{rid} → #{target_form}: #{reason}",
            evidence: [%{deopt: rid, target_form: target_form, reason: reason}],
            author_agent: :adapter
          })
          |> case do
            {:ok, change} -> {:deopted, rid, target_form, reason, change_id: change.change_id}
            err -> {:error, rid, err}
          end

        :keep ->
          # ContextQuality 质量判据（调研 REPORT §4 落位）：Jit 成本侧判 keep 的
          # release，再查任务级质量侧——注入是否让任务变差（差分归因，确定性信号）。
          case quality_deopt_decision(rid) do
            {:deopt, reason} ->
              Logger.info("quality deopt #{rid}: #{reason}")

              coordinator
              |> Newbee.Environment.Coordinator.propose_change(%{
                reason: "quality deopt #{rid}: #{reason}",
                evidence: [%{quality_deopt: rid, reason: reason}],
                author_agent: :adapter
              })
              |> case do
                {:ok, change} -> {:deopted, rid, :quality, reason, change_id: change.change_id}
                err -> {:error, rid, err}
              end

            :keep ->
              {:keep, rid}
          end
      end
    end)
  end

  # ContextQuality 质量 deopt 判据：release 注入上下文的实证质量。
  # Collector 未运行（无账本）时优雅 :keep——度量缺失不阻塞既有成本侧 deopt。
  @doc false
  def quality_deopt_decision(release_id) do
    alias Newbee.Environment.ContextQuality
    alias Newbee.Environment.ContextQuality.Collector

    if Process.whereis(Collector) do
      l = Collector.ledger(release_id)

      cond do
        ContextQuality.verdict(l) == :harmful ->
          s = ContextQuality.summary(l)

          {:deopt,
           "harmful: 注入后成功率 #{Float.round(s.success_with, 2)} < 基线 #{Float.round(s.success_without, 2)} " <>
             "(置信区间不重叠, n=#{s.n_with}/#{s.n_without})"}

        ContextQuality.bloat_regression?(l) ->
          s = ContextQuality.summary(l)

          {:deopt, "context bloat: 注入后 token #{round(s.avg_tokens_with)} > 基线 #{round(s.avg_tokens_without)} 且成功率不升"}

        true ->
          :keep
      end
    else
      :keep
    end
  rescue
    _ -> :keep
  end

  # ── helpers ──

  # rule release 的源码：一个实现 contract 的规则模块（pattern/injection 即数据）
  defp rule_source(id, pattern, injection) do
    mod = Module.concat(["Newbee", "Plugins", "Rules", Macro.camelize(slug(id))])

    """
    defmodule #{inspect(mod)} do
      @moduledoc "沉睡规则 #{id}（JIT L2：平时零成本，触发才注入）"
      @behaviour Newbee.Environment.PluginContract

      @impl true
      def id, do: "rule.#{slug(id)}"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def describe, do: %{kind: :rule, pattern: #{inspect(pattern)}, injection: #{inspect(injection)}, scope: :all}
      @impl true
      def dependencies, do: []

      def pattern, do: ~r"#{pattern}"
      def injection, do: #{inspect(injection)}
    end
    """
  end

  defp contract_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || ""
  end

  defp slug(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end
end
