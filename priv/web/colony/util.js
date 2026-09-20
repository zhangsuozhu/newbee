// 蜂群前端 · 通用工具。只依赖 api.js 的 toast 做失败反馈（api.js 只从本文件取 $，函数级引用不会成环）。
import { toast } from "./api.js";
export function $(sel, root = document) { return root.querySelector(sel); }
export function $$(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

export function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
    else if (v != null && v !== false) node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    if (c == null) continue;
    node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

export function fmtTime(ts) {
  if (!ts) return "";
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

export function fmtAgo(ts) {
  if (!ts) return "";
  const s = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (s < 10) return "刚刚";
  if (s < 60) return `${s} 秒前`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} 分钟前`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} 小时前`;
  return `${Math.floor(h / 24)} 天前`;
}

export function absTime(ts) {
  const d = new Date(ts || Date.now());
  return d.toLocaleString(undefined, { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

export function debounce(fn, ms = 200) {
  let t = null;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

export function sortByCreated(list) {
  return [...(list || [])].sort((a, b) => (a.created_at || 0) - (b.created_at || 0));
}

export function statusLabel(status) {
  const map = {
    pending: "待领取",
    claimed: "已领取",
    running: "进行中",
    blocked: "等待处理",
    pending_review: "待验收",
    done: "已完成",
    failed: "失败",
    cancelled: "已取消",
    idle: "空闲",
    working: "在干活",
    offline: "离线",
  };
  return map[status] || status || "";
}

export function kindLabel(kind) {
  return kind === "ai" ? "AI" : "人";
}

export function signalLabel(kind) {
  return {
    recommend: "摇摆舞·推荐",
    rebalance: "颤抖舞·减负",
    inhibit: "停止信号",
    report: "汇报",
    command: "指令",
    notify: "知会",
    escalate: "升级 Queen",
    handoff: "交接",
  }[kind] || kind;
}
export function fmtBytes(n) {
  if (n == null || isNaN(n)) return "";
  if (n < 1024) return n + " B";
  if (n < 1024 * 1024) return (n / 1024).toFixed(1).replace(/\.0$/, "") + " KB";
  return (n / 1024 / 1024).toFixed(1).replace(/\.0$/, "") + " MB";
}


// 卡片「更多」菜单：一个按钮 + 弹出项。全局只挂一次外部点击关闭，避免每张卡都加监听。
let cardMenuBound = false;
function bindCardMenuDismiss() {
  if (cardMenuBound) return;
  cardMenuBound = true;
  document.addEventListener("click", (event) => {
    document.querySelectorAll(".card-menu:not(.hidden)").forEach((pop) => {
      const trigger = pop.parentElement?.querySelector(".card-more");
      if (pop.contains(event.target) || trigger?.contains(event.target)) return;
      pop.classList.add("hidden");
      setTimeout(() => {
        if (trigger && document.body.contains(trigger) && !trigger.disabled && trigger.getClientRects().length) {
          trigger.focus({preventScroll: true});
        }
      }, 0);
    });
  });
  // 键盘用户：菜单打开后按 Esc 应该能关掉，并把焦点还给触发按钮
  // （其它浮层——弹窗、工作台层——都支持 Esc，这里原来只有鼠标点击能关）。
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    const open = Array.from(document.querySelectorAll(".card-menu:not(.hidden)"));
    if (!open.length) return;
    event.preventDefault();
    for (const pop of open) {
      pop.classList.add("hidden");
      const trigger = pop.parentElement && pop.parentElement.querySelector(".card-more");
      if (trigger) trigger.focus();
    }
  });
}

export function cardMenu(items, label = "更多 ▾") {
  bindCardMenuDismiss();
  const wrap = document.createElement("div");
  wrap.className = "card-menu-wrap";
  const btn = document.createElement("button");
  btn.type = "button"; btn.className = "btn-ghost card-more"; btn.textContent = label;
  btn.setAttribute("aria-haspopup", "true");
  const pop = document.createElement("div");
  pop.className = "card-menu hidden";
  for (const [text, fn] of items) {
    const item = document.createElement("button");
    item.type = "button"; item.className = "card-menu-item"; item.textContent = text;
    item.onclick = async () => {
      pop.classList.add("hidden");
      btn.focus({preventScroll: true});
      try {
        await fn();
      } catch (error) {
        console.error("[colony] menu action failed", error);
        toast(error.message || "操作失败，请重试", true);
      } finally {
        if (document.body.contains(btn) && !btn.hidden && btn.getClientRects().length && !btn.disabled) btn.focus({preventScroll: true});
      }
    };
    pop.appendChild(item);
  }
  btn.onclick = (event) => {
    event.stopPropagation();
    const opening = !pop.classList.toggle("hidden");
    if (!opening) return;
    pop.style.left = "";
    pop.style.right = "0";
    const margin = 8;
    const wrapRect = wrap.getBoundingClientRect();
    const menuWidth = pop.getBoundingClientRect().width;
    const viewportWidth = document.documentElement.clientWidth || innerWidth;
    if (wrapRect.left + menuWidth <= viewportWidth - margin) {
      pop.style.left = "0";
      pop.style.right = "auto";
    } else if (wrapRect.right - menuWidth >= margin) {
      pop.style.left = "auto";
      pop.style.right = "0";
    } else {
      pop.style.left = `${margin - wrapRect.left}px`;
      pop.style.right = "auto";
    }
  };
  wrap.append(btn, pop);
  return wrap;
}


// 复制到剪贴板：优先 Clipboard API；不安全上下文（例如 http://局域网IP 打开）里
// navigator.clipboard 不存在，退回 execCommand。两条路都失败必须如实返回 false——
// 以前是失败也显示「已复制」，用户以为复制成功，粘出来还是旧内容。
export async function copyToClipboard(text) {
  const value = String(text == null ? "" : text);
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(value);
      return true;
    }
  } catch (_) { /* 落到下面的兜底 */ }
  try {
    const ta = document.createElement("textarea");
    ta.value = value;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "-1000px";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    ta.remove();
    return ok;
  } catch (_) {
    return false;
  }
}

