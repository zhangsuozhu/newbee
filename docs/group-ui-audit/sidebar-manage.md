# 左侧群卡片 + 群管理弹窗 · 可用性 / 视觉审计（只读）

审计对象：newbee WebUI「项目协作群」区域（侧栏群卡片 + ⋯ 菜单 + 群管理弹窗 + 建群/加群弹窗）。
审计方式：只读代码 + 在预览环境 http://127.0.0.1:4399 实测（Chromium 1440×900 桌面 / 390×844 手机，四套主题切换采样）。
只读声明：本次未修改 priv/ 与 lib/ 下任何文件；唯一产物是本报告与 `.newbee/group-ui-audit/shots/` 下的截图。

## 0. 审计基线（行号只对该基线有效）

| 文件 | sha256（前 16 位） | 备注 |
| --- | --- | --- |
| priv/web/app.js | C57987E6F812460C | mtime 2026-09-10 12:51:34 |
| priv/web/style.css | B26227F9E6F0AEE7 | mtime 2026-09-10 12:54:53 |
| priv/web/index.html | FBC7502005BBFD51 | mtime 2026-09-10 12:41:09 |

注意：审计期间工作区被其他会话并发修改（app.js / style.css 在 12:41→12:54 之间多次变化）。报告中的行号对应上表基线；若文件再次变化，请用引用的选择器 / 函数名重新定位。截图目录中 `shots/old-build/` 是改动前旧版界面的存档，未被本报告引用。

环境实测样本：示例群「订单系统开发组」（3 台机器：1 在线 / 2 离线、2 群会话、2 任务、自动会诊关闭），另一群「test」。

## 1. 问题清单（18 条）

- [P0] 三个群相关弹窗对键盘不可用：Esc 关不掉、打开后焦点不进入弹窗、Tab 直接跑到背后侧栏 | priv/web/app.js:3735 openXManage、4052-4057 事件绑定；priv/web/index.html:411/426/443 | 实测（1440×900，拟物）：打开「群管理」后 focusOnOpen="BODY#"、inModal=false、Esc 后 modalAfterEsc=true；连按 6 次 Tab 焦点依次落在背景的「建群→加群→▾→聊天室→⋯」；截图 shots/desktop-1440-neumorphic-manage-overview.png | 打开时把焦点移到弹窗内首个控件（或给 .modal-box 加 tabindex="-1"+focus()），全局 Esc 关闭最上层弹窗并归还焦点，背景设 inert/aria-hidden 做 focus trap
- [P0] 群卡「⋯」菜单用 fixed 定位且不跟随滚动，侧栏一滚菜单就脱离锚点、悬在别的群卡片上，点击会作用到原群 | priv/web/app.js:3368-3399（xPopup / xGroupMenu）；priv/web/style.css:3315（.xg-menu position:fixed） | 实测 #session-list.scrollTop=200 后锚点 y=298 而菜单仍停在 y=50；截图 shots/desktop-1440-menu-after-scroll.png（菜单悬在两群卡片之间） | 监听 scroll/resize 关闭或重定位菜单；或把菜单渲染进卡片内用 absolute；打开时把焦点移入菜单首项、关闭归还锚点
- [P0] 破坏性操作缺少确认：机器/成员「移除」、会话「移出群」单击即执行；「退出群/解散群」只靠 3 秒内连点两次，且两键相邻 | priv/web/app.js:4026-4028（rm-d / rm-m / unbind-s 无 confirm）、4039-4050（xArm 双击确认）、3946（危险操作行） | 同文件 4032 的 task-cancel 有 confirm 作对照，说明是遗漏而非设计；390px 实测两键 x=50/120、高 44px、间距 8px（shots/mobile-390-neumorph-dark-manage-settings-danger.png） | 移除类改用 confirmDialog 并写清对象与后果；「解散群」要求输入群名或独立红色确认弹窗；两键之间加间隔与分区，统一危险样式
- [P1] 状态圆点在侧栏机器行与管理弹窗行恒为 0×0（不可见），因为尺寸与配色只写在 .session-item 作用域内 | priv/web/style.css:178-184、3338-3339、3396；priv/web/app.js:3495、3858 | 实测 getBoundingClientRect：侧栏 .xg-dev .sess-dot w=0 h=0、管理弹窗 #xm_body .sess-dot w=0 h=0，背景色 rgba(0,0,0,0)（.xg-dev 下的 sess-dot 没有任何尺寸规则） | 把 .sess-dot 基础尺寸与 online/offline/paused 三态色提升为全局选择器；或改为带文字的「在线/离线/已暂停」小胶囊
- [P1] 亮色/暗色主题 11px 次要文字对比度不足（2.67–4.09:1），而拟物主题 4.69:1 以上，三主题不一致 | priv/web/style.css:3293-3301（.xg-live/.xg-chip）、3273-3274（.xzone-title）、3333（.xg-note）、3348（.xg-linkbtn） | 同页采样计算：.xg-hd-meta / .xg-dev-state / .xg-task-state = 2.67（light）、3.01（dark）；.xzone-title = 3.02 / 3.32；.xg-note = 3.72；.xg-linkbtn = 4.09；拟物主题同项 4.69–7.11（WCAG AA 正文需 4.5:1）；截图 shots/desktop-1440-light-sidebar.png、desktop-1440-dark-sidebar.png、desktop-1440-neumorph-dark-sidebar.png | light/dark 下把 --nb-label-caption 加深到 ≥4.5:1（或这些位置改用 --nb-label-2）；把对比度写进主题 token 回归检查
- [P1] 「暂停」只在颜色上表达：群卡头部文字仍是「x/y 在线」，暂停与离线文案无法区分 | priv/web/app.js:3336-3347（xGroupLive 返回 paused）、3448-3450（liveTxt 未用 paused）、3465；priv/web/style.css:3298-3299 | 代码中 paused 只用于拼接 class；liveTxt 恒为「online/total 在线」。实测该群 1 在线 + 2 离线，头部显示「1/3 在线」；若一台暂停，仍是同样文案、只把胶囊染成警示色 | 头部文案分层，例如「2/3 在线 · 1 台已暂停」；机器行内加「已暂停」文字标签而非只靠底色
- [P1] 空状态三处不一致：无群时没有分区标题、搜索无匹配时整块静默消失、管理弹窗对空群显示「0/0 机器在线」 | priv/web/app.js:3413-3425（空群/搜索分支）、3793（摘要恒拼 online/total） | 运行时把会话搜索设为 "zzzz"：.xgroup=0、.xgroup-empty=0，页面上只出现会话级文案「没有匹配「zzzz」的会话」，协作群分区无声消失；对照 3450 侧栏有空值兜底「等待加入」而 3793 没有 | 空群渲染分区标题 + 一句说明；搜索无匹配时给协作群分区自己的空提示；弹窗对 total=0 显示「还没有机器加入」
- [P1] 「设置」页签里没有设置：成员与危险操作在「设置」，真正的设置「任务阻塞时自动会诊」在「概览」 | priv/web/app.js:3733（XM_TABS）、3825-3828（概览内开关）、3935-3946（设置=成员+危险操作） | 运行时 settingsTabSections = 成员 / 危险操作；截图 shots/desktop-1440-neumorphic-manage-settings.png 与 desktop-1440-neumorphic-manage-overview.png | 概览只留摘要与邀请；自动会诊等群级设置移入「设置」；成员单独成页签，危险操作固定在设置底部
- [P1] 空群卡片上的「邀请机器」跳到不存在的页签 invite，实际落到最后的 else 分支（成员/危险操作），拿不到加群码 | priv/web/app.js:3534（{tab:"invite"}）对比 3733（XM_TABS 无 invite）、3935（else 分支） | 代码路径：renderXManage 只有 overview/devices/work/shared 四个分支，其余一律渲染「成员 + 危险操作」，全文没有任何 tab==="invite" 分支 | 改为 {tab:"overview"}；renderXManage 对未知 tab 兜底到 overview，避免以后再加错页签
- [P1] 搜索会把群会话从群卡片里拽出来，退化成平铺条目，丢失「群会话」标记与所属群 | priv/web/app.js:3410-3420（renderXGroups 过滤/渲染）、3333（匹配只用群名/project_id）、4068-4069（addItem 去重） | 运行时搜 "appimg"（群内会话标题）→ .xgroup=0，该会话出现在「其他会话」区、childCells=0，用户看不到它属于哪个群 | 会话命中时保留群卡片并标出命中项；或至少在平铺条目上保留「群会话 · 群名」标记
- [P1] 机器行 / 任务行是带 onclick 的 div，没有 tabindex 与 role，键盘完全到不了 | priv/web/app.js:3492-3499（.xg-dev + onclick）、3549-3556（.xg-task） | 实测卡片内可点击 div=9 个，devTagName="DIV"、devTabindex=null、devRole=null，卡片内可聚焦元素只有 button（折叠、聊天室、⋯ 等） | 改成 <button>，或补 role="button"、tabindex="0" 与 Enter/Space 处理
- [P1] 失败被静默吞掉：退出/解散失败照样关窗并清掉本地身份；群卡片渲染异常时整块消失 | priv/web/app.js:4039-4050（catch 空）、4116（try{renderXGroups}catch{}） | 代码：catch 内无 line("error"…) 提示，且 localStorage.removeItem("xgroup.me."+gid) 仍会执行；rpc 失败用户看到的现象与成功一致 | catch 里给出可见错误，失败时不关窗不清身份；渲染异常给一条降级提示（例如「协作群加载失败，点此重试」）
- [P1] 手机端触摸目标不一致：⋯ 恒为 26×26，其他群按钮亮/暗主题 32px、拟物 44px | priv/web/style.css:3304-3305（.xg-icon-btn 26px）、3481（≤768px .xg-btn 32px）、3972-3973（拟物 min-height 44px） | 390×844 实测：⋯=26px（四主题相同）；「聊天室」=32px（light/dark）、44px（拟物）；「建群/加群」=32px / 44px | 手机端把 .xg-icon-btn 提到 ≥32px；尺寸规则从主题选择器里移出，统一放在 @media 中，避免同控件随主题变高矮
- [P1] 会话视图与页签状态脱节：打开「看对话」后正文是对话，页签仍高亮原页签；标题显示原始 sessionId | priv/web/app.js:3703-3730（xShowConversation 只写 xm_body）、3712（标题用 sessionId） | 实测打开 conv:sess-checkout-1 后 .xm-tab.current 仍为「共享内容」，正文首行「对话 · sess-checkout-1」；截图 shots/desktop-1440-neumorphic-conversation.png；3715 只取最近 200 条且无「已截断」提示 | 对话视图给独立标题/面包屑并清除页签高亮（或加一个「对话」页签）；标题优先用会话标题；截断时显示「仅显示最近 200 条」
- [P2] ARIA tabs 语义不完整、共享内容表单只有 placeholder | priv/web/app.js:3802-3811（页签）、priv/web/index.html:447-448、priv/web/app.js:3932（共享内容表单） | 实测 ariaControls=null、xm_body 的 aria-labelledby 与 aria-label 均为 null；按 ArrowRight 不切换页签（必须 Tab+Enter）；.xm-share-compose 的输入没有 label | 补 aria-controls / aria-labelledby，加左右方向键切换；给输入补可见或 sr-only 的 <label>
- [P2] 状态修饰类没有对应样式：.xg-live.offline 与 .xg-chip.busy 在 CSS 中不存在 | priv/web/style.css:3293-3301 | 源码检索只有 .xg-live、.xg-live.online、.xg-live.paused、.xg-chip；运行时 class 实际是 "xg-live offline" 与 "xg-chip busy"，离线/进行中胶囊退化为默认灰底与普通强调色 | 补齐 offline（灰）与 busy 的语义样式，或删掉无用 class，避免以后误以为已有区分
- [P2] 群卡头部在 390px 塞进 4 个控件 + 3 段统计，且统计之间缺空格 | priv/web/app.js:3455-3467；priv/web/style.css:3285-3290 | 390px 实测 header 高 82px，元信息单行 357px，textContent 为「1/3 在线·3 台机器·2 会话·2 任务2 进行中」（「任务」与「2 进行中」之间无空格，读屏会连读） | 分隔符统一为带空格的「·」；把「x 进行中」并入任务段；手机端可只保留「x/y 在线」与「n 任务」
- [P2] 同一批实体四处不同叫法：侧栏「机器」、弹窗页签「机器」、设置里「成员」、聊天室「代表」，且摘要里并排出现 | priv/web/app.js:3455、3733、3787-3796（摘要）、3936（成员） | 摘要同时显示「x 机器在线」与「x 位代表」；「成员」与「机器」在设置页相邻出现却语义不同（入群身份 vs 执行设备） | 建立术语表并在设置页加一句解释（成员=入群身份、机器=执行设备、代表=聊天室角色）；摘要按同一术语收敛

## 2. 覆盖度对照（任务要求 → 条目）

| 要求维度 | 对应条目 |
| --- | --- |
| 信息层级 | 8、14、17、18 |
| 术语与文案 | 6、8、14、18 |
| 状态表达（在线/暂停/远端） | 4、6、16 |
| 空状态 | 7、9 |
| 窄屏 390px | 13、17、3 |
| 键盘可达性与焦点 | 1、2、11、15 |
| 暗色 / 亮色 / 新拟物三主题一致性 | 5、13、16 |
| 误操作风险（移除/解散/退出） | 3、12 |

## 3. 改动清单（按实现优先级）

| 优先级 | 改动 | 涉及文件 | 预估工作量 |
| --- | --- | --- | --- |
| 1 | 弹窗键盘支持：打开即聚焦弹窗内首控件、Esc 关闭最上层弹窗、背景 inert/焦点环内循环 | priv/web/app.js（openXManage/xOpen/xClose 与三个 modal 的绑定，约 60 行）、priv/web/index.html（给 .modal-box 或首控件补 tabindex，3 处） | 0.5–1 天 |
| 2 | 破坏性操作二次确认：「移除机器/成员」「移出群」接入 confirmDialog；「解散群」改为输入群名的独立确认；危险按钮分区与间距 | priv/web/app.js（3957-4050 动作分发 + 3891-3946 渲染）、priv/web/style.css（.xm-card.danger/.xm-actions） | 0.5 天 |
| 3 | ⋯ 菜单跟随锚点：滚动/resize 关闭或重定位，打开时聚焦首项、关闭归还焦点 | priv/web/app.js:3366-3408（xPopup）、priv/web/style.css:3315 | 0.3 天 |
| 4 | 状态点修复：.sess-dot 基础尺寸与三态色提升为全局；「暂停」加入文字表达 | priv/web/style.css:178-184/3338-3339/3396、priv/web/app.js:3448-3466 | 0.3 天 |
| 5 | 对比度修复：light/dark 的 --nb-label-caption 提到 ≥4.5:1，核对其余 11px 文本 | priv/web/style.css（主题 token 段 + .xzone-title/.xg-note/.xg-linkbtn） | 0.3 天 |
| 6 | 空状态补齐：无群分区标题与说明、搜索无匹配提示、弹窗空群文案 | priv/web/app.js:3413-3425、3790-3796 | 0.3 天 |
| 7 | 页签信息架构：invite→overview 修正、自动会诊移入设置、成员独立页签 | priv/web/app.js:3534、3733、3815-3946 | 0.3 天 |
| 8 | 可点击行语义化：.xg-dev/.xg-task 改 button（或 role+tabindex+键盘处理） | priv/web/app.js:3491-3558、priv/web/style.css:3325/3350 | 0.3 天 |
| 9 | 搜索保留群上下文：会话命中时保留群卡片并标出命中项 | priv/web/app.js:3410-3420、4068-4069 | 0.5 天 |
| 10 | 失败不再静默：leave/dissolve/renderXGroups 的 catch 给出可见错误并保留状态 | priv/web/app.js:4039-4050、4116 | 0.2 天 |
| 11 | 手机触摸目标统一：.xg-icon-btn ≥32px，尺寸规则移出主题选择器 | priv/web/style.css:3304-3305、3481、3972-3973 | 0.2 天 |
| 12 | 打磨：对话视图标题/截断提示、ARIA tabs、.xg-live.offline/.xg-chip.busy、头部统计分隔与术语统一 | priv/web/app.js:3703-3730/3802-3811/3455-3467、priv/web/style.css:3293-3301 | 0.5 天 |

合计约 4.2 天（1 人）；其中第 1–3 项直接决定键盘可用性与误操作风险，建议优先。

## 4. 证据索引

截图（相对仓库根，均为本次实测，非旧版）：

- 侧栏四主题：shots/desktop-1440-neumorphic-sidebar.png、shots/desktop-1440-light-sidebar.png、shots/desktop-1440-dark-sidebar.png、shots/desktop-1440-neumorph-dark-sidebar.png
- ⋯ 菜单：shots/desktop-1440-neumorphic-groupcard-menu.png、shots/desktop-1440-menu-after-scroll.png、shots/mobile-390-neumorph-dark-groupmenu.png
- 群管理弹窗：shots/desktop-1440-neumorphic-manage-overview.png、shots/desktop-1440-light-manage-overview.png、shots/desktop-1440-dark-manage-overview.png、shots/desktop-1440-neumorphic-manage-settings.png、shots/desktop-1440-neumorph-dark-manage-settings.png、shots/desktop-1440-neumorphic-conversation.png
- 长列表/矮视口：shots/desktop-1440-manage-longlist-clipped.png（合成 9 倍行数，验证 .xm-body max-height 生效：scrollHeight 1010 / clientHeight 540）、shots/desktop-1440x600-shared-clipped.png
- 手机 390×844：shots/mobile-390-light-sidebar.png、shots/mobile-390-dark-sidebar.png、shots/mobile-390-neumorph-dark-sidebar.png、shots/mobile-390-neumorph-dark-manage-overview.png、shots/mobile-390-neumorph-dark-manage-devices.png、shots/mobile-390-neumorph-dark-manage-work.png、shots/mobile-390-neumorph-dark-manage-shared.png、shots/mobile-390-neumorph-dark-manage-settings-danger.png、shots/mobile-390-light-manage-settings.png
- 旧版存档（未引用）：shots/old-build/

复现要点（只读、可重跑）：

1. 打开 http://127.0.0.1:4399，展开「订单系统开发组」卡片。
2. 键盘：聚焦卡片「⋯」按 Enter，菜单出现但焦点仍在按钮；Tab 6 次可观察到焦点走到背景控件；打开群管理后按 Esc 不关闭。
3. 滚动：保持「⋯」菜单打开，滚动侧栏 200px，菜单不移动（fixed），与锚点分离。
4. 对比度：切到 light/dark，采 .xg-hd-meta 与 .xg-dev-state 的 color/背景，比值 2.67 / 3.01。
5. 搜索：会话搜索框输入 "zzzz"（群分区静默消失）与 "appimg"（群会话掉到「其他会话」）。
6. 尺寸：390×844 下用 getBoundingClientRect 读 .xg-icon-btn（26）与 .xg-btn（32/44）。
