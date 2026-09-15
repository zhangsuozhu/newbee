defmodule Newbee.Environment.ApprovalAuditTest do
  use ExUnit.Case, async: true

  alias Newbee.Environment.{ApprovalAudit, Change}

  test "automatic approval record explains the change and rollback" do
    change = %Change{
      change_id: "chg_test",
      base_revision: 2,
      human_brief: %{
        "title" => "减少重复登录失败",
        "change_to" => "先检查凭证，再重试一次",
        "why" => "最近三次任务都遇到同一种失败",
        "risk_undo" => "只影响登录提示，旧版本可恢复"
      },
      evaluation_result: %{"passed" => true, "failed_layers" => []}
    }

    record = ApprovalAudit.auto_record(change, :autonomous, 3, at: "2026-01-01T00:00:00Z")
    assert record["decision_label"] == "系统自动通过"
    assert record["improvement"] == "先检查凭证，再重试一次"
    assert record["reason"] == "最近三次任务都遇到同一种失败"
    assert record["rollback_to_revision"] == 2
    assert record["reversible"] == true
    assert record["certainty"] == "固定规则全部通过"
  end

  test "equivalent pending changes become one human approval card" do
    brief = %{
      "title" => "统一检查凭证",
      "change_to" => "调用工具前先检查凭证",
      "why" => "同一类失败反复出现",
      "risk_undo" => "只影响工具调用，旧版本可恢复"
    }

    changes =
      for id <- ["chg_a", "chg_b"] do
        %Change{
          change_id: id,
          approval_group: "approval_credentials",
          status: :canary,
          evaluation_result: %{"passed" => true},
          human_brief: brief
        }
      end

    assert [%{"count" => 2, "change_ids" => ["chg_a", "chg_b"], "requires_human" => true}] =
             ApprovalAudit.pending_groups(changes)
  end
end
