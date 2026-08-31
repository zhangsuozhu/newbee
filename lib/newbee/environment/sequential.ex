defmodule Newbee.Environment.Sequential do
  @moduledoc """
  序贯检验与变化点检测（TCE v2, THEORY-V2.md U1/U2）。

  - SPRT (Wald 1945; Wald-Wolfowitz 最优性): Bernoulli 成功率的序贯假设检验。
    在两类错误 alpha/beta 约束下期望样本数最小——deopt 判据的理论正确形态。

  - CUSUM (Page 1954): 单侧累积漂移检测 S_{n+1} = max(0, S_n + x_t - omega)。
    对缓漂敏感、对偶发噪声鲁棒，ARL 由阈值 h 直接控制——频率漂移检测的正确形态。

  全部纯函数、O(1) 状态（一个累加器），可 property 测试。
  """

  # ── U1: Bernoulli SPRT ──

  @doc """
  Bernoulli SPRT 单步更新。
  state: %{s: 累积log-LR, decided: nil | :h0 | :h1}
  H0: p = p_ok (健康), H1: p = p_bad (坏)
  opts: p_ok(0.8), p_bad(0.3), alpha(0.05), beta(0.05)
  返回新 state。decided 后冻结（调用方负责重置策略）。
  """
  def sprt_step(state, success?, opts \\ [])

  def sprt_step(%{decided: d} = state, _ok, _opts) when d != nil, do: state

  def sprt_step(state, ok?, opts) when is_boolean(ok?) do
    p_ok = Keyword.get(opts, :p_ok, 0.8)
    p_bad = Keyword.get(opts, :p_bad, 0.3)
    alpha = Keyword.get(opts, :alpha, 0.05)
    beta = Keyword.get(opts, :beta, 0.05)

    # llr = log f(x|H1)/f(x|H0)，H1=p_bad(坏), H0=p_ok(健康)
    px = if ok?, do: p_bad, else: 1.0 - p_bad
    py = if ok?, do: p_ok, else: 1.0 - p_ok

    # log 似然比 log f(x|H1)/f(x|H0)；px/py 恒 > 0（p 不取 0/1）
    llr = :math.log(px / py)

    a = :math.log(beta / (1.0 - alpha))
    b = :math.log((1.0 - beta) / alpha)

    s = state.s + llr

    decided =
      cond do
        # 接受"工具坏" -> deopt
        s >= b -> :h1
        # 接受"工具健康" -> 清白重置
        s <= a -> :h0
        true -> nil
      end

    %{state | s: s, decided: decided}
  end

  @doc """
  SPRT 决定后的滚动重置 [R8]：生产中一次判定不是终点——h0 后世界可能变坏、
  h1 后修复可能恢复。重置清零证据，开启新一轮监控，rounds 记录已完成轮数。
  """
  def sprt_roll(%{decided: nil} = state), do: state

  def sprt_roll(state) do
    %{state | s: 0.0, decided: nil, n: 0, rounds: (state[:rounds] || 0) + 1}
  end

  @doc "SPRT 初始状态。"
  def sprt_init, do: %{s: 0.0, decided: nil, n: 0, rounds: 0}

  @doc "带计数的单步（n 记录已消耗样本数，供审计）。"
  def sprt_step_counted(state, ok?, opts \\ [])

  def sprt_step_counted(%{decided: d} = state, _ok, _opts) when d != nil, do: state

  def sprt_step_counted(state, ok?, opts) do
    st = sprt_step(state, ok?, opts)
    %{st | n: state.n + 1}
  end

  # ── U2: CUSUM 漂移检测 ──

  @doc """
  CUSUM 单步更新（上侧/漂移下降检测）。
  x_t 为标准化偏移观测（如 (实际-期望)/sd）；omega 允许带；h 报警阈值。
  返回 %{s: 累积量, alarm?: bool}。
  """
  def cusum_step(state, x, opts \\ []) do
    omega = Keyword.get(opts, :omega, 0.5)
    h = Keyword.get(opts, :h, 4.0)
    s = max(0.0, state.s + x - omega)
    %{state | s: s, alarm?: s > h, n: state.n + 1}
  end

  @doc "CUSUM 初始状态。"
  def cusum_init, do: %{s: 0.0, alarm?: false, n: 0}

  @doc """
  下侧 CUSUM（检测负向漂移，如频率跌落）：S_{n+1} = max(0, S_n - x_t - omega)。
  x_t 为标准化观测，omega 允许带，h 报警阈值。
  """
  def cusum_down_step(state, x, opts \\ []) do
    omega = Keyword.get(opts, :omega, 0.5)
    h = Keyword.get(opts, :h, 4.0)
    s = max(0.0, state.s - x - omega)
    %{state | s: s, alarm?: s > h, n: state.n + 1}
  end

  @doc "从 Gamma(a,b) 后验计算下一步的标准化偏移观测（供 cusum_step 的 x）。"
  def standardized_offset(gamma_ab, observed_count, expected_scale \\ 1.0) do
    {a, b} = gamma_ab
    expected = a / b * expected_scale
    sd = max(:math.sqrt(a) / b * expected_scale, 1.0e-9)
    (observed_count - expected) / sd
  end
end
