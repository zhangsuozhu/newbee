defmodule Newbee.Web.ColonyWorkviewTest do
  use ExUnit.Case, async: true

  @tag skip: is_nil(System.find_executable("bun"))
  test "work responsibility and review evidence use executable presentation policies" do
    bun = System.find_executable("bun") || flunk("Bun is required for executable Web UI tests")

    script = ~S"""
    import assert from 'node:assert/strict';
    import {attentionAction, attentionWorks, workAttention, pendingReviewHoney, reviewModel} from './priv/web/colony/workview.js';
    const owner = {canManage: true, actorId: 'owner'};
    const member = {canManage: false, actorId: 'human'};
    const review = {id:'review', status:'pending_review', context_revision:2, acceptance:['并发刷新', '旧会话'], result:'new'};
    const blocked = {id:'blocked', status:'blocked', waiting_for:'user'};
    const human = {id:'human-task', status:'running', owner_kind:'human', assigned_bee_id:'human'};
    assert.equal(attentionAction(review, owner).section, 'results');
    assert.equal(attentionAction(review, member), null);
    assert.equal(attentionAction({...review,integration_required:true}, owner), null);
    assert.equal(attentionAction({...review,status:'done',approval_required:true}, owner), null);
    assert.equal(attentionAction(blocked, member), null);
    assert.equal(attentionAction(blocked, owner).reason, '等待你答复');
    assert.equal(attentionAction({...blocked,next_step:'执行器没有心跳，无法确认'}, owner).section, 'execution');
    assert.equal(attentionAction(human, member).reason, '由你负责');
    assert.equal(attentionAction({...human,assigned_bee_id:'other'}, member), null);
    assert.equal(attentionAction({...human,status:'blocked',waiting_for:'user'}, owner), null);
    const parent = {id:'parent',status:'running'};
    const child = {...blocked,id:'child',parent_task_id:'parent'};
    assert.deepEqual(attentionWorks([parent,child],owner).map(t=>t.id), ['parent']);
    assert.equal(workAttention(parent,[parent,child],owner).section, 'collaboration');
    assert.deepEqual(attentionWorks([parent,child],member), []);
    const pending = {id:'new',task_id:'review',review_state:'pending_review'};
    assert.deepEqual(pendingReviewHoney([review],[pending],[],member), []);
    assert.equal(pendingReviewHoney([review],[pending],[],owner).length,1);
    assert.equal(pendingReviewHoney([review],[pending],[review],owner).length,0);
    assert.equal(pendingReviewHoney([review],[{...pending,id:'old'}],[],owner).length,0);
    assert.equal(pendingReviewHoney([review],[{...pending,task_id:'missing'}],[],owner).length,0);
    assert.equal(pendingReviewHoney([parent,child],[{...pending,task_id:'child'}],[parent],owner).length,0);
    const honey = {work_revision:2,evidence:[{id:'record',text:'全部通过'},{id:'record',text:'同一证据'}, {text:'重复正文'}, {text:'重复正文'}], limitations:[]};
    let model = reviewModel(review,honey);
    assert.equal(model.revision,'matching');
    assert.deepEqual(model.criteria.map(row=>row.status),['unverified','unverified']);
    assert.equal(model.records.length,3); // IDs deduplicate; identical text is not an identity.
    const checks = [{check:'并发刷新',ok:true,detail:'检查报告'}, {check:'其他检查',ok:true}];
    model = reviewModel(review,{...honey,review:{auto_checks:checks},checks:[{check:'旧会话',ok:true}]});
    assert.deepEqual(model.criteria.map(row=>row.status),['passed','unverified']);
    assert.equal(model.otherChecks.length,1);
    model = reviewModel(review,{...honey,review:{auto_checks:[...checks,{check:'并发刷新',ok:false}]}});
    assert.equal(model.criteria[0].status,'failed');
    assert.equal(reviewModel(review,{...honey,checks:[{check:'并发刷新',ok:'true'}]}).criteria[0].status,'unverified');
    assert.equal(reviewModel(review,{...honey,work_revision:1}).revision,'changed');
    assert.equal(reviewModel(review,{}).revision,'unknown');
    assert.equal(reviewModel(null,honey).revision,'unknown');
    assert.equal(reviewModel(review,honey).gitRevision,null); // Requirement matching is not code validation.
    assert.equal(reviewModel({...review,acceptance:[]},honey).criteria.length,0);
    console.log('presentation policies passed');
    """

    {output, status} = System.cmd(bun, ["--eval", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "presentation policies passed"
  end

  test "refresh rendering preserves an explicitly selected queue" do
    js = File.read!("priv/web/colony/chat.js")
    assert js =~ "const selected = requested;"
    refute js =~ "state.workFilter = selected;"
    assert js =~ "state.drill?.honey"
    assert js =~ "reviewModel(task, d)"
    assert File.read!("priv/web/colony/drill.js") =~ "data: {...honey, honey_id: honey.id}"
  end
end
