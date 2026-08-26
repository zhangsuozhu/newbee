defmodule Newbee.Tools.JSpace do
  @moduledoc """
  J-Space 工作区台账工具：把模型的内层工作区外部化为持久 ledger
  （goal/core/verified/open/next），跨会话与压缩存活（DESIGN §5.3/§6.5）。

  - `note` 更新台账：goal/core/next 替换，verified/open/checkpoint 编号追加
  - `seam` 每个 seam（子任务）收敛后记一笔
  - `ship` 把 verified 的成果固化为文件/事件

  ## 函数清单
  - `note(opts)` / `note(session_id, opts)` — 更新台账。`opts` 含 `goal:`, `core:`, `next:`, `verified:`, `open:`, `checkpoint:`。
  - `read()` / `read(session_id)` — 读当前 ledger（map）。
  - `resume()` / `resume(session_id)` — 恢复上一会话的 ledger 到当前。
  - `seam()` / `seam(session_id)` — 标记 seam 边界。
  - `ship(content)` / `ship(session_id, content)` — 固化成果。
  - `clear()` / `clear(session_id)` — 清空。
  - `exists?()` / `exists?(session_id)` — 是否存在。
  - `ledger_path()` / `ledger_path(session_id)` — 路径。

  ## 可跑示例
      Newbee.Tools.JSpace.note(goal: "修复 trailing 哈希不一致", core: "Edit clean_hash")
      Newbee.Tools.JSpace.note(checkpoint: "CP1: Edit trail/CRLF 已修复")

  """

  @doc "ledger 根目录（可用 NEWBEE_JSPACE_DIR 覆盖，默认 ~/.newbee/jspace）。"
  def root do
    System.get_env("NEWBEE_JSPACE_DIR") || Path.join(System.user_home!(), ".newbee/jspace")
  end

  @doc "ledger 文件路径（按会话；无会话回退 default）。"
  def ledger_path(session \\ nil) do
    id = session || current_session() || "default"
    Path.join(root(), "#{id}.md")
  end

  @doc "当前活动会话 id（经 Host 回主 VM 查询 kernel 登记的会话；无会话返回 nil）。"
  def current_session do
    Newbee.Host.call(Newbee.Session, :current_id, [])
  end

  @doc "ledger 是否存在。"
  def exists?(session \\ nil), do: File.regular?(ledger_path(session))

  @doc "读取 ledger 全文；不存在返回 nil。"
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

  @doc "登记即将交付的检查项（交付前逐项核验）。返回确认文本。"
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
