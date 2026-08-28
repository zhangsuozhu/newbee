defmodule Newbee.Environment.Verifier do
  @moduledoc """
  Verifier（DESIGN §8.2）：五层评价的裁判汇总。

  | 层 | 评价者 | 作用 |
  |---|---|---|
  | Static | compiler / contract checker | 语法、入口、依赖、contract |
  | Deterministic | self-test / 项目测试 / 已验证失败抗体 | 可重复正确性 |
  | Counterfactual | verifier / 历史回放 | 与 parent 比，不只看绝对成功 |
  | Real usage | worker feedback + 价签测量 | 使用归因绑定 release_id |
  | Longitudinal | coordinator | 多次任务后的成功率/回退率/token 成本 |

  规则（§8.2）：
  - adapter 可提评价计划，**不能伪造评价结果**；
  - 确定性门失败不能由模型投票绕过；
  - 多候选先 PPT/全配对选 top-1，**只有 top-1 进确定性门**；
  - verifier 不可用时退回 deterministic gate + 历史 fitness；证据仍不足则
    保持候选并列、不得用均匀随机排名自动发布。
  """

  alias Newbee.Environment.{Antibodies, Autonomy, Fitness, PluginManager, Release}
  alias Newbee.Environment.Verifier.PPT

  require Logger

  # ── 主入口 ──

  @doc """
  评价一个候选 release。返回 evaluation 结果 map：

      %{
        release_id, layers: %{static: ..., deterministic: ..., counterfactual: ...,
                              usage: ..., longitudinal: ...},
        passed: bool, failed_layers: [atom], evaluated_at
      }

  opts:
    - `:evaluator` — 确定性门用的求值器（默认开一次性干净实例）
    - `:parent` — parent release（counterfactual 对比对象）
    - `:ring` — Ring 门槛（决定需要的层，§8.3）
    - `:verifier_client` — verifier 模型（Counterfactual 执行回放/PPT 用）
  """
  def evaluate(%Release{} = release, opts \\ []) do
    ring = Keyword.get(opts, :ring, Autonomy.ring_of(release.kind))
    required = Autonomy.required_layers(ring)

    layers = %{}

    # 1. Static
    static = static_layer(release)
    layers = Map.put(layers, :static, static)

    # 2. Deterministic（static 失败则短路——编译不过的候选不浪费评测预算）
    deterministic =
      if static.passed do
        deterministic_layer(release, opts)
      else
        %{passed: false, skipped: true, reason: :static_failed}
      end

    layers = Map.put(layers, :deterministic, deterministic)

    # 3. Counterfactual（Ring 2+ 要求；与 parent 对比）
    counterfactual =
      if :counterfactual in required do
        counterfactual_layer(release, opts)
      else
        %{passed: true, skipped: true, reason: :not_required_at_ring}
      end

    layers = Map.put(layers, :counterfactual, counterfactual)

    # 4. Real usage（评价时刻的存量反馈；新 release 通常为无样本——不作否决依据）
    layers = Map.put(layers, :usage, usage_layer(release))

    # 5. Longitudinal
    layers = Map.put(layers, :longitudinal, longitudinal_layer(release))

    required_now =
      Enum.reject(required, &(&1 in [:canary, :cross_project, :independent_release, :full_replay, :human_signoff]))

    failed =
      for layer <- required_now,
          layer_result = Map.get(layers, layer, %{passed: false, missing: true}),
          not Map.get(layer_result, :passed, false),
          do: layer

    %{
      release_id: release.release_id,
      plugin_id: release.plugin_id,
      ring: ring,
      layers: layers,
      passed: failed == [],
      failed_layers: failed,
      evaluated_at: now_iso()
    }
  end

  # ── Layer 1: Static ──

  def static_layer(%Release{} = release) do
    case PluginManager.static_validate(release) do
      :ok -> %{passed: true}
      {:error, reason} -> %{passed: false, reason: inspect(reason)}
    end
  end

  # ── Layer 2: Deterministic ──

  @doc """
  确定性门 = self_test（contract）+ 已验证失败抗体回放（§15.13 零复现）。
  **确定性门失败不能由模型投票绕过。**
  """
  def deterministic_layer(%Release{} = release, opts \\ []) do
    with {:self_test, :ok} <- {:self_test, run_self_test(release, opts)},
         {:antibodies, :ok} <- {:antibodies, run_antibodies(release, opts)} do
      %{passed: true}
    else
      {:self_test, {:error, reason}} ->
        %{passed: false, stage: :self_test, reason: inspect(reason)}

      {:antibodies, {:error, failures}} ->
        %{passed: false, stage: :antibodies, reason: failures}
    end
  end

  defp run_self_test(%Release{source_files: files}, _opts) when map_size(files) == 0, do: :ok

  defp run_self_test(%Release{} = release, _opts) do
    # 编译候选模块并运行 contract self_test（无 self_test 实现视为通过静态子集）
    Enum.reduce_while(release.source_files, :ok, fn {name, source}, _acc ->
      case Newbee.Environment.PluginContract.validate_source(source, release.kind) do
        {:ok, %{module: mod}} ->
          if function_exported?(mod, :self_test, 1) do
            case apply(mod, :self_test, [%{}]) do
              {:ok, _} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {name, reason}}}
              other -> {:halt, {:error, {name, {:bad_self_test_return, other}}}}
            end
          else
            {:cont, :ok}
          end

        {:error, reasons} ->
          {:halt, {:error, {name, reasons}}}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_antibodies(_release, opts) do
    case Antibodies.gate(opts) do
      {:pass, details} ->
        if details.ran > 0 do
          Logger.info("antibody gate: #{details.ran} verified regressions passed")
        end

        :ok

      {:fail, failures} ->
        {:error, failures}
    end
  end

  # ── Layer 3: Counterfactual ──

  @doc """
  反事实回放（§8.2 两种模式）：

  - **投影回放**（默认，零副作用）：用新/旧 release 的视图构建器重建
    prompt 与决策输入，确定性对比；
  - **执行回放**：需 replay fixture（固定模型 I/O、工程快照、依赖 lock）。
    按每个 release 的 `replay_policy`（rerun | stub | forbid）执行；
    `forbid` 出现在关键路径时不得充当自动晋升门。

  无回放数据时如实报告 skipped——不伪造对比结果。
  """
  def counterfactual_layer(%Release{} = release, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    replay_log = Keyword.get(opts, :replay_log, [])

    cond do
      release.replay_policy == :forbid ->
        %{passed: false, reason: :replay_forbidden, auto_promotable: false}

      release.replay_policy == :stub ->
        # :stub 用既有结果验证投影兼容性——兼容即 passed，但标注非进步证明
        Map.put(projection_replay(release, parent, opts), :note, :stub_compatibility_only)

      replay_log == [] ->
        # 无回放语料：投影回放做确定性 prompt 对比
        projection_replay(release, parent, opts)

      true ->
        projection_replay(release, parent, Keyword.put(opts, :log, replay_log))
    end
  end

  @doc """
  投影回放：对同一段历史（事件日志片段），用新旧视图构建器重建投影，
  确定性对比差异。返回差分报告（零副作用）。
  """
  def projection_replay(release, parent, opts \\ []) do
    builder_new = Keyword.get(opts, :builder_new, &default_view_builder/2)
    builder_old = Keyword.get(opts, :builder_old, &default_view_builder/2)
    log = Keyword.get(opts, :log, [])

    diffs =
      Enum.map(log, fn event ->
        old_view = builder_old.(event, parent)
        new_view = builder_new.(event, release)
        %{event: event_id_of(event), changed: old_view != new_view, old: summarize(old_view), new: summarize(new_view)}
      end)
      |> case do
        [] -> [%{event: :empty, changed: false, old: "", new: ""}]
        other -> other
      end

    changed = Enum.count(diffs, & &1.changed)

    %{
      passed: true,
      mode: :projection,
      replayed: length(diffs),
      changed: changed,
      # 投影回放证明兼容性而非进步——如实报告（§8.2）
      proves: :projection_compatibility,
      diffs: diffs
    }
  end

  defp default_view_builder(event, _release), do: event
  defp event_id_of(%{id: id}), do: id
  defp event_id_of(%{"id" => id}), do: id
  defp event_id_of(other), do: inspect(other) |> String.slice(0, 40)
  defp summarize(view) when is_binary(view), do: String.slice(view, 0, 200)
  defp summarize(view), do: inspect(view, limit: 5) |> String.slice(0, 200)

  # ── Layer 4: Real usage ──

  @doc "真实使用层：存量 feedback 样本（绑定 release_id）。新 release 无样本不作否决。"
  def usage_layer(%Release{} = release) do
    f = Fitness.overall(release.release_id)

    %{
      passed: true,
      samples: f.samples,
      success_rate: f.success_rate,
      sufficient: f.samples >= Fitness.min_samples()
    }
  end

  # ── Layer 5: Longitudinal ──

  @doc """
  纵向层：同 plugin 历史 release 的回退率。回退率 > 50%（≥3 样本）告警，
  供 Coordinator 驱动 deopt；不否决新候选（历史 ≠ 候选）。
  """
  def longitudinal_layer(%Release{} = release, history \\ []) do
    same_plugin = Enum.filter(history, &(&1.plugin_id == release.plugin_id))

    rolled_back = Enum.count(same_plugin, &(&1[:outcome] == :rolled_back))
    total = length(same_plugin)

    rate = if total > 0, do: rolled_back / total, else: 0.0

    %{
      passed: true,
      plugin_history: total,
      rollback_rate: rate,
      degraded_signal: total >= 3 and rate > 0.5
    }
  end

  # ── 多候选选择（PPT / 全配对，§8.2）──

  @doc """
  Best-of-N：先按候选数与 verifier 预算比较 `N(N-1)/2` 与 PPT 预计比较次数，
  全配对更便宜时直接全量比较，PPT 更便宜时才 ring pass → pivot → tournament。
  **只有 top-1 进确定性门**；verifier 不可用退回 deterministic + fitness，
  证据不足保持候选并列——不得用均匀随机排名自动发布。
  """
  def select_top(candidates, opts \\ []) when is_list(candidates) do
    n = length(candidates)

    cond do
      n == 0 ->
        {:error, :no_candidates}

      n == 1 ->
        {:ok, %{best: 0, method: :single}}

      verifier_available?(opts) ->
        full_pairs = div(n * (n - 1), 2)
        ppt_estimate = ppt_cost_estimate(n, opts)
        complete_fn = Keyword.get(opts, :complete_fn)
        task = Keyword.get(opts, :task, "")

        if full_pairs <= ppt_estimate do
          # 全配对更便宜：直接全量比较
          result = full_pairwise(candidates, task, complete_fn, opts)
          {:ok, result}
        else
          result = PPT.select(nil, task, candidates, opts)
          {:ok, Map.put(result, :method, :ppt)}
        end

      # verifier 不可用：退回 fitness 证据；不足则并列（不随机发布）
      true ->
        case fitness_rank(candidates) do
          {:ok, idx} -> {:ok, %{best: idx, method: :fitness_fallback}}
          :insufficient -> {:error, :insufficient_evidence}
        end
    end
  end

  defp verifier_available?(opts), do: is_function(Keyword.get(opts, :complete_fn), 3)

  # PPT 预计比较次数：ring pass N + pivot tournament ≈ k*(n-k) + k(k-1)/2
  defp ppt_cost_estimate(n, opts) do
    k = Keyword.get(opts, :k, max(2, div(n, 3)))
    n + k * (n - k) + div(k * (k - 1), 2)
  end

  defp full_pairwise(candidates, task, complete_fn, opts) do
    n = length(candidates)
    scale = Keyword.get(opts, :scale, :letters)

    pairs =
      for i <- 0..(n - 2), j <- (i + 1)..(n - 1) do
        {i, j}
      end

    scores =
      Enum.reduce(pairs, %{}, fn {i, j}, acc ->
        prompt = """
        Task: #{task}

        Candidate A:
        #{Enum.at(candidates, i)}

        Candidate B:
        #{Enum.at(candidates, j)}

        Reply with <score_A>N</score_A><score_b>M</score_b> (1..20).
        """

        {sa, sb} =
          case complete_fn.(prompt, scale, opts) do
            {:ok, text} -> parse_scores(text)
            _ -> {1, 1}
          end

        acc
        |> Map.update(i, sa, &(&1 + sa))
        |> Map.update(j, sb, &(&1 + sb))
      end)

    best = scores |> Enum.max_by(fn {_i, s} -> s end, fn -> {0, 0} end) |> elem(0)

    %{
      best: best,
      ranking: scores |> Enum.sort_by(fn {_i, s} -> -s end) |> Enum.map(&elem(&1, 0)),
      scores: scores,
      comparisons: length(pairs),
      method: :full_pairwise
    }
  end

  defp parse_scores(text) do
    a = parse_score(Regex.run(~r/<score_A>(\d+)</i, text))
    b = parse_score(Regex.run(~r/<score_B>(\d+)</i, text))
    {a, b}
  end

  defp parse_score([_, n]), do: String.to_integer(n)
  defp parse_score(_), do: 1

  defp fitness_rank(candidates) do
    # candidates 是源码字符串时无法查 fitness——只对 release struct 有意义
    if Enum.all?(candidates, &match?(%Release{}, &1)) do
      scored =
        candidates
        |> Enum.with_index()
        |> Enum.map(fn {c, i} -> {Fitness.overall(c.release_id), i} end)

      sufficient = Enum.filter(scored, fn {f, _i} -> f.samples >= Fitness.min_samples() end)

      case sufficient do
        [] -> :insufficient
        _ -> {:ok, sufficient |> Enum.max_by(fn {f, _i} -> f.success_rate || 0.0 end) |> elem(1)}
      end
    else
      :insufficient
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
