// 蜂群前端 · RPC 客户端（复用现有 /api RPC-over-HTTP 信封）
import { $ } from "./util.js";

const TOKEN_KEY = "newbee.token";
const MEMBER_TOKEN_KEY = "newbee.member_token";

export function isMemberSession() {
  try { return localStorage.getItem(MEMBER_TOKEN_KEY) === "1"; } catch (_) { return false; }
}

export function markMemberSession() {
  try { localStorage.setItem(MEMBER_TOKEN_KEY, "1"); } catch (_) {}
}

function clearMemberSession() {
  try { localStorage.removeItem(MEMBER_TOKEN_KEY); } catch (_) {}
}

// 单一令牌来源：RPC 与直连 fetch（附件上传/删除）必须用同一份，否则远程模式下
// RPC 带着 Bearer 正常、/api/upload 不带就 401「未登录或会话已过期」。
export function authToken() {
  const fromUrl = new URLSearchParams(location.search).get("token");
  if (fromUrl) {
    try { localStorage.setItem(TOKEN_KEY, fromUrl); } catch (_) {}
    return fromUrl;
  }
  try { return localStorage.getItem(TOKEN_KEY) || ""; } catch (_) { return ""; }
}
// 清除失效令牌（令牌被服务端拒绝时调用）。
// 同时抹掉 URL 上的 ?token=：否则 authToken() 每次都会把那个坏令牌又存回来。
export function forgetAuthToken() {
  try { localStorage.removeItem(TOKEN_KEY); } catch (_) {}
  clearMemberSession();
  try {
    const url = new URL(location.href);
    if (url.searchParams.has("token")) {
      url.searchParams.delete("token");
      history.replaceState(null, "", url.pathname + url.search + url.hash);
    }
  } catch (_) {}
}
export async function rpc(method, payload = {}, {timeoutMs = 30000} = {}) {
  const headers = { "Content-Type": "application/json" };
  const t = authToken();
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
    // 宿主令牌失效时本地模式可回到匿名访问；成员令牌不能清掉，否则下一次请求会伪装成 Queen。
    if (result.error.code === "unauthorized" && !isMemberSession()) forgetAuthToken();
    const err = new Error(result.error.message || result.error.code);
    err.code = result.error.code;
    throw err;
  }
  const value = result.ok;
  if (method === "auth.status") {
    if (value?.host_owner === false) markMemberSession();
    else if (value?.host_owner === true || !t) clearMemberSession();
  }
  return value;
}

export function toast(message, isError = false) {
  const box = $("#colony-toast");
  if (!box) return;
  box.hidden = false;
  box.setAttribute('role', isError ? 'alert' : 'status');
  box.setAttribute('aria-live', isError ? 'assertive' : 'polite');
  box.textContent = message;
  box.className = `colony-toast${isError ? ' bad' : ''}`;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { box.hidden = true; }, isError ? 8000 : 4000);
}
