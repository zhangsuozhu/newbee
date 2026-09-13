// 蜂群前端 · RPC 客户端（复用现有 /api RPC-over-HTTP 信封）
import { $ } from "./util.js";

const TOKEN_KEY = "newbee.token";

function token() {
  const fromUrl = new URLSearchParams(location.search).get("token");
  if (fromUrl) {
    try { localStorage.setItem(TOKEN_KEY, fromUrl); } catch (_) {}
    return fromUrl;
  }
  try { return localStorage.getItem(TOKEN_KEY) || ""; } catch (_) { return ""; }
}

export async function rpc(method, payload = {}, {timeoutMs = 30000} = {}) {
  const headers = { "Content-Type": "application/json" };
  const t = token();
  if (t) headers["Authorization"] = `Bearer ${t}`;

  const res = await fetch(`/api/${encodeURIComponent(method)}`, {
    method: "POST",
    signal: AbortSignal.timeout(timeoutMs),
    headers,
    body: JSON.stringify({ rpcId: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, method, payload }),
  }).catch(error => {
    if (error.name === 'TimeoutError' || error.name === 'AbortError') throw new Error('请求超时；结果可能已处理，请刷新确认后再操作');
    throw error;
  });

  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = await res.json();
  const result = body && body.result;
  if (!result) throw new Error("返回信封无效");
  if (result.error) {
    const err = new Error(result.error.message || result.error.code);
    err.code = result.error.code;
    throw err;
  }
  return result.ok;
}

export function toast(message, isError = false) {
  const box = $("#colony-toast");
  if (!box) return;
  box.textContent = message;
  box.className = `colony-toast show${isError ? " error" : ""}`;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { box.className = "colony-toast"; }, 2600);
}
