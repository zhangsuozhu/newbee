defmodule Newbee.Environment.ApprovalAudit do
  @moduledoc "Human-readable audit records for automatic and human self-evolution approvals."

  alias Newbee.Environment.Change

  def auto_record(%Change{} = change, via, revision, opts \\ []) do
    brief = change.human_brief || %{}
    evaluation = change.evaluation_result || %{}
    scope = first(brief, ["risk_undo", "impact_scope"], "影响范围未记录")
    improvement = first(brief, ["change_to", "improvement"], "把已验证的改进加入环境")
    why = first(brief, ["why"], "固定验证门全部通过，且当前自治规则允许自动生效。")

    %{
      "approval_id" => "auto_" <> change.change_id,
      "decision" => "automatic",
      "decision_label" => "系统自动通过",
      "change_id" => change.change_id,
      "change_ids" => [change.change_id],
      "group_id" => change.approval_group || group_key(change),
      "summary" => first(brief, ["title"], "自动应用一项已验证的改进"),
      "improvement" => improvement,
      "reason" => why,
      "impact_scope" => scope,
      "evidence" => %{
        "evaluation_passed" => evaluation["passed"] || evaluation[:passed] || false,
        "failed_layers" => evaluation["failed_layers"] || evaluation[:failed_layers] || [],
        "via" => to_string(via)
      },
      "certainty" => "固定规则全部通过",
      "reversible" => true,
      "rollback_to_revision" => change.base_revision,
      "activated_revision" => revision,
      "actor" => "system",
      "at" => Keyword.get(opts, :at, DateTime.utc_now() |> DateTime.to_iso8601())
    }
  end

  def group_key(%Change{} = change) do
    change.approval_group ||
      case change.evaluation_result || %{} do
        %{"plugin_id" => plugin} when is_binary(plugin) and plugin != "" ->
          "approval_" <> digest(plugin)

        %{plugin_id: plugin} when is_binary(plugin) and plugin != "" ->
          "approval_" <> digest(plugin)

        _ ->
          "approval_" <>
            digest(normalize(first(change.human_brief || %{}, ["change_to", "title"], change.reason || "改进")))
      end
  end

  def pending_groups(changes) when is_list(changes) do
    changes
    |> Enum.filter(&pending?/1)
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {group_id, members} ->
      briefs = Enum.map(members, &human_summary/1)
      first_brief = hd(briefs)

      %{
        "group_id" => group_id,
        "title" => if(length(members) == 1, do: first_brief["title"], else: "合并审批：" <> first_brief["title"]),
        "change_ids" => Enum.map(members, & &1.change_id),
        "count" => length(members),
        "improvements" => briefs |> Enum.map(& &1["improvement"]) |> Enum.uniq(),
        "reason" => briefs |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.join("；"),
        "impact_scope" => briefs |> Enum.map(& &1["impact_scope"]) |> Enum.uniq() |> Enum.join("；"),
        "reversible" => true,
        "requires_human" => true
      }
    end)
    |> Enum.sort_by(& &1["title"])
  end

  def pending_groups(_), do: []

  def human_summary(%Change{} = change) do
    brief = change.human_brief || %{}

    %{
      "change_id" => change.change_id,
      "title" => first(brief, ["title"], "环境改进"),
      "improvement" => first(brief, ["change_to", "improvement"], "暂无改进说明"),
      "reason" => first(brief, ["why", "found"], "暂无原因说明"),
      "impact_scope" => first(brief, ["risk_undo", "impact_scope"], "影响范围未记录"),
      "rollback_to_revision" => change.base_revision,
      "status" => to_string(change.status)
    }
  end

  defp pending?(%Change{status: status, evaluation_result: result}),
    do: status in [:canary, :evaluating] and is_map(result)

  defp pending?(_), do: false

  defp first(map, keys, default) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) ->
          if String.trim(value) != "", do: value
      end
    end)
  end

  defp normalize(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9\p{Han}]+/u, " ") |> String.trim()

  defp normalize(_), do: "change"
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end
