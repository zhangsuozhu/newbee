// 蜂群前端 · 输入区（与主界面同款）：附件上传 / 拖拽 / 粘贴、思考强度、待验收条、发往哪里
import { esc, fmtBytes, kindLabel } from "./util.js";
import { rpc, toast, authToken } from "./api.js";
import { state, currentBeeId, currentTaskId, memberById, resetToChat } from "./store.js";
import { manage, help, joinEnvironment } from './manage.js';
import { refresh } from './store.js';

const MAX_ATTACH = 8;
const MAX_FILE = 20 * 1024 * 1024;
const MAX_IMAGE = 8 * 1024 * 1024;
const EFFORT_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
const EFFORT_LABELS = { none: "关闭", minimal: "极低", low: "低", medium: "中", high: "高", xhigh: "极高", max: "最高", ultra: "极限" };

let ctxRef = null;
let mentionOpen = false;

export function renderComposer(ctx) {
  ctxRef = ctx;
  const bar = document.getElementById("quick-bar");
  if (!bar || bar.dataset.ready === "1") return;
  bar.dataset.ready = "1";

  const chips = [
    ['＋', '新工作', 'primary', () => prefill('请帮我完成：')],
    ['◔', '当前工作', '', () => { state.groupTab = 'work'; resetToChat(); ctx.render(true); }],
    ['？', '能做什么', '', help],
    ['⚙', '群设置', '', manage],
    ['⇢', '加入蜂群', 'secondary', joinEnvironment],
  ];
  for (const [icon, label, kind, fn] of chips) {
    const b = document.createElement("button");
    b.className = "chip-btn" + (kind ? " " + kind : "");
    b.type = "button";
    const ico = document.createElement("span");
    ico.className = "chip-ico";
    ico.textContent = icon;
    const text = document.createElement("span");
    text.textContent = label;
    b.append(ico, text);
    b.title = label;
    b.onclick = fn;
    bar.appendChild(b);
  }
  // 暂停/恢复全群 AI 是宿主级开关，放在顶栏（不在输入区抢位置），见 bindPause()。
  const scope = document.createElement("span");
  scope.className = "colony-scope";
  scope.id = "scope-hint";
  bar.appendChild(scope);

  const input = document.getElementById("input");
  const sendBtn = document.getElementById("send");
  input.value = state.draft || "";
  input.addEventListener("input", () => {
    state.draft = input.value;
    autosize(input);
  });
  input.addEventListener("keydown", (e) => {
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === "Enter" && !e.shiftKey) {
      if (mentionOpen) return; // 正在挑 @ 的成员，回车交给选择器
      e.preventDefault();
      send(ctx, input.value);
    }
  });
  sendBtn.addEventListener("click", () => send(ctx, input.value));

  bindAttachments(ctx);
  bindEffort(ctx);
  bindMentions();
  bindPause();
  if (ctx.autofocus) input.focus();
}

// ── 附件：按钮 / 拖拽 / 粘贴（与主界面同一套上传接口与预览样式）──

function bindAttachments(ctx) {
  const input = document.getElementById("input");
  const fileInput = document.getElementById("file-input");
  const attachBtn = document.getElementById("attach-btn");
  if (!attachBtn || !fileInput) return;

  attachBtn.addEventListener("click", async () => {
    try {await ensureUploadSession();} catch (error) {toast(error.message, true); return;}
    const t = target();
    if (!t.sid) {
      toast(t.why || "该对象还没有绑定会话，无法上传附件", true);
      return;
    }
    fileInput.click();
  });

  fileInput.addEventListener("change", async () => {
    await addFiles([...fileInput.files]);
    fileInput.value = "";
  });

  input.addEventListener("paste", async (e) => {
    const files = [...((e.clipboardData && e.clipboardData.files) || [])];
    if (!files.length) return;
    e.preventDefault();
    await addFiles(files);
  });

  const card = document.querySelector(".composer-card");
  const overlay = document.getElementById("drop-overlay");
  if (!card || !overlay) return;
  let depth = 0;
  card.addEventListener("dragenter", (e) => {
    e.preventDefault();
    depth += 1;
    overlay.classList.remove("hidden");
  });
  card.addEventListener("dragover", (e) => e.preventDefault());
  card.addEventListener("dragleave", (e) => {
    e.preventDefault();
    depth = Math.max(0, depth - 1);
    if (depth === 0) overlay.classList.add("hidden");
  });
  card.addEventListener("drop", async (e) => {
    e.preventDefault();
    depth = 0;
    overlay.classList.add("hidden");
    await addFiles([...((e.dataTransfer && e.dataTransfer.files) || [])]);
  });
}

async function ensureUploadSession() {
  if (state.uploadColony !== state.colonyId) {
    const result = await rpc('colony.upload.session', {colonyId:state.colonyId});
    state.uploadSid = result.sessionId; state.uploadColony = state.colonyId;
  }
}

async function addFiles(files) {
  if (!files.length) return;
  try {await ensureUploadSession();} catch (error) {toast(error.message, true); return;}
  const t = target();
  if (!t.sid) {
    toast(t.why || "该对象还没有绑定会话，无法上传附件", true);
    return;
  }
  for (const file of files) {
    if (!file) continue;
    if (file.size === 0) {
      toast("不能上传空文件：" + (file.name || "file"), true);
      continue;
    }
    if (file.size > MAX_FILE) {
      toast("文件过大（>20 MiB）：" + file.name, true);
      continue;
    }
    if (state.attachments.length + state.uploading >= MAX_ATTACH) {
      toast(`每条消息最多 ${MAX_ATTACH} 个附件`, true);
      break;
    }
    const sid = t.sid;
    state.uploading += 1;
    renderAttachPreview();
    try {
      const uploaded = await uploadAttachment(file, sid);
      if (target().sid !== sid) {
        await deleteAttachment(uploaded, sid).catch(() => {});
        continue;
      }
      const isImage = !!uploaded.image && file.size <= MAX_IMAGE;
      const dataUrl = isImage ? await fileAsDataUrl(file) : null;
      state.attachments.push({
        id: uploaded.id,
        name: uploaded.name,
        type: uploaded.content_type,
        size: uploaded.size,
        isImage,
        dataUrl,
      });
      state.attachSid = sid;
    } catch (e) {
      toast("上传失败：" + (e.message || e), true);
    } finally {
      state.uploading -= 1;
      renderAttachPreview();
    }
  }
}

async function uploadAttachment(file, sid) {
  const headers = { "content-type": file.type || "application/octet-stream" };
  const token = authToken();
  if (token) headers.authorization = "Bearer " + token;
  const url = `/api/upload/${encodeURIComponent(sid)}?name=${encodeURIComponent(file.name || "file")}`;
  const res = await fetch(url, { method: "POST", headers, body: file });
  let body = null;
  try {
    body = await res.json();
  } catch (e) {
    /* handled below */
  }
  if (!res.ok || !body || !body.ok) {
    throw new Error(body && body.error ? body.error.message : `上传失败 (HTTP ${res.status})`);
  }
  return body.ok;
}

async function deleteAttachment(a, sid = state.attachSid) {
  if (!a || !a.id || !sid) return;
  const headers = {};
  const token = authToken();
  if (token) headers.authorization = "Bearer " + token;
  await fetch(`/api/upload/${encodeURIComponent(sid)}/${encodeURIComponent(a.id)}`, { method: "DELETE", headers });
}

function renderAttachPreview() {
  const box = document.getElementById("attach-preview");
  if (!box) return;
  if (state.attachments.length === 0 && state.uploading === 0) {
    box.classList.add("hidden");
    box.innerHTML = "";
    return;
  }
  box.classList.remove("hidden");
  box.innerHTML = "";
  state.attachments.forEach((a, i) => {
    const item = document.createElement("div");
    item.className = "attach-item";
    if (a.isImage && a.dataUrl) {
      const img = document.createElement("img");
      img.src = a.dataUrl;
      img.alt = a.name;
      item.appendChild(img);
    } else {
      const icon = document.createElement("div");
      icon.className = "attach-file-icon";
      icon.textContent = (a.name.split(".").pop() || "FILE").slice(0, 5).toUpperCase();
      item.appendChild(icon);
    }
    const cap = document.createElement("span");
    cap.className = "attach-name";
    cap.textContent = a.name;
    cap.title = `${a.name} (${fmtBytes(a.size)})`;
    const rm = document.createElement("button");
    rm.className = "attach-remove";
    rm.textContent = "×";
    rm.title = "移除";
    rm.onclick = () => {
      const removed = state.attachments.splice(i, 1)[0];
      renderAttachPreview();
      deleteAttachment(removed).catch(() => {});
    };
    item.appendChild(cap);
    item.appendChild(rm);
    box.appendChild(item);
  });
  if (state.uploading > 0) {
    const pending = document.createElement("div");
    pending.className = "attach-item attach-uploading";
    pending.textContent = `正在上传 ${state.uploading} 个文件`;
    box.appendChild(pending);
  }
}

function clearAttachments(removeRemote) {
  const pending = state.attachments.slice();
  state.attachments = [];
  renderAttachPreview();
  if (removeRemote) pending.forEach((a) => deleteAttachment(a).catch(() => {}));
}

function fileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("读取图片预览失败"));
    reader.readAsDataURL(file);
  });
}

// ── 思考强度：只在「与 AI 对话」时出现（群聊隐藏）──

function bindEffort(ctx) {
  const wrap = document.getElementById("effort-segments");
  const btn = document.getElementById("effort-btn");
  const btnText = document.getElementById("effort-btn-text");
  if (!wrap || !btn) return;

  const close = () => {
    wrap.classList.add("hidden");
    btn.setAttribute("aria-expanded", "false");
  };
  const renderSegs = (active) => {
    wrap.innerHTML = "";
    EFFORT_LEVELS.forEach((lv) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "effort-seg" + (lv === active ? " active" : "");
      b.textContent = EFFORT_LABELS[lv] || lv;
      b.title = lv;
      b.dataset.level = lv;
      b.setAttribute("role", "menuitem");
      b.onclick = async (e) => {
        e.stopPropagation();
        renderSegs(lv);
        close();
        const t = target();
        if (!t.sid) return;
        try {
          await rpc("session.setEffort", { sessionId: t.sid, effort: lv });
          toast(`「${t.label}」思考强度：${EFFORT_LABELS[lv] || lv}`);
        } catch (err) {
          toast("设置思考强度失败：" + (err.message || err), true);
        }
      };
      wrap.appendChild(b);
    });
    if (btnText) btnText.textContent = EFFORT_LABELS[active] || active;
    btn.dataset.level = active;
    btn.title = "思考强度：" + (EFFORT_LABELS[active] || active);
    btn.classList.toggle("on", active !== "none");
  };
  btn.onclick = (e) => {
    e.stopPropagation();
    if (target().bee && target().bee.kind !== "ai") return;
    const willOpen = wrap.classList.contains("hidden");
    if (willOpen) {
      wrap.classList.remove("hidden");
      btn.setAttribute("aria-expanded", "true");
    } else close();
  };
  document.addEventListener("click", (e) => {
    if (!e.target.closest(".effort-pick")) close();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
  });

  window.__colonyRestoreEffort = (effort) => renderSegs(effort === "off" ? "none" : effort === "auto" ? "medium" : effort || "medium");
  renderSegs("medium");
}

async function restoreEffort(sid) {
  try {
    const st = await rpc("session.state", { sessionId: sid });
    const effort = st && (st.effort || (st.state && st.state.effort));
    if (window.__colonyRestoreEffort) window.__colonyRestoreEffort(effort || "medium");
  } catch (e) {
    /* 会话未运行：保持默认 */
  }
}

// ── 消息发往哪里 ──

export function target() {
  const queen = queenBee();
  const uploadSid = state.uploadColony === state.colonyId ? state.uploadSid : null;
  const taskId = currentTaskId();
  const beeId = currentBeeId();

  if (taskId) {
    const task = state.drill && state.drill.task;
    const exec = task && task.assigned_bee_id ? memberById(task.assigned_bee_id) : null;
    const sid = exec && exec.session_id;
    return {
      sid: uploadSid || sid || null,
      bee: exec || null,
      label: exec ? exec.display : "当前任务",
      why: "这条任务还没有执行者（或执行者未绑定会话），无法上传附件",
    };
  }
  if (beeId) {
    const bee = memberById(beeId);
    return {
      sid: uploadSid || (bee && bee.session_id) || null,
      bee: bee || null,
      label: bee ? bee.display : "Bee",
      why: "这只 Bee 还没有绑定会话，无法上传附件",
    };
  }
  return {
    sid: uploadSid || null,
    bee: queen || null,
    label: "群聊",
    why: "请先选择蜂群",
  };
}

function queenBee() {
  const data = state.data;
  if (!data) return null;
  const qid = (data.colony || {}).queen_bee_id;
  return (data.members || []).find((m) => m.id === qid) || null;
}

// 顶栏的「暂停/恢复全群 AI」：宿主级开关，不占输入区位置。
function bindPause() {
  const btn = document.getElementById('colony-pause');
  if (!btn || btn.dataset.ready === '1') return;
  btn.dataset.ready = '1';
  btn.onclick = async () => {
    const running = state.data?.control_state === 'running';
    btn.disabled = true;
    try {
      await rpc('colony.control', {colonyId:state.colonyId, scope:'colony', targetId:state.colonyId, action: running ? 'pause' : 'resume'});
      await refresh();
      toast(running ? '已暂停全群 AI（人仍可发言）' : '已恢复全群 AI');
    } catch (error) {
      toast(error.message || '操作失败', true);
    } finally {
      btn.disabled = false;
    }
  };
}

export function updateScope() {
  const pause = document.getElementById('colony-pause');
  if (pause) {
    const cs = state.data?.control_state;
    const show = !!state.data?.can_manage;
    // 必须同时清掉 .hidden 类：index.html 的静态标记就带这个类，而
    // style.css 里 `.hidden{display:none !important}` 会盖住一切，只改 hidden 属性按钮永远不出现。
    pause.hidden = !show;
    pause.classList.toggle('hidden', !show);
    if (show) {
      const running = cs === 'running';
      pause.textContent = running ? '❚❚' : '▶';
      pause.title = running ? '暂停全群 AI（不影响人发言）' : cs === 'pausing' ? '正在暂停…再点恢复' : '恢复全群 AI';
      pause.classList.toggle('is-paused', !running && cs !== 'pausing');
    }
  }

  const hint = document.getElementById("scope-hint");
  const t = target();

  if (hint) {
    const bee = currentBeeId() ? memberById(currentBeeId()) : null;
    const taskId = currentTaskId();
    if (taskId) hint.textContent = `发给 ${t.label}`;
    // 成员层级里对 AI 说话：这句话会被转进它自己的对话（colony.say 走 1:1 会被拒），
    // 提示要写成「将转入对话」，不然等于承诺了一个发不出去的地址。
    else if (bee && bee.kind === "ai" && state.view === "dm") hint.textContent = `将转入 ${bee.display} 的对话`;
    else if (bee) hint.textContent = `发给 ${bee.display}`;
    else hint.textContent = "发到群聊 · Enter 发送，Shift+Enter 换行";
  }


  // 思考强度：与 AI 一对一（或 AI 执行的任务）才有意义；群聊隐藏
  const pick = document.getElementById("effort-pick");
  const btn = document.getElementById("effort-btn");
  if (pick && btn) {
    const isAi = !!(t.bee && t.bee.kind === "ai");
    pick.classList.toggle("hidden", !isAi);
    btn.disabled = !isAi;
  }

  const attachBtn = document.getElementById("attach-btn");
  if (attachBtn) {
    attachBtn.disabled = !state.colonyId;
    attachBtn.title = state.colonyId ? "上传文件（图片也可直接粘贴，也可拖进来）" : "请先选择蜂群";
  }

  // 目标会话变了：丢弃上一批附件（与主界面切会话行为一致）
  if (state.attachSid && state.attachSid !== t.sid) {
    clearAttachments(true);
    state.attachSid = null;
  }
  if (t.sid && t.sid !== state.effortSid && (!t.bee || t.bee.kind === "ai")) {
    state.effortSid = t.sid;
    restoreEffort(t.sid);
  }
}

export function prefill(text) {
  const input = document.getElementById("input");
  if (!input) return;
  const typed = input.value || "";
  // 不能直接覆盖：用户可能已经打了半句，点「＋ 新工作 / ＋ 新任务」时把他写的话弄丢。
  // 模板插到前面，原话留在后面；已经以模板开头就不重复插。
  const next = typed.trim() && !typed.trim().startsWith(text) ? `${text} ${typed.trim()}` : text;
  input.value = next;
  state.draft = next;
  autosize(input);
  input.focus();
  input.setSelectionRange(next.length, next.length);
}

function autosize(input) {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 160) + "px";
}

// 串行化发送：上一条还在飞就排队，而不是静默丢弃。
// 之前发送中会直接 return，快速连按 Enter / 连点发送时第二条被无声丢掉
// 第二条会被无声丢掉（实测 4 次尝试只发出 2 个 colony.say，用户看到「什么都没发生」）。
export function send(ctx, text) {
  const run = () => doSend(ctx, text);
  const next = (send.queue || Promise.resolve()).then(run, run);
  send.queue = next.catch(() => {});
  return next;
}

async function doSend(ctx, text) {
  text = (text || "").trim();
  const uploadIds = state.attachments.map((a) => a.id);
  if (!text && !uploadIds.length) return;
  if (!state.colonyId) { toast('请先选择蜂群', true); return; }
  // 成员层级里给 AI 成员打字：colony.say 带 context.beeId 会走 1:1 会话通道，
  // 而 AI 的 1:1 只能在内嵌对话里进行——服务端固定返回 conversation_required。
  // 既然产品语义是「和这只 Bee 交流」，就直接把话转进它的对话，而不是让用户撞报错。
  if (state.view === "dm" && state.beeModeId) {
    const member = memberById(state.beeModeId);
    if (member && member.kind === "ai") {
      if (uploadIds.length) { toast("附件请打开它自己的对话再发", true); return; }
      const input = document.getElementById("input");
      if (ctx.deliverToConversation) {
        if (input && input.value === text) { input.value = ""; state.draft = ""; autosize(input); }
        await ctx.deliverToConversation(member, text);
        return;
      }
    }
  }


  // 建群/切群还在路上时别把消息发进旧群（send 用的是此刻的 state.colonyId）。
  if (state.switching) { toast('正在创建蜂群，请稍候再发送', true); return; }
  if (state.uploading > 0) { toast("请等待文件上传完成", true); return; }
  // 队列已保证串行，这里不需要再丢弃并发提交。

  const input = document.getElementById('input');
  const button = document.getElementById('send');
  const draft = input?.value || '';
  const route = () => JSON.stringify([state.colonyId, state.view, state.conversationId, state.stack]);
  const origin = route();
  const payload = { colonyId: state.colonyId, text, requestId: crypto.randomUUID(), uploadSid: state.uploadSid };
  const beeId = currentBeeId(), taskId = currentTaskId();
  if (taskId) payload.context = { taskId };
  else if (beeId) payload.context = { beeId };
  if (uploadIds.length) payload.uploadIds = uploadIds;
  send.sending = true;
  if (button) { button.disabled = true; button.setAttribute('aria-label', '发送中'); button.setAttribute('aria-busy', 'true'); }
  sendFeedback('正在发送…');
  let accepted = false;
  try {
    const res = await rpc('colony.say', payload);
    accepted = true;
    // 请求期间新输入的内容、切换页面后的草稿都不能被旧请求清空。
    if (route() === origin) {
      if (input && input.value === draft && draft.trim() === text) {
        input.value = ''; state.draft = ''; autosize(input);
      }
      state.attachments = state.attachments.filter(a => !uploadIds.includes(a.id));
      renderAttachPreview();
    }
    sendFeedback('已发送');
    toast(res.reply ? (res.reply.length > 100 ? '已发送，回复见消息流' : `已发送 · ${res.reply}`) : '已发送');
    if (route() === origin) {
      for (const a of res.actions || []) {
        if (a.type === 'switch' && a.colony_id) await ctx.switchColony(a.colony_id);
      }
    }
    await ctx.refreshNow();
  } catch (e) {
    const message = accepted ? '已发送，但更新消息失败，请刷新查看' : (e.message || '发送失败') + '；输入内容已保留';
    sendFeedback(message, true);
    toast(message, true);
  } finally {
    send.sending = false;
    if (button) { button.disabled = false; button.setAttribute('aria-label', '发送'); button.removeAttribute('aria-busy'); }
  }
}

function sendFeedback(message, error = false) {
  let status = document.getElementById('send-status');
  if (!status) {
    status = document.createElement('div'); status.id = 'send-status';
    status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
    document.getElementById('composer')?.append(status);
  }
  status.textContent = message;
  status.classList.toggle('error', error);
}

// ── 待验收条：沿用主界面 .permission-bar ──
export function updateReviewBar() {
  const bar = document.getElementById("review-bar");
  if (!bar) return;
  // 首页概览已经列出待验收成果和操作按钮，底部不再重复同一条。
  if (state.view === 'chat' && state.groupTab !== 'messages') { bar.classList.add('hidden'); return; }
  const recent = (state.data && state.data.honey && state.data.honey.recent) || [];
  const internalTasks = new Set((state.data?.tasks || []).filter(t => t.integration_required).map(t => t.id));
  const pending = recent.filter(h => !internalTasks.has(h.task_id) && (h.review_state === 'pending_review' || h.review_state === 'auto_verified'));
  if (!pending.length) {
    bar.classList.add("hidden");
    return;
  }
  bar.classList.remove("hidden");
  const title = document.getElementById("review-text");
  if (title) title.textContent = `${pending.length} 件成果待你验收`;
  // 只有一件时不再重复列出标题（成果卡里就有），避免同一句话在首屏出现三次。
  const items = document.getElementById("review-preview");
  if (items) items.textContent = pending.length > 1 ? pending.slice(0, 3).map((h) => h.title).join(" · ") : "";
  document.getElementById("review-go").onclick = (event) => {
    // 键盘激活（Enter/Space）时 click 的 detail 为 0；鼠标点击是 1。
    const fromKeyboard = !event || event.detail === 0;
    state.groupTab = 'work';
    resetToChat();
    // 键盘用户：切到工作台后把焦点直接交给「通过」，否则焦点落到 body，
    // 要从页首 Tab 二十来次才够得到验收按钮。
    setTimeout(() => {
      const card = document.querySelector("[data-honey-pending]");
      if (card) card.scrollIntoView({ block: "center", behavior: "smooth" });
      if (!fromKeyboard) return;
      // 工作台可能还没渲染出「通过」，出现后再抓焦点（最多等 ~1.4s）。
      let tries = 0;
      const grab = () => {
        const accept = document.querySelector(".btn-allow");
        if (accept) { accept.focus(); return; }
        if (++tries < 12) setTimeout(grab, 120);
      };
      grab();
    }, 150);
  };
}

// ── @ 点名：仿微信群。输入 @ 弹出成员列表（含 @all），选中即插入 ──

function mentionCandidates() {
  const members = (state.data && state.data.members) || [];
  return [
    { name: "all", label: "@all", kind: "all", hint: "全体 AI" },
    ...members.map((m) => ({ name: m.display, label: "@" + m.display, kind: m.kind, hint: kindLabel(m.kind) })),
  ];
}

function bindMentions() {
  const input = document.getElementById("input");
  const card = document.querySelector(".composer-card");
  if (!input || !card || card.dataset.mentionReady === "1") return;
  card.dataset.mentionReady = "1";

  const pop = document.createElement("div");
  pop.className = "mention-pop hidden";
  card.appendChild(pop);

  let items = [];
  let active = 0;

  const close = () => {
    pop.classList.add("hidden");
    pop.innerHTML = "";
    items = [];
    mentionOpen = false;
  };

  // 光标前正在输入的 @token
  const tokenAt = () => {
    const pos = input.selectionStart || 0;
    const before = input.value.slice(0, pos);
    const m = before.match(/@([\p{L}\p{N}_\-.]*)$/u);
    return m ? { token: m[0], prefix: m[1], pos } : null;
  };

  const render = () => {
    const tok = tokenAt();
    if (!tok) return close();

    const q = tok.prefix.toLowerCase();
    const all = mentionCandidates();
    items = all
      .filter((c) => !q || c.name.toLowerCase().includes(q) || (c.kind === "all" && "all".startsWith(q)))
      .slice(0, 8);
    if (!items.length) return close();
    if (active >= items.length) active = 0;

    pop.innerHTML = "";
    items.forEach((c, i) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "mention-item" + (i === active ? " active" : "");
      row.innerHTML =
        `<span class="mention-at">${esc(c.label)}</span>` +
        `<span class="mention-kind">${esc(c.hint || "")}</span>`;
      row.onmousedown = (e) => {
        e.preventDefault();
        insert(c);
      };
      pop.appendChild(row);
    });

    pop.classList.remove("hidden");
    mentionOpen = true;
  };

  const insert = (c) => {
    const tok = tokenAt();
    if (!tok) return close();
    const start = tok.pos - tok.token.length;
    const after = input.value.slice(tok.pos);
    input.value = input.value.slice(0, start) + "@" + c.name + " " + after;
    const caret = start + c.name.length + 2;
    state.draft = input.value;
    close();
    input.focus();
    input.setSelectionRange(caret, caret);
  };

  input.addEventListener("input", render);
  input.addEventListener("click", render);
  input.addEventListener("blur", () => setTimeout(close, 120));
  input.addEventListener("keydown", (e) => {
    if (e.isComposing || e.keyCode === 229 || !mentionOpen) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      active = Math.min(active + 1, items.length - 1);
      render();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      active = Math.max(active - 1, 0);
      render();
    } else if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault();
      insert(items[active]);
    } else if (e.key === "Escape") {
      e.preventDefault();
      close();
    }
  });
}