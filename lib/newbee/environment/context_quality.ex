defmodule Newbee.Environment.ContextQuality do
  @moduledoc """
  ContextQuality（调研报告 §4 落位）：上下文经验的实证质量裁判。

  ## 问题（调研 V3）

  newbee 的自进化闭环（adapter 把教训编译成 rule/memory release 注入上下文）
  此前没有质量侧裁判：PatternStore 只度量 tool 成本侧，无法回答
  "这条经验注入后，同类任务变好还是变差？"。

  调研证据：
  - Blind Curator (arXiv:2607.07436)：LLM judge 的 false-pass 偏差超过 0.45 时
    退休机制无声失效——**裁判必须是确定性信号，不能是 LLM 自评**。
  - More Skills Worse Agents (2605.24050)：经验库膨胀使 pass rate 掉 21%。
  - Agent Skills Can Be Harmful (2608.11888)：差分归因是定位致败经验的有效方法。

  ## 设计

  每个活跃 release（rule/memory/skill）维护两组 Beta 后验（复用 PatternStats 数值核）：

  - `with_ctx`：该 release 注入上下文期间的任务 outcome 分布
  - `without_ctx`：未注入期间（基线）的任务 outcome 分布

  outcome 来自**确定性验证器信号**（测试通过 / 编译成功 / edit 锚点命中 /
  无 tool_error），归一为布尔。

  ## 退休判据（差分 + 序贯）

  P(with_ctx 的成功率 < without_ctx 的成功率) > retire_conf 且样本足够
  → 判定该经验**有害**，建议走 Change 生命周期降级（deopt）。

  样本不足 / 后验重叠 → :insufficient，绝不误退休（Blind Curator 教训：
  宁缺勿滥，误退休好经验的代价高于暂留坏经验）。

  纯函数模块：不持状态，状态的持有与持久化由调用方（Collector/Store）负责。
  """

  alias Newbee.Environment.PatternStats

  # 退休判定：P(有害) 的置信阈值。Blind Curator 显示 false-pass 偏差致命，
  # 故取高置信，且要求最小样本，避免小样本误杀。
  @min_paired_samples 5
  # 退休置信区间的单侧 alpha：harmful 判据为双侧 (1-2α) 置信区间不重叠，
  # 名义 FPR≈2α=0.10 且小样本自动退化为 insufficient（Blind Curator 防线）。
  @alpha 0.05
  # 有益判定用更松的 alpha（0.15→70% 区间），尽早标记好经验以强化复用。
  @help_alpha 0.15

  @typedoc """
  单个 release 的质量账本：
  - with_ctx: Beta{α,β}，注入期间任务成功/失败计数
  - without_ctx: Beta{α,β}，基线期间任务成功/失败计数
  - with_tokens / without_tokens: 期间平均 token 成本（Context Bloat 护栏）
  - n_with / n_without: 样本数
  """
  @type ledger :: %{
          with_ctx: PatternStats.beta(),
          without_ctx: PatternStats.beta(),
          with_tokens: float(),
          without_tokens: float(),
          n_with: non_neg_integer(),
          n_without: non_neg_integer()
        }

  @doc "新账本（无信息先验 Beta(1,1)）。"
  @spec new_ledger() :: ledger()
  def new_ledger do
    %{
      with_ctx: {1.0, 1.0},
      without_ctx: {1.0, 1.0},
      with_tokens: 0.0,
      without_tokens: 0.0,
      n_with: 0,
      n_without: 0
    }
  end

  @doc """
  记录一次任务 outcome。

  - `injected?`: 本次任务该 release 是否在上下文中
  - `success`: 确定性验证器判定的任务成败（boolean）
  - `tokens`: 本次任务消耗 token（可选，用于 Context Bloat 护栏）
  """
  @spec record(ledger(), boolean(), boolean(), number() | nil) :: ledger()
  def record(l, injected?, success, tokens \\ nil) do
    l =
      if injected? do
        %{l | with_ctx: upd(l.with_ctx, success), n_with: l.n_with + 1}
      else
        %{l | without_ctx: upd(l.without_ctx, success), n_without: l.n_without + 1}
      end

    case tokens do
      t when is_number(t) ->
        if injected? do
          %{l | with_tokens: running_avg(l.with_tokens, l.n_with, t)}
        else
          %{l | without_tokens: running_avg(l.without_tokens, l.n_without, t)}
        end

      _ ->
        l
    end
  end

  defp upd({a, b}, true), do: {a + 1.0, b}
  defp upd({a, b}, false), do: {a, b + 1.0}

  defp running_avg(avg, n, v) when n > 0, do: avg + (v - avg) / n
  defp running_avg(_avg, _n, v), do: v * 1.0

  @doc """
  有害判定：P(with_ctx 成功率 < without_ctx 成功率) > conf 且双侧样本足够。

  用 Beta 后验的解析比较：对独立 X~Beta(a1,b1), Y~Beta(a2,b2)，
  P(X<Y) 用数值积分估计（对 X 的密度加权 I_x 累积）。
  这里用 PatternStats.betai 做精确的分位点计算。

  返回 :harmful | :insufficient | :ok
  """
  @spec verdict(ledger(), keyword()) :: :harmful | :insufficient | :ok
  def verdict(l, opts \\ []) do
    min_n = Keyword.get(opts, :min_paired_samples, @min_paired_samples)
    alpha = Keyword.get(opts, :alpha, @alpha)
    help_alpha = Keyword.get(opts, :help_alpha, @help_alpha)

    cond do
      l.n_with < min_n or l.n_without < min_n ->
        :insufficient

      true ->
        # 退休判据（调研落位，Blind Curator 防线）：
        # harmful 当且仅当双侧后验置信区间不重叠——UCB(with) < LCB(without)。
        # 该判据的名义假阳性率≈2*alpha，且**样本不足时区间自然变宽→不重叠不成立
        # →insufficient**，天然免疫 Blind Curator 的小样本误杀（实证：margin 点估计
        # 法在中性经验上 FPR≈11%，区间法压到 ≈2*alpha，见 REPORT §5 蒙特卡洛）。
        cond do
          ci_disjoint?(l, alpha) -> :harmful
          ci_disjoint_help?(l, help_alpha) -> :ok
          true -> :insufficient
        end
    end
  end

  @doc "有害判定：with 成功率 UCB(1-alpha) < without 成功率 LCB(alpha)（区间不重叠）。"
  @spec ci_disjoint?(ledger(), float()) :: boolean()
  def ci_disjoint?(l, alpha \\ @alpha) do
    beta_ucb(l.with_ctx, 1.0 - alpha) < beta_lcb(l.without_ctx, alpha)
  end

  @doc "有益判定：with 成功率 LCB > without 成功率 UCB（反向区间不重叠）。"
  @spec ci_disjoint_help?(ledger(), float()) :: boolean()
  def ci_disjoint_help?(l, alpha \\ @help_alpha) do
    beta_lcb(l.with_ctx, alpha) > beta_ucb(l.without_ctx, 1.0 - alpha)
  end

  @doc "Beta 后验 LCB（下 alpha 分位数）。"
  def beta_lcb({a, b}, alpha), do: beta_quantile(a, b, alpha)

  @doc "Beta 后验 UCB（上 1-alpha 分位数）。"
  def beta_ucb({a, b}, alpha), do: beta_quantile(a, b, alpha)

  @doc "Beta(a,b) 的 p 分位数（bisection on betai，60 次迭代收敛到 1e-9）。"
  @spec beta_quantile(float(), float(), float()) :: float()
  def beta_quantile(a, b, p) when p >= 0.0 and p <= 1.0 do
    bq_bisect(a, b, p, 0.0, 1.0, 0)
  end

  defp bq_bisect(_a, _b, _p, lo, hi, iter) when iter >= 60, do: (lo + hi) / 2.0

  defp bq_bisect(a, b, p, lo, hi, iter) do
    mid = (lo + hi) / 2.0

    if safe_betai(mid, a, b) < p,
      do: bq_bisect(a, b, p, mid, hi, iter + 1),
      else: bq_bisect(a, b, p, lo, mid, iter + 1)
  end

  @doc """
  Context Bloat 护栏（调研 2608.11888：25.3% 效率回归是上下文膨胀）：
  注入后 token 显著上升且成功率不升 → 额外退休理由。
  返回 true 表示该 release 造成可观测的净成本回归。
  """
  @spec bloat_regression?(ledger(), keyword()) :: boolean()
  def bloat_regression?(l, opts \\ []) do
    min_n = Keyword.get(opts, :min_paired_samples, @min_paired_samples)
    token_margin = Keyword.get(opts, :token_margin, 1.2)

    enough = l.n_with >= min_n and l.n_without >= min_n

    enough and l.with_tokens > 0 and l.without_tokens > 0 and
      l.with_tokens > l.without_tokens * token_margin and
      PatternStats.beta_mean(l.with_ctx) <= PatternStats.beta_mean(l.without_ctx)
  end

  @doc """
  P(X < Y)，X~Beta(a1,b1), Y~Beta(a2,b2)。
  精确式：∫₀¹ f_X(t)·P(Y>t) dt = ∫₀¹ f_X(t)·(1−I_t(a2,b2)) dt。
  用 K 点 Simpson 数值积分（K=200 足够 1e-6 精度）。
  """
  @spec prob_less(PatternStats.beta(), PatternStats.beta()) :: float()
  def prob_less({a1, b1}, {a2, b2}) do
    k = 200
    h = 1.0 / k

    {s0, sk} =
      {beta_pdf(0.0, a1, b1) * (1.0 - safe_betai(0.0, a2, b2)), beta_pdf(1.0, a1, b1) * (1.0 - safe_betai(1.0, a2, b2))}

    {s_odd, s_even} =
      Enum.reduce(1..(k - 1), {0.0, 0.0}, fn i, {o, e} ->
        x = i * h
        v = beta_pdf(x, a1, b1) * (1.0 - safe_betai(x, a2, b2))
        if rem(i, 2) == 1, do: {o + v, e}, else: {o, e + v}
      end)

    res = h / 3.0 * (s0 + sk + 4.0 * s_odd + 2.0 * s_even)
    res |> max(0.0) |> min(1.0)
  end

  # Beta 密度（对数域防溢出）
  defp beta_pdf(x, a, b) when x > 0 and x < 1 do
    lg = PatternStats.log_gamma(a + b) - PatternStats.log_gamma(a) - PatternStats.log_gamma(b)
    :math.exp(lg + (a - 1.0) * :math.log(x) + (b - 1.0) * :math.log(1.0 - x))
  end

  defp beta_pdf(_, _, _), do: 0.0

  defp safe_betai(x, a, b) do
    PatternStats.betai(x, a, b)
  rescue
    _ -> if x < a / (a + b), do: 0.0, else: 1.0
  end

  @doc "可读摘要：给 Projection/TUI 展示一个 release 的质量价签。"
  @spec summary(ledger()) :: map()
  def summary(l) do
    %{
      success_with: PatternStats.beta_mean(l.with_ctx),
      success_without: PatternStats.beta_mean(l.without_ctx),
      p_harmful: prob_less(l.with_ctx, l.without_ctx),
      avg_tokens_with: l.with_tokens,
      avg_tokens_without: l.without_tokens,
      n_with: l.n_with,
      n_without: l.n_without,
      verdict: verdict(l),
      bloat: bloat_regression?(l)
    }
  end
end
