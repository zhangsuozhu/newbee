defmodule Newbee.Colony.Honey do
  @moduledoc """
  Honey（成果）：一切被工具加工过的产物（信息/文档/源码/命令结果）。

  验收流（附录 A）：
  - 产出后进入 pending_review；
  - 机器可校验的验收标准先跑 auto_check：全部通过 → auto_verified，否则退回 pending（附失败项）；
  - Queen（人）只对 auto_verified / pending_review 做价值判断：accept / reject。
  """

  @states ~w(pending_review auto_verified accepted rejected)

  def states, do: @states

  @doc "新建成果。attrs: colony_id, bee_id, task_id?, kind, title, content?/content_ref?, note?, checks?"
  def new(attrs) when is_map(attrs) do
    now = Map.get(attrs, "created_at") || now_ms()

    %{
      "id" => Map.get(attrs, "id") || Newbee.Colony.Id.new(:honey, scope_for(attrs)),
      "colony_id" => Map.get(attrs, "colony_id"),
      "task_id" => blank_to_nil(Map.get(attrs, "task_id")),
      "bee_id" => blank_to_nil(Map.get(attrs, "bee_id")),
      "kind" => blank_to_nil(Map.get(attrs, "kind")) || "artifact",
      "title" => blank_to_nil(Map.get(attrs, "title")) || "未命名成果",
      "content_ref" => blank_to_nil(Map.get(attrs, "content_ref")),
      "content" => Map.get(attrs, "content") || "",
      "note" => Map.get(attrs, "note") || "",
      "review" => %{
        "state" => "pending_review",
        "auto_checks" => normalize_checks(Map.get(attrs, "checks")),
        "verdict" => nil
      },
      "created_at" => now
    }
  end

  @doc "执行自动预检：全部通过则 auto_verified；有失败项则回到 pending_review 并记录失败项。"
  def auto_verify(honey, checks) do
    checks = normalize_checks(checks)
    ok? = checks != [] and Enum.all?(checks, &Map.get(&1, "ok"))

    review =
      honey
      |> get_in(["review"])
      |> Map.put("auto_checks", checks)
      |> Map.put("state", if(ok?, do: "auto_verified", else: "pending_review"))

    Map.put(honey, "review", review)
  end

  @doc "Queen 验收。verdict: accept | reject；note 为理由。"
  def review(honey, verdict, by_bee_id, note \\ "") do
    state = get_in(honey, ["review", "state"])
    new_state = if verdict == "accept", do: "accepted", else: "rejected"

    cond do
      state in ["accepted", "rejected"] ->
        {:error, :already_reviewed}

      verdict not in ["accept", "reject"] ->
        {:error, :invalid_verdict}

      true ->
        review =
          honey
          |> get_in(["review"])
          |> Map.put("state", new_state)
          |> Map.put("verdict", %{
            "by" => by_bee_id,
            "verdict" => verdict,
            "note" => note,
            "at" => now_ms()
          })

        {:ok, Map.put(honey, "review", review)}
    end
  end

  def accepted?(honey), do: get_in(honey, ["review", "state"]) == "accepted"

  def public(honey) do
    honey
    |> Map.put("review_state", get_in(honey, ["review", "state"]))
    |> Map.put("preview", preview(honey))
  end

  defp preview(honey) do
    content =
      case Map.get(honey, "content") do
        c when is_binary(c) -> c
        other -> inspect(other)
      end

    String.slice(content || "", 0, 240)
  end

  defp normalize_checks(nil), do: []

  defp normalize_checks(list) when is_list(list) do
    Enum.map(list, fn
      %{"check" => _} = c -> Map.put_new(c, "ok", false)
      %{"name" => name, "ok" => ok} -> %{"check" => name, "ok" => ok}
      other -> %{"check" => inspect(other), "ok" => false}
    end)
  end

  defp normalize_checks(_), do: []

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v

  defp scope_for(%{"scope" => "xhost"}), do: :xhost
  defp scope_for(_), do: :local

  defp now_ms, do: System.system_time(:millisecond)
end
