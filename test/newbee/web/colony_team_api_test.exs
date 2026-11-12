defmodule Newbee.Web.ColonyTeamApiTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, Engine, Team, TeamTemplate, Work}
  @opts Newbee.Web.Router.init([])

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "团队 RPC"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  defp rpc(method, payload, token \\ nil) do
    conn =
      Plug.Test.conn(:post, "/api/" <> method, Jason.encode!(%{rpcId: "t-1", payload: payload}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn = Newbee.Web.Router.call(conn, @opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["result"]
  end

  test "模板种子→列表→开项目→阶段验收全链路（RPC）", %{cid: cid} do
    assert %{"ok" => %{"template" => template}} = rpc("colony.team.template.seed", %{})
    assert template["name"] == "产研团队"
    assert %{"ok" => %{"templates" => [^template]}} = rpc("colony.team.templates", %{})

    assert %{"ok" => %{"run" => run}} =
             rpc("colony.team.run.start", %{
               "templateId" => template["id"],
               "goal" => "记账小程序",
               "name" => "记账项目"
             })

    assert %{"ok" => %{"runs" => [listed]}} = rpc("colony.team.runs", %{"colonyId" => run["colony_id"]})
    assert listed["id"] == run["id"]

    assert %{"ok" => view} = rpc("colony.team.run.view", %{"colonyId" => run["colony_id"], "runId" => run["id"]})
    assert Enum.at(view["stages"], 0)["state"] == "current"
    task_id = view["current_task"]["id"]

    # 模拟阶段成果提交（执行器路径），然后 RPC 验收
    {:ok, task} = Store.get_task(task_id)

    {:ok, honey} =
      Work.submit(
        task["colony_id"],
        task["id"],
        %{"content" => "PRD v1", "work_revision" => task["context_revision"]},
        task["assigned_bee_id"]
      )

    assert %{"ok" => %{"run" => advanced}} =
             rpc("colony.team.run.review", %{
               "colonyId" => run["colony_id"],
               "runId" => run["id"],
               "honeyId" => honey["id"],
               "verdict" => "accept",
               "note" => "通过"
             })

    assert advanced["stage_index"] == 1
  end

  test "提案→草案→批准（RPC）", %{cid: cid} do
    assert %{"ok" => %{"proposal" => proposal}} =
             rpc("colony.team.proposal.start", %{"colonyId" => cid, "goal" => "组建产研团队"})

    {:ok, task} = Store.get_task(proposal["task_id"])
    {:ok, _} = Team.plan_complete(task, Jason.encode!(TeamTemplate.product_team()))

    assert %{"ok" => %{"proposals" => [listed]}} = rpc("colony.team.proposals", %{"colonyId" => cid})
    assert listed["status"] == "draft_ready"

    assert %{"ok" => %{"template" => template, "proposal" => approved}} =
             rpc("colony.team.proposal.decide", %{
               "colonyId" => cid,
               "proposalId" => proposal["id"],
               "decision" => "approve"
             })

    assert approved["status"] == "approved"
    assert template["source"] == "proposal"
  end

  test "跨蜂群访问提案/项目被拒绝", %{cid: cid} do
    {:ok, other} = Engine.create_colony(%{"name" => "别的群"})
    {:ok, proposal} = Team.start_proposal(%{"goal" => "目标", "colony_id" => cid}, nil)

    assert %{"error" => %{"code" => "forbidden"}} =
             rpc("colony.team.proposal.decide", %{
               "colonyId" => other["id"],
               "proposalId" => proposal["id"],
               "decision" => "reject"
             })
  end

  test "成员凭据不能审批提案或验收阶段（owner-only）", %{cid: cid} do
    {:ok, invite} = Newbee.Colony.Membership.invite(cid, colony_admin(cid), %{"kind" => "human"})
    {:ok, %{"token" => token}} = Newbee.Colony.Membership.redeem(invite["code"], "同事甲")
    {:ok, proposal} = Team.start_proposal(%{"goal" => "目标", "colony_id" => cid}, nil)
    {:ok, task} = Store.get_task(proposal["task_id"])
    {:ok, _} = Team.plan_complete(task, Jason.encode!(TeamTemplate.product_team()))

    assert %{"error" => %{"code" => "forbidden"}} =
             rpc(
               "colony.team.proposal.decide",
               %{"colonyId" => cid, "proposalId" => proposal["id"], "decision" => "approve"},
               token
             )

    # 只读列表对成员开放
    assert %{"ok" => %{"proposals" => _}} = rpc("colony.team.proposals", %{"colonyId" => cid}, token)
  end

  defp colony_admin(cid) do
    {:ok, colony} = Store.get_colony(cid)
    colony["queen_bee_id"]
  end
end
