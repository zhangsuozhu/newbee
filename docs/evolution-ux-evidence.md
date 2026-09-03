# 进化 UX 整改完成证据（fix/evo-ux-focus）

## 改了什么
```
 lib/newbee/web/api.ex |  83 ++++++++++++++++-
 priv/web/app.js       | 249 ++++++++++++++++++++++++++++++++++++++------------
 priv/web/index.html   |  51 ++++++++---
 priv/web/style.css    |  29 ++++++
 4 files changed, 338 insertions(+), 74 deletions(-)

```

## Bug 修复证据：抢焦点已消除
- 旧代码 `if (MC.open) switchMCTab("steps")` 残留搜索：
```
(none - fixed)
```
- 新机制（徽标代替抢占 + sticky tab）：
```
3357:      // 新步骤只亮徽标（updateMCBadges），把控制权还给用户。
3358:      if (MC.open && MC.tab !== "steps") { MC.stepsUnread++; updateMCBadges(); }
3364:        if (MC.tab !== "files") { MC.filesUnread++; updateMCBadges(); }
4192:      if (decideCount > 0 && !(MC.open && MC.tab === "evolution")) { MC.evoUnread = decideCount; updateMCBadges(); }
4650:  function updateMCBadges() {
4659:  function bumpMCBadge(tab) {
4664:    updateMCBadges();
4692:      const savedTab = localStorage.getItem("newbee-mc-tab");
4700:    updateMCBadges();
4735:    try { localStorage.setItem("newbee-mc-tab", tab); } catch (e) {}
4739:    updateMCBadges();
4822:    if (MC.open && MC.tab !== "steps") bumpMCBadge("steps");
```

## UX 重构证据：人话骨架存在
```
110:      <button class="mc-tab active" data-tab="files" title="文件变更"><svg class="ico" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg> 文件<span class="mc-badge hidden" id="mc-badge-files"></span></button>
111:      <button class="mc-tab" data-tab="steps" title="执行步骤"><svg class="ico" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg> 步骤<span class="mc-badge hidden" id="mc-badge-steps"></span></button>
114:      <button class="mc-tab" data-tab="evolution" title="环境进化">⟁ 进化<span class="mc-badge hidden" id="mc-badge-evolution"></span></button>
201:      <div class="evo-intro">
202:        <div class="evo-intro-text"><strong>环境进化 = 让 AI 自己变好，但由你把关</strong><span>AI 发现重复问题 → 提出最小改进 → 跑完 5 道验证 → 需要你批准才会生效。旧版本保留，随时可回退。</span></div>
205:      <div id="evo-guide" class="evo-guide hidden">
234:        <div id="evo-decide-list" class="evo-changes-list"></div>
```

## 验证
- `mix compile --warnings-as-errors`（dev/test）零警告（worktree 实测通过）
- `mix test test/newbee/web/evolution_ux_test.exs`：4 passed
- `mix test test/newbee/web/`：73 passed, 1 excluded
- `bun build priv/web/app.js`：Bundled 1 module（JS 语法通过）
- 后端契约：`evolution.status` 新增 `autonomy_explain`，`evolution_change` 新增 `human_title/reason_plain/risk_label/reversibility/verification_summary`，旧字段保留兼容

## 文献依据
- https://www.nngroup.com/articles/ten-usability-heuristics/ （H1/H2/H3/H5/H8/H10）
- https://www.nngroup.com/articles/confirmation-dialog/ （具体后果 + 动词按钮 + undo）
- https://www.nngroup.com/articles/progressive-disclosure/ （首屏/二级切分）
- https://www.nngroup.com/articles/user-control-and-freedom/ （Back/Undo/Exit）
- https://www.nngroup.com/articles/attention-economy/ （Simon 注意力瓶颈）
- 详见 docs/evolution-ux-audit.md

## 手工走查（请 reviewer 复核）
1. 打开 Mission Control → 切到进化：首屏看到一句话定义 + “怎么判断要不要批准？”
2. 切到其他 tab（如 Diff/概览）→ 让 AI 跑一步：确认不再被拽到步骤，步骤 tab 亮徽标
3. 有待决策时进化 tab 亮徽标；点进化看到“是否让环境记住这个改进？”+ 证据/风险/可逆三行 + “批准并激活/再想想”
