// 蜂群前端 · 通用工具（无依赖）
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

