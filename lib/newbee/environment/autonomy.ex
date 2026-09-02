defmodule Newbee.Environment.Autonomy do
  @moduledoc """
  Autonomy Policy（DESIGN §8.1）：环境变更（Change 激活）的自治档位。

  - `observe`：adapter 只产出建议与评测，不激活；
  - `manual`（默认）：评价通过后需人 `/approve` 激活；
  - `autonomous`：过门的 Change 自动激活/canary，事后通知可 `/undo`；
  - `emergency_stop`：冻结一切环境变更，仅允许回退。

  **激活判定 = 多套规则的合取**：

  ```text
  可激活 = Host Safety ∧ Capability Policy ∧ Autonomy 档位 ∧ Ring Gate ∧ 资源预算
  ```

  **自治是挣来的**：满足 ①已验证失败抗体数 ≥ 阈值 ②回放覆盖率 ≥ 阈值
  ③近 K 个 Change 无人工回退，Coordinator 才**建议**升 autonomous。
  """

  alias Newbee.Environment.Change

  @levels [:observe, :manual, :autonomous, :emergency_stop]
  @default :manual
  @config Path.join(System.user_home!(), ".newbee/config.json")

  # 各 kind 的自治上限（§8.1）：档位再高也不得突破
  @kind_caps %{
    tool: :autonomous,
    workflow: :autonomous,
    projection: :autonomous,
    rule: :autonomous_canary,
    prompt: :autonomous_canary,
    provider: :manual,
    stateful_service: :manual,
    adapter: :manual,
    evaluator: :manual,
    verifier: :manual
  }

  def levels, do: @levels
  def default, do: :manual

  def get do
    case File.read(@config) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"autonomy" => p}} when is_binary(p) -> normalize(String.to_atom(p))
          _ -> @default
        end

      _ ->
        @default
    end
  rescue
    _ -> @default
  end

  def set(level) when level in @levels do
    cfg =
      case File.read(@config) do
        {:ok, b} -> Jason.decode!(b)
        _ -> %{}
      end

    File.mkdir_p!(Path.dirname(@config))
    File.write!(@config, Jason.encode!(Map.put(cfg, "autonomy", to_string(level)), pretty: true))
    sync_coordinator(level)
    :ok
  end

  def set(level) when is_atom(level), do: {:error, :invalid_level}

  defp sync_coordinator(level) do
    coordinator = Newbee.Environment.Coordinator

    if Process.whereis(coordinator) do
      Newbee.Environment.Coordinator.set_autonomy(coordinator, level)
    end
  catch
    :exit, _reason -> :ok
  end

  defp normalize(l) when l in @levels, do: l
  defp normalize(_), do: @default

  # ── Ring Gate（§8.3）──

  @doc "kind 所在的 Ring（0-3）。Ring 0 = Host Shell，永不由当前模型激活。"
  def ring_of(:tool), do: 3
  def ring_of(:workflow), do: 3
  def ring_of(:projection), do: 3
  def ring_of(:rule), do: 2
  def ring_of(:prompt), do: 2
  def ring_of(:provider), do: 1
  def ring_of(:stateful_service), do: 1
  def ring_of(:adapter), do: 1
  def ring_of(:evaluator), do: 1
  def ring_of(:verifier), do: 1
  def ring_of(_), do: 1

  @doc "Ring 要求的评价层（§8.3 门槛映射）。"
  def required_layers(ring) do
    case ring do
      3 -> [:static, :deterministic, :canary]
      2 -> [:static, :deterministic, :canary, :counterfactual]
      1 -> [:static, :deterministic, :canary, :counterfactual, :cross_project]
      0 -> [:independent_release, :full_replay, :human_signoff]
    end
  end

  @doc """
  激活判定（合取）：{:allow, via} | {:deny, reason}。
  `via` ∈ :autonomous | :manual_approved | :canary。

  - emergency_stop：仅回退；
  - kind 自治上限封顶；
  - rule/prompt 即使 autonomous 也须先经 canary；
  - Ring 0 永远拒绝。
  """
  def activation_decision(kind, autonomy, opts \\ []) do
    approved? = Keyword.get(opts, :approved, false)
    canary_done? = Keyword.get(opts, :canary_done, false)
    rollback? = Keyword.get(opts, :rollback, false)

    cond do
      ring_of(kind) == 0 ->
        {:deny, :ring0_host_shell}

      autonomy == :emergency_stop and not rollback? ->
        {:deny, :emergency_stop}

      autonomy == :observe ->
        {:deny, :observe_only}

      rollback? ->
        # 回退在任何档位都允许（emergency_stop 只允许回退）
        {:allow, :rollback}

      true ->
        cap = Map.get(@kind_caps, kind, :manual)

        case {cap, autonomy} do
          {:manual, _} ->
            if approved?, do: {:allow, :manual_approved}, else: {:deny, :needs_approval}

          {_, :manual} ->
            if approved?, do: {:allow, :manual_approved}, else: {:deny, :needs_approval}

          {:autonomous, :autonomous} ->
            {:allow, :autonomous}

          {:autonomous_canary, :autonomous} ->
            if canary_done?, do: {:allow, :autonomous}, else: {:allow, :canary}
        end
    end
  end

  # ── 挣来的自治（§8.1）──

  @doc """
  是否建议升 autonomous。证据：
  - verified 抗体数 ≥ min_antibodies（默认 5）
  - 回放覆盖率 ≥ min_replay_coverage（默认 0.5）
  - 近 k 个 Change 无人工回退（默认 10）
  """
  def suggest_upgrade?(evidence, opts \\ []) do
    min_antibodies = Keyword.get(opts, :min_antibodies, 5)
    min_coverage = Keyword.get(opts, :min_replay_coverage, 0.5)
    k = Keyword.get(opts, :k, 10)

    verified = Map.get(evidence, :verified_antibodies, 0)
    coverage = Map.get(evidence, :replay_coverage, 0.0)
    recent = Map.get(evidence, :recent_changes, []) |> Enum.take(k)

    no_manual_rollback =
      Enum.all?(recent, fn
        %Change{status: s} -> s != :rolled_back
        %{"status" => s} -> s != "rolled_back"
        _ -> true
      end)

    verified >= min_antibodies and coverage >= min_coverage and no_manual_rollback
  end
end
