defmodule Newbee.Environment.HumanBriefTest do
  use ExUnit.Case, async: true

  alias Newbee.Environment.HumanBrief

  test "template: distill 风格裸ID输入不复读，六段齐全" do
    brief =
      HumanBrief.template_brief(%{
        reason: "adapter: distill-stream-chat-hotpath",
        evidence: [%{proposal: "distill-stream-chat-hotpath", type: "tool"}],
        kind: :tool,
        ring: 2
      })

    for k <- ~w(title found change_to why risk_undo ask) do
      assert is_binary(brief[k]), k
      assert String.length(brief[k]) >= 2, k
    end

    refute brief["title"] =~ "distill"
    refute brief["found"] =~ "chg_"
    assert brief["fallback"] == true
    assert brief["model"] == "template"
  end

  test "template: 空证据也不崩，标题说人话" do
    brief = HumanBrief.template_brief(%{kind: :rule, ring: 3})
    assert brief["title"] =~ "提醒"
    assert brief["risk_undo"] =~ "影响小"
  end

  test "generate: stub LLM 成功则采用并标记非回退" do
    json =
      Jason.encode!(%{
        title: "记住登录失败的退避策略",
        found: "AI 发现登录重试多次失败",
        change_to: "改成指数退避等待",
        why: "能减少雪崩重试",
        risk_undo: "影响小，可以回退",
        ask: "认可的话请批准"
      })

    brief = HumanBrief.generate(%{kind: :rule}, client_fun: fn _ -> {:ok, json} end, model: "test")
    assert brief["fallback"] == false
    assert brief["title"] == "记住登录失败的退避策略"
    assert brief["model"] == "test"
  end

  test "generate: LLM 失败回退模板且不抛异常" do
    brief = HumanBrief.generate(%{kind: :prompt}, client_fun: fn _ -> {:error, :no_key} end)
    assert brief["fallback"] == true
    assert brief["title"] =~ "经验"
  end

  test "generate: 无中文的胡言乱语被拒收，回退模板" do
    json = Jason.encode!(%{title: "foo", found: "bar", change_to: "baz", why: "qux", risk_undo: "quux", ask: "corge"})
    brief = HumanBrief.generate(%{kind: :tool}, client_fun: fn _ -> {:ok, json} end)
    assert brief["fallback"] == true
  end

  test "generate: 含 chg_ 的伪造被拒收" do
    json =
      Jason.encode!(%{
        title: "批准 chg_1234567890abcdef",
        found: "AI 发现了问题",
        change_to: "改成新的样子",
        why: "因为这样有效果",
        risk_undo: "影响很小可以回退",
        ask: "请批准这个改进"
      })

    brief = HumanBrief.generate(%{kind: :rule}, client_fun: fn _ -> {:ok, json} end)
    assert brief["fallback"] == true
  end
end
