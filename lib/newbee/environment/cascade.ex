defmodule Newbee.Environment.Cascade do
  @moduledoc """
  级联收益模型（TCE 总纲 C 节，[D15]，R6）。

  三形态运行时是"便宜优先"的级联：
    新输入 → L2 规则拦截（零 token，读规则成本 C_l2）→ 未命中走推理 C_infer
           → L3 工具命中则整个循环短路（0 token）

  一次 pattern 出现的期望节省：
    E[save] = P(l3)·C_infer + P(l2_only)·(C_infer − C_l2)

  未来窗口 W 内出现次数 = λ·W（Gamma 后验均值），总期望节省 = 二者乘积。
  """

  alias Newbee.Environment.PatternStats

  @default_c_infer 3000.0
  @default_c_l2 200.0
  @window_days 30.0

  @doc "单次级联期望节省。p_l2/p_l3 来自 L1/L2/L3 各形态的命中后验（缺省用同一 stats 的 succ）。"
  def per_hit(%PatternStats{} = s, opts \\ []) do
    c_infer = opts[:c_infer] || @default_c_infer
    c_l2 = opts[:c_l2] || @default_c_l2
    p_l3 = opts[:p_l3] || PatternStats.succ_mean(s)
    p_l2 = opts[:p_l2] || (p_l3 * 1.5) |> min(1.0)
    p_l3 * c_infer + max(p_l2 - p_l3, 0.0) * (c_infer - c_l2)
  end

  @doc "窗口内总期望节省 = E[λ]·W · per_hit。"
  def expected_benefit(%PatternStats{} = s, opts \\ []) do
    window = opts[:window_days] || @window_days
    PatternStats.freq_mean(s) * window * per_hit(s, opts)
  end

  @doc "带不确定性的净收益 LCB：复用 PatternStats.net_lcb 的 delta 法但用级联 save。"
  def net_lcb(%PatternStats{} = s, compile_cost, opts \\ []) do
    kappa = Keyword.get(opts, :kappa, 1.0)
    e_l = PatternStats.freq_mean(s)
    sd_l = PatternStats.freq_sd(s)
    e_s = per_hit(s, opts)
    n_s = max(s.n, 1)
    sd_s = max(e_s * 0.3 / :math.sqrt(n_s), e_s * 0.15)
    mean_net = e_l * window_of(opts) * e_s
    var_net = :math.pow(window_of(opts), 2) * (e_l * e_l * sd_s * sd_s + e_s * e_s * sd_l * sd_l)
    mean_net - kappa * :math.sqrt(var_net) - compile_cost
  end

  defp window_of(opts), do: Keyword.get(opts, :window_days, @window_days)
end
