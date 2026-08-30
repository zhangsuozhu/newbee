defmodule Newbee.DEE.Rules do
  @moduledoc """
  沉睡规则 (DESIGN §4.5) ⭐：环境的免疫系统。

  规则平时沉睡、不占 context；kernel 在 run_elixir 代码提交前和模型输出流上调用
  `check/2`——命中即把规则作为 system reminder 注入。"平时零成本、犯病才出现"：
  教训编译成规则而非 prompt 文本。

  规则带 scope（:all | :content | :code）：
    - `:all`（默认）—— 代码、正文、思考流都检查（旧行为）
    - `:content` —— 只检查模型对外正文（outer register；J-Space 纪律用，
      因为思考流是 inner，允许稠密）
    - `:code`   —— 只检查 run_elixir 代码

  内建 **J-Space invariants**（outer 纪律）在启动时自动播种：缺则补，
  用户删过的不会复活。

  持久化：~/.newbee/rules.json。重启后重新载入。
  """

  use GenServer

  defp path, do: Path.join(Newbee.GlobalStore.root(), "rules.json")

  defstruct rules: [], hits: %{}

  # ── 内建 J-Space invariants（§?）：可文本检测的 outer 纪律 ──

  # Generic rules distilled from HA drill (cross-project, notify-worthy)
  @generic_rules [
    %{
      id: "ssh-quote-nesting",
      scope: :code,
      pattern: "ssh.*curl.*python.*f\"",
      injection: "[Rule] ssh 嵌套引号易炸：外层用单引号包 ssh 命令，内层 curl|python 用双引号；f-string 内不要出现反斜杠，改用 format 或拼接。"
    },
    %{
      id: "py-runtime-drift",
      scope: :code,
      pattern: "ModuleNotFoundError|No module named",
      injection: "[Rule] 解释器版本漂移：多版本 Python 共存时用显式版本调用；留意 3.12+ 已移除的标准库，先判运行时版本再决定回退或兼容。"
    },
    %{
      id: "api-type-dual-track",
      scope: :all,
      pattern: "boolean.*string|string.*boolean",
      injection: "[Rule] API 类型双轨：同一字段在不同端点可能是 bool 与 string 双轨；前端用联合类型兼容，后端源头统一为 bool。"
    }
  ]

  @jspace_rules [
    %{
      id: "jspace-outer",
      scope: :content,
      pattern: "(→|⇒|⇔|∃|∀|∈|∉|⊆|⊇|⊢|⊨|⟦|⟧|↦|≡|✓\\d{2}|\\[CP\\s\\d+\\])",
      injection: "[J-Space] 稠密符号泄进了 outer register——内层简写要展开成白话再输出，或移到思考流/ledger。只有可展开的压缩才算容量。"
    },
    %{
      id: "jspace-marker",
      scope: :content,
      pattern: "(GRRR|GAAAH|PHEW|I'M DROWNING|DATA DATA|blocked\\?! WRONG|AAAAAAAA|STOP\\. FOCUS)",
      injection: "[J-Space] marker 是内层状态信号，别在输出里表演。marker 必须成对：跟着 move（具体动作）+ settle（收尾一行），否则是 marker idling。"
    },
    %{
      id: "jspace-hedge",
      scope: :content,
      pattern: "(可能.*也可能|it could be .* or .*|一方面.*另一方面|both .* and .* are possible|或许.*或许)",
      injection: "[J-Space] 列可能性代替解决（hedge）——工作区不存混合物。能命名分离测试就是候选集（保留），否则选一个相信的并标 ?。"
    },
    %{
      id: "jspace-checkpoint",
      scope: :content,
      pattern: "(检查点|checkpoint)",
      injection: "[J-Space] 检查点必须落账：Newbee.Tools.JSpace.note(checkpoint: \"...\") 写编号记录，声明结论+验证覆盖了什么。没记录的检查点不是检查点。"
    },
    %{
      id: "jspace-verified",
      scope: :content,
      pattern: "(verified|已验证)",
      injection: "[J-Space] 声明 verified 时说明验证覆盖了什么（哪个编译/哪组测试），别只贴结论。"
    }
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "注册一条规则（同 id 覆盖）。opts: source（:adapter | :user | :auto | :jspace）、scope（:all | :content | :code）。"
  def add(id, pattern, injection, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:add,
       %{
         id: to_string(id),
         pattern: pattern,
         injection: injection,
         source: Keyword.get(opts, :source, :user),
         scope: Keyword.get(opts, :scope, :all)
       }}
    )
  end

  @doc """
  检查文本是否命中规则。scope 为当前上下文（:all | :content | :code）；
  规则在自身 scope 为 :all 或等于当前 scope 时参与。返回命中列表（按注册序）。
  """
  def check(text, scope \\ :all) when is_binary(text) do
    GenServer.call(__MODULE__, {:check, text, scope})
  end

  @doc "全部规则。"
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "记录一次命中（JIT profiling 输入，§8.5：触发次数 × 节省的返工 token = 价签）。"
  def hit(id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:hit, to_string(id)})
    end

    :ok
  end

  @doc "命中计数（价签：触发次数）。"
  def hits do
    GenServer.call(__MODULE__, :hits)
  end

  @doc "删除规则。"
  def remove(id) do
    GenServer.call(__MODULE__, {:remove, to_string(id)})
  end

  @impl true
  def init(_) do
    rules = load() |> seed_generic() |> seed_jspace()
    {:ok, %__MODULE__{rules: rules}}
  end

  @impl true
  def handle_call({:add, rule}, _from, state) do
    rules = Enum.reject(state.rules, &(&1.id == rule.id)) ++ [rule]
    state = %{state | rules: rules}
    persist(state.rules)
    {:reply, :ok, state}
  end

  def handle_call({:check, text, scope}, _from, state) do
    hits =
      Enum.filter(state.rules, fn rule ->
        if rule.scope == :all or rule.scope == scope do
          case Regex.compile(rule.pattern) do
            {:ok, re} -> Regex.match?(re, text)
            {:error, _} -> false
          end
        else
          false
        end
      end)

    {:reply, hits, state}
  end

  def handle_call(:list, _from, state), do: {:reply, state.rules, state}

  def handle_call(:hits, _from, state), do: {:reply, state.hits, state}

  def handle_call({:remove, id}, _from, state) do
    rules = Enum.reject(state.rules, &(&1.id == id))
    state = %{state | rules: rules}
    persist(state.rules)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:hit, id}, state) do
    {:noreply, %{state | hits: Map.update(state.hits, id, 1, &(&1 + 1))}}
  end

  # 内建 J-Space 规则播种：缺则补（用户删过的不会复活），有改动才落盘
  defp seed_generic(rules) do
    {rules, added?} =
      Enum.reduce(@generic_rules, {rules, false}, fn r, {acc, added?} ->
        if Enum.any?(acc, &(&1.id == r.id)), do: {acc, added?}, else: {acc ++ [%{id: r.id, pattern: r.pattern, injection: r.injection, source: :generic, scope: r.scope}], true}
      end)
    if added?, do: persist(rules)
    rules
  end

  defp seed_jspace(rules) do
    {rules, added?} =
      Enum.reduce(@jspace_rules, {rules, false}, fn r, {acc, added?} ->
        if Enum.any?(acc, &(&1.id == r.id)) do
          {acc, added?}
        else
          {acc ++ [%{id: r.id, pattern: r.pattern, injection: r.injection, source: :jspace, scope: r.scope}], true}
        end
      end)

    if added?, do: persist(rules)
    rules
  end

  defp persist(rules) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode_to_iodata!(rules))
    :ok
  end

  defp load do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, rules} when is_list(rules) ->
            Enum.map(rules, fn r ->
              %{
                id: r["id"],
                pattern: r["pattern"],
                injection: r["injection"],
                source: (r["source"] || "user") |> String.to_atom(),
                scope: (r["scope"] || "all") |> String.to_atom()
              }
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
