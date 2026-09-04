defmodule Newbee.Tools.JSpace do
  @moduledoc """
  长任务台账：goal/core/verified/next 持久化，跨压缩恢复。
  复杂多步任务使用；简单任务不要创建 ledger。

  ## 函数清单
  - `note(fields, session \\\\ nil) :: String.t()` — 更新台账；`fields` 是含 `goal/core/next/verified/open/checkpoint` 的关键字列表。
  - `read(session \\\\ nil) :: String.t() | nil` — 读取 ledger 原文；不存在返回 `nil`。
  - `seam(session \\\\ nil) :: String.t()` — 子任务边界重读 ledger；不存在返回开账提示。
  - `ship(path, checks \\\\ [], session \\\\ nil) :: String.t()` — 登记交付路径和检查项。
  - `resume(session \\\\ nil) :: String.t()` — 返回恢复协议与 ledger 原文。
  - `clear(session \\\\ nil) :: :ok` — 删除指定 ledger。
  - `exists?(session \\\\ nil) :: boolean()` — ledger 是否存在。

  ## 可跑示例
      ledger = Newbee.Tools.JSpace.note([goal: "统一工具说明", next: "核对真实签名"])
      body = Newbee.Tools.JSpace.read()
      body = Newbee.Tools.JSpace.seam()
      confirmation = Newbee.Tools.JSpace.ship("docs/tool-contracts.md", ["编译", "测试"])
      recovery = Newbee.Tools.JSpace.resume()
      true = Newbee.Tools.JSpace.exists?()
      :ok = Newbee.Tools.JSpace.clear()
  """

  defp root do
    System.get_env("NEWBEE_JSPACE_DIR") || Path.join(System.user_home!(), ".newbee/jspace")
  end

  defp ledger_path(session) do
    id = session || current_session() || "default"
    Path.join(root(), "#{id}.md")
  end

  # 与 history:// 同理：peer 求值上下文优先用 capability 解析，避免全局 current 串会话。
  defp current_session do
    case collaboration_session_id() do
      {:ok, sid} -> sid
      :error -> Newbee.Host.call(Newbee.Session, :current_id, [])
    end
  end

  defp collaboration_session_id do
    case Process.get({Newbee.Tools.Collaboration, :context}) do
      %{capability: token} when is_binary(token) ->
        case Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [token]) do
          {:ok, %{session_id: sid}} when is_binary(sid) -> {:ok, sid}
          _ -> :error
        end

      _ ->
        case Process.get({Newbee.Tools.Media, :capability}) do
          token when is_binary(token) ->
            case Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [token]) do
              {:ok, %{session_id: sid}} when is_binary(sid) -> {:ok, sid}
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  @doc "ledger 是否存在；session 省略时使用当前会话。"
  def exists?(session \\ nil), do: File.regular?(ledger_path(session))

  @doc "读取 ledger 原文；不存在返回 nil。session 省略时使用当前会话。"
  def read(session \\ nil) do
    case File.read(ledger_path(session)) do
      {:ok, body} -> body
      _ -> nil
    end
  end

  @doc """
  更新台账。fields 为关键字列表：
    goal: "..."      → 替换 Goal 行
    core: "..."      → 替换 Core 行
    next: "..."      → 替换 Next 行（不许空）
    verified: "..."  → 追加编号 ✓NN（append-only，回滚有地址）
    open: "..."      → 追加 ? 悬项（附"什么能定案"）
    checkpoint: "..." → 追加 [CP NN] 检查点
  返回新台账全文。
  """
  def note(fields, session \\ nil) when is_list(fields) do
    body = read(session) || initial_ledger()
    counters = %{verified: count_marked(body, ~r/^✓(\d+)/m), cp: count_marked(body, ~r/^\[CP (\d+)\]/m)}
    lines = apply_fields(String.split(body, "\n"), fields, counters)
    text = Enum.join(lines, "\n") <> "\n"
    File.mkdir_p!(root())
    File.write!(ledger_path(session), text)
    text
  end

  @doc "seam 重读：返回 ledger 全文（模型在每个 seam 调用并据此续写）。"
  def seam(session \\ nil) do
    case read(session) do
      nil -> "（无 ledger——loop 档任务先开账: note(goal: \"...\", next: \"...\")）"
      body -> body
    end
  end

  @doc "登记交付路径与检查项；返回确认文本。参数顺序是 path, checks, session。"
  def ship(path, checks \\ [], session \\ nil) when is_list(checks) do
    body = read(session) || initial_ledger()
    list = Enum.map_join(checks, "\n", &"    - [ ] #{&1}")
    line = "- [ ] SHIP #{path}" <> if checks == [], do: "", else: "\n" <> list
    text = body <> "\n## 交付检查\n" <> line <> "\n"
    File.mkdir_p!(root())
    File.write!(ledger_path(session), text)
    "已登记交付检查: #{path}"
  end

  @doc "长间隔（压缩/会话边界）后恢复：前提 + invariants + 全 ledger。"
  def resume(session \\ nil) do
    "## J-Space 恢复协议\n" <>
      "前提：你有内层工作区——稠密思考、可按需展开；自动化（语法/格式/惯例）不占它。\n" <>
      "Invariants：①marker 无动作 ②监控从不报告 ③稠密行不可展开 ④confidence 全同 " <>
      "⑤检查点未落账 ⑥verified 未声明覆盖 ⑦稠密符号泄进输出 ⑧未逐行读 goal 就宣告完成。\n\n" <>
      "## Ledger\n" <>
      (read(session) || "（无 ledger——开账: note(goal: \"...\", next: \"...\")）")
  end

  @doc "清空 ledger（任务结束/换任务）。"
  def clear(session \\ nil) do
    File.rm(ledger_path(session))
    :ok
  end

  # ── 内部 ──

  defp initial_ledger do
    "Goal:      (未设定)\nCore:      (未设定)\nVerified:  (无)\nOpen:      (无)\nNext:      (未设定)\n"
  end

  defp count_marked(body, regex), do: length(Regex.scan(regex, body))

  defp apply_fields(lines, [], _counters), do: lines

  defp apply_fields(lines, [{k, v} | rest], counters) when is_binary(v) do
    {new_lines, counters} =
      case k do
        :goal -> {replace_line(lines, "Goal:", "Goal:      " <> v), counters}
        :core -> {replace_line(lines, "Core:", "Core:      " <> v), counters}
        :next -> {replace_line(lines, "Next:", "Next:      " <> v), counters}
        :verified -> append_numbered(lines, v, counters, :verified, "✓", "Verified:")
        :open -> {lines ++ ["? " <> v], counters}
        :checkpoint -> append_numbered(lines, v, counters, :cp, "[CP ", nil)
      end

    apply_fields(new_lines, rest, counters)
  end

  defp replace_line(lines, prefix, new_line) do
    case Enum.find_index(lines, &String.starts_with?(&1, prefix)) do
      nil -> lines ++ [new_line]
      idx -> List.replace_at(lines, idx, new_line)
    end
  end

  # header 非 nil 时先把占位行（如 "Verified:  (无)"）清成裸 header
  defp append_numbered(lines, v, counters, key, tag, header) do
    lines = if header, do: replace_line(lines, header, header), else: lines
    n = Map.fetch!(counters, key) + 1
    num = String.pad_leading(Integer.to_string(n), 2, "0")
    line = tag <> num <> if(tag == "✓", do: " ", else: "] ") <> v
    {lines ++ [line], Map.put(counters, key, n)}
  end
end
