defmodule Newbee.Environment.Manifest do
  @moduledoc """
  Manifest (DESIGN §3.1)：active revision 指针 + revision 历史 + known-good 链。

  持久化在 `.newbee/environment.json`——**派生快照**，真相在事件流；
  记录 `checkpoint`（已应用的事件水位），崩溃后从 checkpoint 重放重建。
  历史 revision 永不删除；回退 = 移动 active 指针。
  """

  alias Newbee.Environment.Revision

  defstruct revision: 0,
            active: %{},
            revisions: [],
            checkpoint: 0,
            degraded: []

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{active: Newbee.Plugins.builtin_active_map()}

  @doc "当前 active revision 号。"
  def current_rev(%__MODULE__{revision: r}), do: r

  @doc "当前 active release 图：%{plugin_id => release_id}。"
  def active(%__MODULE__{active: a}), do: a

  @doc """
  推进 active：产生新 revision（单调递增）。
  `delta` = %{plugin_id => release_id | nil}（nil 表示移除该插件）。
  """
  def advance(%__MODULE__{} = m, delta, change_id) when is_map(delta) do
    new_active =
      Enum.reduce(delta, m.active, fn
        {plugin_id, nil}, acc -> Map.delete(acc, plugin_id)
        {plugin_id, release_id}, acc -> Map.put(acc, plugin_id, release_id)
      end)

    rev = Revision.new(m.revision + 1, new_active, change_id)

    %{m | revision: rev.rev, active: new_active, revisions: m.revisions ++ [rev]}
  end

  @doc "按 rev 号取历史 revision。"
  def revision(%__MODULE__{revisions: revs}, n) when is_integer(n) do
    Enum.find(revs, &(&1.rev == n))
  end

  @doc "最近 known-good revision（health == :healthy 的最大 rev；无则 0 = 内置基线环境）。"
  def last_known_good(%__MODULE__{revisions: revs}) do
    revs
    |> Enum.filter(&(&1.health == :healthy))
    |> Enum.map(& &1.rev)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  回退 = 移动 active 指针到历史 revision（§8.4）。自身也产生新 revision
  （审计链完整：指针移动也是历史）。
  """
  def rollback(%__MODULE__{} = m, target_rev, change_id) when is_integer(target_rev) do
    target =
      if target_rev == 0 do
        # rev0 = 内置基线环境（与 Store.fresh_environment/0 播种一致）：
        # 回退到 rev0 回到内置图，而非空图。
        Revision.new(0, Newbee.Plugins.builtin_active_map())
      else
        revision(m, target_rev)
      end

    case target do
      nil ->
        {:error, :revision_not_found}

      %Revision{} ->
        rev = Revision.new(m.revision + 1, target.active, change_id)
        {:ok, %{m | revision: rev.rev, active: target.active, revisions: m.revisions ++ [rev]}}
    end
  end

  @doc "标记某 revision 健康状态（known-good 链维护）。"
  def mark_health(%__MODULE__{revisions: revs} = m, n, health) do
    degraded =
      if health == :degraded,
        do: Enum.uniq(m.degraded ++ [n]),
        else: List.delete(m.degraded, n)

    %{
      m
      | revisions: Enum.map(revs, fn r -> if r.rev == n, do: Revision.mark_health(r, health), else: r end),
        degraded: degraded
    }
  end

  # ── 序列化 ──

  def to_map(%__MODULE__{} = m) do
    %{
      "revision" => m.revision,
      "active" => m.active,
      "revisions" => Enum.map(m.revisions, &Revision.to_map/1),
      "checkpoint" => m.checkpoint,
      "degraded" => m.degraded
    }
  end

  def from_map(map) when is_map(map) do
    active = map["active"]
    # 兼容旧快照：rev0 空图（首启前/旧文件）自动合入内置基线（P0 活锁修复），
    # rev>0 的显式空快照原样保留（避免漂移）。
    builtin = Newbee.Plugins.builtin_active_map()

    merged =
      cond do
        is_map(active) and map_size(active) == 0 and (map["revision"] || 0) == 0 -> Map.merge(builtin, active)
        is_map(active) -> if map_size(active) == 0, do: builtin, else: active
        true -> builtin
      end

    %__MODULE__{
      revision: map["revision"] || 0,
      active: merged,
      revisions: Enum.map(map["revisions"] || [], &Revision.from_map/1),
      checkpoint: map["checkpoint"] || 0,
      degraded: map["degraded"] || []
    }
  end
end
