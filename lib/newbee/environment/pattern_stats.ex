defmodule Newbee.Environment.PatternStats do
  @moduledoc """
  PatternStats（TCE 总纲 A 节）：pattern 级三组共轭后验。

  - freq: Gamma(a, b) + Poisson → 出现频率 λ 后验
  - succ: Beta(α, β) + Bernoulli → 成功率 p 后验
  - save: 正态-正态 → 单次节省 token 幅度后验

  纯函数集合：更新、时间衰减、估计、LCB、EB 收缩。
  数值方法：Lanczos logΓ、递推 ψ/ψ'、NR Lentz 连分数 I_x(a,b) 与 P(a,x)、
  分位数 bisection。判据是序贯检验，1e-8 精度足够（TCE 总纲 A/B 节）。
  """

  defstruct freq: {1.0, 1.0}, succ: {1.0, 1.0}, save: {0.0, 0.0, 1.0},
            n: 0, last_update: nil, snapshot: %{a: nil, b: nil}

  @type t :: %__MODULE__{}
  @type gamma :: {float(), float()}
  @type beta :: {float(), float()}

  # ═══════════════ 特殊函数 ═══════════════

  @doc "log Γ(x)，Lanczos (g=7)。x>0。"
  def log_gamma(x) when x > 0 do
    z = x - 1.0
    coefs = [0.999_999_999_999_809_93, 676.5203681218851, -1259.1392167224028,
             771.32342877765313, -176.61502916214059, 12.507343278686905,
             -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7]

    sum =
      coefs
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn
        {c, 0}, acc -> acc + c
        {c, i}, acc -> acc + c / (z + i)
      end)

    t = z + 7.5
    0.5 * :math.log(2 * :math.pi()) + (z + 0.5) * :math.log(t) - t + :math.log(sum)
  end

  @doc "digamma ψ(x)，x>0（递推至 x≥6 渐近展开）。"
  def digamma(x) when x > 0, do: dg(x, 0.0)

  defp dg(x, acc) when x < 6.0, do: dg(x + 1.0, acc - 1.0 / x)

  defp dg(x, acc) do
    inv = 1.0 / x
    inv2 = inv * inv
    acc + :math.log(x) - 0.5 * inv -
      inv2 * (1.0 / 12.0 - inv2 * (1.0 / 120.0 - inv2 / 252.0))
  end

  @doc "trigamma ψ'(x)，x>0。"
  def trigamma(x) when x > 0, do: tg(x, 0.0)

  defp tg(x, acc) when x < 6.0, do: tg(x + 1.0, acc + 1.0 / (x * x))

  defp tg(x, acc) do
    inv = 1.0 / x
    inv2 = inv * inv
    acc + inv * (1.0 + 0.5 * inv + inv2 * (1.0 / 6.0 - inv2 * (1.0 / 30.0 - inv2 / 42.0)))
  end

  @doc "正则化不完全 Beta I_x(a,b)（NR Lentz 连分数）。"
  def betai(x, _a, _b) when x <= 0.0, do: 0.0
  def betai(x, _a, _b) when x >= 1.0, do: 1.0

  def betai(x, a, b) do
    front =
      :math.exp(log_gamma(a + b) - log_gamma(a) - log_gamma(b) +
                  a * :math.log(x) + b * :math.log(1.0 - x))

    if x < (a + 1.0) / (a + b + 2.0) do
      front * betacf(a, b, x) / a
    else
      1.0 - front * betacf(b, a, 1.0 - x) / b
    end
  end

  defp betacf(a, b, x) do
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0
    d0 = 1.0 - qab * x / qap
    d0 = if abs(d0) < 1.0e-30, do: 1.0e-30, else: d0
    d0 = 1.0 / d0
    betacf_loop(1, a, b, x, qab, qap, qam, 1.0, d0, d0)
  end

  defp betacf_loop(m, a, b, x, qab, qap, qam, c, d, h) do
    m2 = 2 * m

    aa1 = m * (b - m) * x / ((qam + m2) * (a + m2))
    d1 = 1.0 + aa1 * d
    d1 = if abs(d1) < 1.0e-30, do: 1.0e-30, else: d1
    c1 = 1.0 + aa1 / c
    c1 = if abs(c1) < 1.0e-30, do: 1.0e-30, else: c1
    d1 = 1.0 / d1
    h1 = h * d1 * c1

    aa2 = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
    d2 = 1.0 + aa2 * d1
    d2 = if abs(d2) < 1.0e-30, do: 1.0e-30, else: d2
    c2 = 1.0 + aa2 / c1
    c2 = if abs(c2) < 1.0e-30, do: 1.0e-30, else: c2
    d2 = 1.0 / d2
    del = d2 * c2
    h2 = h1 * del

    cond do
      abs(del - 1.0) < 3.0e-12 -> h2
      m > 300 -> h2
      true -> betacf_loop(m + 1, a, b, x, qab, qap, qam, c2, d2, h2)
    end
  end

  @doc "正则化下不完备 Gamma P(a,x)（NR：x<a+1 级数，否则连分数）。"
  def gammainc_p(a, x) when a > 0 and x > 0 do
    front = :math.exp(-x + a * :math.log(x) - log_gamma(a))

    if x < a + 1.0 do
      # 级数分支已含 front（finish_series 内乘）
      gser(a, x, 1.0 / a, 1.0 / a, 0)
    else
      # 连分数给出 Q(a,x) = front × cf；P = 1 − Q
      1.0 - front * gcf(a, x)
    end
  end

  def gammainc_p(_a, _x), do: 0.0

  defp gser(a, x, sum, _del, n) when n > 300, do: finish_series(a, x, sum)

  defp gser(a, x, sum, del, n) do
    del_next = del * (x / (a + n + 1))
    sum_next = sum + del_next

    if abs(del_next) < abs(sum_next) * 1.0e-14 do
      finish_series(a, x, sum_next)
    else
      gser(a, x, sum_next, del_next, n + 1)
    end
  end

  defp finish_series(a, x, sum) do
    sum * :math.exp(-x + a * :math.log(x) - log_gamma(a))
  end

  defp gcf(a, x) do
    tiny = 1.0e-30
    # 标准 NR gcf：b 从 x+1-a 起，每轮 +1；d/c 用 Lentz
    b0 = x + 1.0 - a
    c0 = 1.0 / tiny
    d0 = 1.0 / b0
    h0 = d0
    gcf_iter2(a, x, b0, c0, d0, h0, 1)
  end

  defp gcf_iter2(_a, _x, _b, _c, _d, h, n) when n > 300, do: h

  defp gcf_iter2(a, x, b, c, d, h, n) do
    an = -1.0 * n * (n - a)
    b2 = b + 2.0
    dn = an * d + b2
    dn = if abs(dn) < 1.0e-30, do: 1.0e-30, else: dn
    cn = b2 + an / c
    cn = if abs(cn) < 1.0e-30, do: 1.0e-30, else: cn
    dn = 1.0 / dn
    del = dn * cn
    hn = h * del

    if abs(del - 1.0) < 3.0e-12 or n > 300 do
      hn
    else
      gcf_iter2(a, x, b, cn, dn, hn, n + 1)
    end
  end

  @doc """
  Beta 分位数（bisection，保收敛）[U-数值]：给 q 求使 I_x(alpha,beta)=q 的 x。80 次二分达 1e-12 区间宽。
  """
  def beta_quantile(q, {a, b}) when q > 0.0 and q < 1.0 do
    bisect_beta(0.0, 1.0, q, a, b, 80)
  end

  defp bisect_beta(lo, hi, _q, _a, _b, iter) when iter <= 0 or hi - lo < 1.0e-12 do
    (lo + hi) / 2.0
  end

  defp bisect_beta(lo, hi, q, a, b, iter) do
    mid = (lo + hi) / 2.0

    if betai(mid, a, b) < q do
      bisect_beta(mid, hi, q, a, b, iter - 1)
    else
      bisect_beta(lo, mid, q, a, b, iter - 1)
    end
  end

  # ═══════════════ 统计更新 ═══════════════

  @doc "新 stats：可指定先验。默认弱信息先验 Gamma(1,1)、Beta(1,1)。"
  def new(opts \\ []) do
    %__MODULE__{
      freq: opts[:freq] || {1.0, 1.0},
      succ: opts[:succ] || {1.0, 1.0},
      save: opts[:save] || {0.0, 0.0, 1.0}
    }
  end

  @doc """
  记录一次 pattern 出现。
  obs: %{count: 出现次数(默认1), success: boolean | nil, saved_tokens: float | nil,
         at: DateTime | nil}
  """
  def observe(%__MODULE__{} = s, obs) do
    count = obs[:count] || 1
    freq = update_freq(s.freq, count)

    succ =
      case fetch_bool(obs, :success) do
        nil -> s.succ
        ok -> update_succ(s.succ, ok)
      end

    save =
      case obs[:saved_tokens] do
        v when is_number(v) ->
          # count 次观测同一幅度（事件级聚合），有效样本数同步增长
          Enum.reduce(1..count, s.save, fn _, acc -> update_save(acc, v * 1.0) end)

        _ ->
          s.save
      end

    %__MODULE__{
      s
      | freq: freq,
        succ: succ,
        save: save,
        n: s.n + count,
        last_update: obs[:at] || DateTime.utc_now()
    }
  end

  defp fetch_bool(map, key) do
    case Map.get(map, key) do
      true -> true
      false -> false
      _ -> nil
    end
  end

  defp update_freq({a, b}, k), do: {a + k, b}
  defp update_succ({alpha, beta}, true), do: {alpha + 1.0, beta}
  defp update_succ({alpha, beta}, false), do: {alpha, beta + 1.0}

  @doc "节省幅度观测更新：均值增量式，k 计数，方差保守下界 1.0。"
  def update_save({m, k, s2}, v) do
    k2 = k + 1.0
    m2 = (v + k * m) / k2
    {m2, k2, max(s2, 1.0)}
  end

  @doc "指数时间衰减 [D6]：充分统计量乘 gamma∈(0,1]，缩放后仍是合法共轭形态。"
  def decay(%__MODULE__{} = s, gamma_factor) when gamma_factor > 0 and gamma_factor <= 1 do
    {a, b} = s.freq
    {al, be} = s.succ
    {m, k, s2} = s.save

    %__MODULE__{
      s
      | freq: {max(a * gamma_factor, 1.0e-6), max(b * gamma_factor, 1.0e-6)},
        succ: {max(al * gamma_factor, 1.0e-6), max(be * gamma_factor, 1.0e-6)},
        save: {m, max(k * gamma_factor, 0.5), s2},
        n: trunc(s.n * gamma_factor)
    }
  end

  # ═══════════════ 估计 ═══════════════

  @doc "频率后验均值 E[λ] = a/b。"
  def freq_mean(%__MODULE__{freq: ab}), do: elem(ab, 0) / elem(ab, 1)

  @doc "频率后验标准差 sqrt(a)/b。"
  def freq_sd(%__MODULE__{freq: {a, b}}), do: :math.sqrt(a) / b

  @doc "成功率后验均值。"
  def succ_mean(%__MODULE__{succ: ab}), do: beta_mean(ab)

  @doc "节省幅度后验均值。"
  def save_mean(%__MODULE__{save: {m, _k, _s2}}), do: m

  @doc "Beta 均值。"
  def beta_mean({a, b}), do: a / (a + b)

  @doc "Beta 方差。"
  def beta_var({a, b}) do
    s = a + b
    a * b / (s * s * (s + 1.0))
  end

  @doc "Gamma 均值 a/b。"
  def gamma_mean({a, b}), do: a / b

  @doc "Gamma 方差 a/b²。"
  def gamma_var({a, b}), do: a / (b * b)

  # ═══════════════ 决策判据（总纲 B/C）═══════════════

  @doc "净收益置信下界 [D14][D10]：E[λ]·E[save] − κ·σ(net) − C，delta 法方差近似。"
  def net_lcb(%__MODULE__{} = s, compile_cost, opts \\ []) do
    kappa = opts[:kappa] || 1.0
    e_l = freq_mean(s)
    sd_l = freq_sd(s)
    e_s = max(save_mean(s), 0.0)
    n_s = max(save_n(s), 1.0)
    sd_s = e_s * 0.5 / :math.sqrt(n_s)
    mean_net = e_l * e_s
    var_net = e_l * e_l * sd_s * sd_s + e_s * e_s * sd_l * sd_l
    mean_net - kappa * :math.sqrt(var_net) - compile_cost
  end

  defp save_n(%__MODULE__{save: {_m, k, _s2}}), do: k

  @doc """
  非对称区间净收益 [U3, omega-UCB 启发]：
  benefit 端取 LCB（保守收益），compile_cost 端取 UCB（悲观成本）。
  排序分 = LCB(benefit) - UCB(C)。比对称 kappa*sigma 更贴合预算语义 (P4)。
  z 为单侧分位倍数（默认 1.645 约 95%）。
  """
  def net_asym(%__MODULE__{} = s, compile_cost, opts \\ []) do
    z = Keyword.get(opts, :z, 1.645)
    cost_cv = Keyword.get(opts, :cost_cv, 0.5)
    e_l = freq_mean(s)
    sd_l = freq_sd(s)
    e_s = max(save_mean(s), 0.0)
    n_s = max(save_n(s), 1.0)
    sd_s = e_s * 0.5 / :math.sqrt(n_s)

    benefit_lcb = e_l * e_s - z * :math.sqrt(e_l * e_l * sd_s * sd_s + e_s * e_s * sd_l * sd_l)
    c_ucb = compile_cost * (1.0 + z * cost_cv / :math.sqrt(n_s))
    benefit_lcb - min(c_ucb, compile_cost * 2.0)
  end

  @doc "编译建议：样本足够且 net_lcb > 0。"
  def compile_worthy?(%__MODULE__{} = s, compile_cost, opts \\ []) do
    s.n >= Keyword.get(opts, :min_samples, 3) and net_lcb(s, compile_cost, opts) > 0.0
  end

  @doc """
  deopt 双通道判据 [D17]（R8）：工具坏 vs 分布漂移分离处置。
  返回 {:tool_broken, reason} | {:drifted, reason} | :keep
  """
  def deopt_decision(%__MODULE__{} = s, opts \\ []) do
    p_min = opts[:p_min] || 0.5
    conf = opts[:conf] || 0.95
    h = opts[:h] || 3.0
    broken = tool_broken?(s, p_min, conf)
    dropped = freq_dropped?(s, h)

    cond do
      broken and not dropped ->
        {:tool_broken, "success posterior below threshold while frequency stable"}

      dropped ->
        {:drifted, "frequency mean fell h sigma below compile-time snapshot"}

      true ->
        :keep
    end
  end

  @doc "工具坏判定 [D17-A]：Beta 后验 P(p < p_min) > conf，且需足够证据(α+β>6)。"
  def tool_broken?(%__MODULE__{succ: {al, be}}, p_min \\ 0.5, conf \\ 0.95) do
    al + be > 6.0 and betai(p_min, al, be) > conf
  end

  @doc "漂移判定 [D17-B]：相对编译时快照的频率均值跌落超过 h×σ。"
  def freq_dropped?(s, h \\ 3.0)

  def freq_dropped?(%__MODULE__{snapshot: %{a: sa, b: sb}} = s, h)
      when is_number(sa) and is_number(sb) do
    lambda0 = sa / sb
    lambda_now = freq_mean(s)
    sd = max(freq_sd(s), 1.0e-9)
    (lambda0 - lambda_now) / sd > h
  end

  def freq_dropped?(_s, _h), do: false

  @doc "记录编译时快照 [D8][D11]：供漂移检测与校准评分。"
  def take_snapshot(%__MODULE__{} = s) do
    snap =
      Map.merge(s.snapshot, %{
        a: elem(s.freq, 0),
        b: elem(s.freq, 1),
        predicted_save_mean: save_mean(s),
        n_at_snapshot: s.n
      })

    %{s | snapshot: snap}
  end

  # ═══════════════ Empirical Bayes 收缩 [D12] ═══════════════

@doc """
  EB 收缩（v2.1 James-Stein 标准形式 [R4]）：
  shrunk_mu = w*m_bar + (1-w)*mu_i, 其中 w = var_m/(var_m+var_i)
  （个体方差相对群体方差越小，越信任个体）。
  收缩后方差同步折减（信息增加 → 不确定性下降）：
    shrunk_var = (1-shrink*w) * var_i
  Gamma(a,b) 重参数化: 给定目标 mu/var 反解 a=mu²/var, b=mu/var。
  群体样本 < 5 时不动 target（EB 无群体信息可用）。
  """
  def eb_shrink(stats_list, %__MODULE__{} = target, shrink)
      when shrink >= 0.0 and shrink <= 1.0 do
    n = length(stats_list)

    if n < 5 do
      target
    else
      means = Enum.map(stats_list, &freq_mean/1)
      m_bar = Enum.sum(means) / n

      var_m =
        Enum.reduce(means, 0.0, fn m, acc -> acc + (m - m_bar) * (m - m_bar) end) /
          max(n - 1, 1)

      var_i = gamma_var(target.freq)
      mu_i = freq_mean(target)

      # James-Stein 权重: 个体方差越大(越不可信) → 越向群体收缩
      w = var_i / (var_m + var_i + 1.0e-12)

      eff = shrink * w
      shrunk_mu = eff * m_bar + (1.0 - eff) * mu_i
      shrunk_var = max((1.0 - eff), 0.05) * var_i

      # Gamma 重参数化（mu>0 守卫）
      mu_safe = max(shrunk_mu, 1.0e-6)
      b_new = mu_safe / max(shrunk_var, 1.0e-12)
      a_new = mu_safe * b_new

      %{target | freq: {a_new, b_new}}
    end
  end
end
