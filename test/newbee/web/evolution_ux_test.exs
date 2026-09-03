defmodule Newbee.Web.EvolutionUxTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  defp post_rpc(method, payload) do
    body = Jason.encode!(%{"rpcId" => "test", "method" => method, "payload" => payload})

    Plug.Test.conn(:post, "/api/" <> method, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Newbee.Web.Router.call(@opts)
    |> then(fn conn -> Jason.decode!(conn.resp_body) end)
  end

  defp ok!(%{"result" => %{"ok" => value}}), do: value

  test "evolution.status 含人话解释 autonomy_explain（H2），不断旧字段" do
    res = post_rpc("evolution.status", %{}) |> ok!()
    assert is_binary(res["autonomy_label"])
    assert is_binary(res["autonomy_explain"])
    # 人话必须包含动作指引：批准 / 回退 / 建议 之一
    assert res["autonomy_explain"] =~ "批准" or res["autonomy_explain"] =~ "回退" or
             res["autonomy_explain"] =~ "建议"
    assert Map.has_key?(res, "changes")
    assert Map.has_key?(res, "engine")
  end

  test "evolution.feed 可读，不崩" do
    res = post_rpc("evolution.feed", %{"n" => 5}) |> ok!()
    assert is_list(res["events"])
  end

  test "前端不再抢焦点：setBusy 不强制 switchMCTab，有徽标与 sticky tab" do
    js = File.read!(Path.join([File.cwd!(), "priv", "web", "app.js"]))
    # 旧抢焦点代码必须消失
    refute js =~ ~s|if (MC.open) switchMCTab("steps")|
    refute js =~ ~s|switchMCTab("files")|
    # 新机制必须存在
    assert js =~ "updateMCBadges"
    assert js =~ "bumpMCBadge"
    assert js =~ "newbee-mc-tab"
    assert js =~ "MC.evoUnread"
  end

  test "进化面板有人话骨架：intro/guide/decide/progress/history" do
    html = File.read!(Path.join([File.cwd!(), "priv", "web", "index.html"]))
    assert html =~ "evo-intro"
    assert html =~ "怎么判断要不要批准"
    assert html =~ "evo-guide"
    assert html =~ "evo-decide-list"
    assert html =~ "evo-progress-list"
    assert html =~ "mc-badge-steps"
    assert html =~ "mc-badge-evolution"
    assert html =~ "当前生效版本"
    refute html =~ "ACTIVE ENVIRONMENT"
    js = File.read!(Path.join([File.cwd!(), "priv", "web", "app.js"]))
    assert js =~ "换一种说法"
    assert js =~ "验证细节"
    assert js =~ "evo-story"
    assert js =~ "explainBrief"
    assert js =~ "evolution.explain"
    assert js =~ "批准，用上这个改进"
    assert js =~ "再想想"
    assert js =~ "evoRingExplain"
  end
end
