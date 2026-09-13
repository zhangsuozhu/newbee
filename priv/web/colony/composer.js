// 蜂群前端 · 输入区（与主界面同款）：附件上传 / 拖拽 / 粘贴、思考强度、待验收条、发往哪里
import { esc, fmtBytes, kindLabel } from "./util.js";
import { state, currentBeeId, currentTaskId, memberById, resetToChat } from "./store.js";
import { rpc, toast } from "./api.js";
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
    ['◔', '进度', '', () => send(ctx, '进度')],
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
  if (state.token) headers.authorization = "Bearer " + state.token;
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
  if (state.token) headers.authorization = "Bearer " + state.token;
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
    pause.hidden = !show;
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
    else if (bee) hint.textContent = `发给 ${bee.display}`;
    else hint.textContent = "发到群聊";
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
  input.value = text;
  state.draft = text;
  autosize(input);
  input.focus();
  input.setSelectionRange(text.length, text.length);
}

function autosize(input) {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 160) + "px";
}

export async function send(ctx, text) {
  text = (text || "").trim();
  const uploadIds = state.attachments.map((a) => a.id);
  if (!text && !uploadIds.length) return;
  if (state.uploading > 0) {
    toast("请等待文件上传完成", true);
    return;
  }

  const payload = { colonyId: state.colonyId, text, requestId:crypto.randomUUID(), uploadSid:state.uploadSid };
  if (send.sending) return;
  send.sending = true;
  const beeId = currentBeeId();
  const taskId = currentTaskId();
  if (beeId) payload.context = { beeId };
  else if (taskId) payload.context = { taskId };
  if (uploadIds.length) payload.uploadIds = uploadIds;

  try {
    const res = await rpc("colony.say", payload);
    send.sending = false;
    state.draft = "";
    const input = document.getElementById("input");
    if (input) {
      input.value = "";
      autosize(input);
    }
    clearAttachments(false);
    for (const a of res.actions || []) {
      if (a.type === "switch" && a.colony_id) ctx.switchColony(a.colony_id);
    }
    if (res.reply) toast(res.reply.length > 60 ? "它回了话，见消息流" : res.reply);
    await ctx.refreshNow();
  } catch (e) {
    send.sending = false;
    toast(e.message || "发送失败", true);
  }
}

// ── 待验收条：沿用主界面 .permission-bar ──
export function updateReviewBar() {
  const bar = document.getElementById("review-bar");
  if (!bar) return;
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
  document.getElementById("review-go").onclick = () => {
    resetToChat();
    setTimeout(() => {
      const card = document.querySelector("[data-honey-pending]");
      if (card) card.scrollIntoView({ block: "center", behavior: "smooth" });
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
    if (!mentionOpen) return;
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