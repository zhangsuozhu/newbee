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

  @tool_api_pattern ~r/(?:Newbee\.Tools\.)?([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.[a-z_][A-Za-z0-9_!?]*)(?:\/\d+)?/

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

  @doc """
  运行每轮进化后的维护检查：active release deopt + 成熟 canary 晋升。

  维护与新信号合成解耦，因此 `run_once/1` 返回 `:no_signals` 时仍会执行。
  """
  def maintain(opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    canaries = promote_ready_canaries(coordinator, opts)
    current = Coordinator.current(coordinator)

    release_ids =
      current.active
      |> Map.values()
      |> Enum.uniq()

    %{
      deopts: check_deopts(release_ids, coordinator),
      canaries: canaries,
      promotions: promote_need_clusters(Keyword.put(opts, :coordinator, coordinator))
    }
  catch
    :exit, reason -> {:error, {:coordinator_down, reason}}
  end

  @doc """
  在 autonomous 档位晋升已稳定驻留的 canary。

  默认驻留窗口为 10 分钟。实际激活仍走 Coordinator 的完整合取门；
  stale base 等拒绝会作为 `{:kept, change_id, reason}` 返回。
  """
  def promote_ready_canaries(coordinator \\ Coordinator, opts \\ []) do
    min_age_ms = Keyword.get(opts, :canary_min_age_ms, :timer.minutes(10))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Coordinator.current(coordinator) do
      %{autonomy: :autonomous} ->
        coordinator
        |> Coordinator.changes()
        |> Enum.filter(&mature_canary?(&1, now, min_age_ms))
        |> Enum.map(fn change ->
          case Coordinator.activate(coordinator, change.change_id) do
            :ok -> {:activated, change.change_id}
            {:error, reason} -> {:kept, change.change_id, reason}
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  将重复 need 按稳定 capability 键聚类，达到阈值后调度一次 L1→L2 晋升。

  默认阈值为 3，每轮最多创建 1 个 Change。晋升严格走 Coordinator + Verifier；
  observe/emergency_stop 档不创建候选。Change evidence 中的 message_id 是消费水位，
  同一批 need 不会重复晋升。
  """
  def promote_need_clusters(opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    threshold = positive_integer(opts[:need_promotion_threshold], 3)
    max_promotions = positive_integer(opts[:max_need_promotions], 1)
    current = Coordinator.current(coordinator)

    if current.autonomy in [:observe, :emergency_stop] do
      []
    else
      needs = Keyword.get_lazy(opts, :needs, fn -> Protocol.messages(kind: :need) end)
      consumed = consumed_need_ids(Coordinator.changes(coordinator))

      needs
      |> Enum.filter(&valid_need?/1)
      |> Enum.uniq_by(& &1["message_id"])
      |> Enum.group_by(&need_cluster_key/1)
      |> Enum.reject(fn {key, _messages} -> is_nil(key) end)
      |> Enum.map(fn {key, messages} ->
        pending = Enum.reject(messages, &MapSet.member?(consumed, &1["message_id"]))
        %{key: key, messages: messages, pending: pending}
      end)
      |> Enum.filter(&(length(&1.pending) >= threshold))
      |> Enum.sort_by(fn cluster -> {-length(cluster.pending), cluster.key} end)
      |> Enum.take(max_promotions)
      |> Enum.map(&promote_need_cluster(&1, current.active, coordinator, threshold))
    end
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

  defp mature_canary?(%{status: :canary, updated_at: updated_at}, now, min_age_ms)
       when is_binary(updated_at) and is_integer(min_age_ms) and min_age_ms >= 0 do
    with {:ok, entered_at, _offset} <- DateTime.from_iso8601(updated_at) do
      DateTime.diff(now, entered_at, :millisecond) >= min_age_ms
    else
      _ -> false
    end
  end

  defp mature_canary?(_change, _now, _min_age_ms), do: false

  defp promote_need_cluster(cluster, active, coordinator, threshold) do
    plugin_id = "rule.jit_need_" <> short_hash(cluster.key)
    pattern = cluster_pattern(cluster)
    injection = cluster_injection(cluster)

    artifact =
      Jit.promote_l1_to_l2(cluster.key, pattern, injection, plugin_id: plugin_id)

    message_ids = cluster.pending |> Enum.map(& &1["message_id"]) |> Enum.sort()

    evidence = %{
      jit_promotion: "l1_to_l2",
      cluster_key: cluster.key,
      message_ids: message_ids,
      pending_count: length(message_ids),
      total_count: length(cluster.messages),
      threshold: threshold
    }

    release_attrs = %{
      plugin_id: artifact.plugin_id,
      kind: artifact.kind,
      parent_release: active[artifact.plugin_id],
      source_files: %{
        "#{slug(artifact.plugin_id)}.ex" =>
          rule_source(cluster.key, artifact.spec.pattern, artifact.spec.injection, artifact.plugin_id)
      },
      usage: artifact.spec.injection
    }

    with {:ok, change} <-
           Coordinator.propose_change(coordinator, %{
             reason: artifact.reason,
             evidence: [evidence],
             request_id: "jit_need:" <> short_hash(Enum.join(message_ids, ",")),
             author_agent: :adapter
           }),
         {:ok, release} <-
           Coordinator.candidate_ready(coordinator, change.change_id, release_attrs) do
      Protocol.candidate_ready(change.change_id, release.plugin_id, release.release_id, %{
        "ring" => Autonomy.ring_of(release.kind),
        "jit_promotion" => "l1_to_l2",
        "cluster_key" => cluster.key
      })

      {:ok, change.change_id, release.plugin_id, length(message_ids)}
    else
      {:error, reason} -> {:error, cluster.key, reason}
      other -> {:error, cluster.key, other}
    end
  end

  defp consumed_need_ids(changes) do
    changes
    |> Enum.flat_map(fn change ->
      (change.evidence || [])
      |> Enum.filter(fn evidence ->
        (evidence["jit_promotion"] || evidence[:jit_promotion]) == "l1_to_l2"
      end)
      |> Enum.flat_map(fn evidence -> evidence["message_ids"] || evidence[:message_ids] || [] end)
    end)
    |> MapSet.new()
  end

  defp valid_need?(%{"message_id" => id, "payload" => payload})
       when is_binary(id) and is_map(payload) do
    capability = payload["capability"]
    is_binary(capability) and String.trim(capability) != ""
  end

  defp valid_need?(_message), do: false

  defp need_cluster_key(%{"payload" => payload}) do
    expected_api = canonical_api(payload["expected_api"])
    capability = payload["capability"]

    cond do
      expected_api -> "api:" <> expected_api
      api = capability_api(capability) -> "api:" <> api
      true -> "text:" <> short_hash(normalize_capability(capability))
    end
  end

  defp canonical_api(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      api = capability_api(value) ->
        api

      Regex.match?(~r/^[a-z_][a-z0-9_!?]*(?:\/\d+)?$/i, value) ->
        value |> String.replace(~r/\/\d+$/, "") |> String.downcase()

      true ->
        nil
    end
  end

  defp canonical_api(_value), do: nil

  defp capability_api(value) when is_binary(value) do
    case Regex.run(@tool_api_pattern, value, capture: :all_but_first) do
      [api] -> String.downcase(api)
      _ -> nil
    end
  end

  defp capability_api(_value), do: nil

  defp normalize_capability(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp cluster_pattern(%{key: "api:" <> api}) do
    escaped = Regex.escape(api)
    prefix = if String.contains?(api, "."), do: "(?:Newbee\\.Tools\\.)?", else: ""
    "(?i)" <> prefix <> escaped
  end

  defp cluster_pattern(%{messages: [message | _]}) do
    "(?i)" <> Regex.escape(message["payload"]["capability"])
  end

  defp cluster_injection(cluster) do
    requirements =
      cluster.messages
      |> Enum.map(&get_in(&1, ["payload", "capability"]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(12)
      |> Enum.map_join("\n", &"- #{&1}")

    ("Repeated needs for #{cluster.key} reached the JIT promotion threshold. " <>
       "When this capability is relevant, account for these observed requirements:\n" <>
       requirements)
    |> String.slice(0, 4_000)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  # ── helpers ──

  # rule release 的源码：一个实现 contract 的规则模块（pattern/injection 即数据）
  defp rule_source(id, pattern, injection, plugin_id \\ nil) do
    plugin_id = plugin_id || "rule." <> slug(id)
    mod = Module.concat(["Newbee", "Plugins", "Rules", Macro.camelize(slug(id))])

    """
    defmodule #{inspect(mod)} do
      @moduledoc "沉睡规则 #{id}（JIT L2：平时零成本，触发才注入）"
      @behaviour Newbee.Environment.PluginContract

      @impl true
      def id, do: #{inspect(plugin_id)}
      @impl true
      def version, do: "1.0.0"
      @impl true
      def describe, do: %{kind: :rule, pattern: #{inspect(pattern)}, injection: #{inspect(injection)}, scope: :all}
      @impl true
      def dependencies, do: []

      def pattern, do: Regex.compile!(#{inspect(pattern)})
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
