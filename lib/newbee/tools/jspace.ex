defmodule Newbee.Tools.JSpace do
  @moduledoc """
  Persistent task ledger: goal/core/verified/next survive compaction.
  Use for loop-level tasks; skip for simple one-shots.

  ## Functions
  - `note(fields, session \\\\ nil) :: String.t()` — update the ledger; `fields` takes `goal/core/next/verified/open/checkpoint`.
  - `read(session \\\\ nil) :: String.t() | nil` — raw ledger text; `nil` when absent.
  - `seam(session \\\\ nil) :: String.t()` — re-read the ledger at subtask seams; open-ledger hint when absent.
  - `ship(path, checks \\\\ [], session \\\\ nil) :: String.t()` — register a delivery path with checks.
  - `resume(session \\\\ nil) :: String.t()` — recovery protocol plus full ledger.
  - `clear(session \\\\ nil) :: :ok` — delete the ledger.
  - `exists?(session \\\\ nil) :: boolean()` — whether a ledger exists.

  ## Runnable example
      ledger = Newbee.Tools.JSpace.note([goal: "Unify tool docs", next: "Check real signatures"])
      body = Newbee.Tools.JSpace.read()
      body = Newbee.Tools.JSpace.seam()
      confirmation = Newbee.Tools.JSpace.ship("docs/tool-contracts.md", ["compile", "test"])
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

  @doc "Whether a ledger exists; defaults to the current session."
  def exists?(session \\ nil), do: File.regular?(ledger_path(session))

  @doc "Raw ledger text; nil when absent. Defaults to the current session."
  def read(session \\ nil) do
    case File.read(ledger_path(session)) do
      {:ok, body} -> body
      _ -> nil
    end
  end

  @doc """
  Update the ledger. `fields` is a keyword list:
    goal: "..."       → replace the Goal line
    core: "..."       → replace the Core line
    next: "..."       → replace the Next line (never leave empty)
    verified: "..."   → append numbered ✓NN (append-only; gives rollback an address)
    open: "..."       → append a ? item (state what would settle it)
    checkpoint: "..." → append a [CP NN] checkpoint
  Returns the new ledger text.
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

  @doc "Seam re-read: full ledger text (call at every seam, then continue from it)."
  def seam(session \\ nil) do
    case read(session) do
      nil -> "(no ledger — open one for loop-level tasks: note(goal: \"...\", next: \"...\"))"
      body -> body
    end
  end

  @doc "Register a delivery path with checks; returns confirmation. Args: path, checks, session."
  def ship(path, checks \\ [], session \\ nil) when is_list(checks) do
    body = read(session) || initial_ledger()
    list = Enum.map_join(checks, "\n", &"    - [ ] #{&1}")
    line = "- [ ] SHIP #{path}" <> if checks == [], do: "", else: "\n" <> list
    text = body <> "\n## Delivery checks\n" <> line <> "\n"
    File.mkdir_p!(root())
    File.write!(ledger_path(session), text)
    "Delivery checks recorded: #{path}"
  end

  @doc "Recover after a long gap (compaction/session boundary): premises + invariants + full ledger."
  def resume(session \\ nil) do
    "## J-Space recovery protocol\n" <>
      "Premise: think in the inner workspace first; dense notes must stay expandable on demand; keep automation (syntax/format/convention) out of it.\n" <>
      "Invariants (looks-busy-but-hollow — never these): marker without action; monitor that never reports; dense line you cannot expand; uniform confidence; " <>
      "unrecorded checkpoint; verified claim without coverage; dense symbols leaking into output; done without re-reading the goal line by line.\n\n" <>
      "## Ledger\n" <>
      (read(session) || "(no ledger — open one: note(goal: \"...\", next: \"...\"))")
  end

  @doc "Clear the ledger (task done or task switch)."
  def clear(session \\ nil) do
    File.rm(ledger_path(session))
    :ok
  end

  # ── 内部 ──

  defp initial_ledger do
    "Goal:      (unset)\nCore:      (unset)\nVerified:  (none)\nOpen:      (none)\nNext:      (unset)\n"
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

  # When header is non-nil, first collapse the placeholder line (e.g. "Verified:  (none)") to a bare header
  defp append_numbered(lines, v, counters, key, tag, header) do
    lines = if header, do: replace_line(lines, header, header), else: lines
    n = Map.fetch!(counters, key) + 1
    num = String.pad_leading(Integer.to_string(n), 2, "0")
    line = tag <> num <> if(tag == "✓", do: " ", else: "] ") <> v
    {lines ++ [line], Map.put(counters, key, n)}
  end
end
