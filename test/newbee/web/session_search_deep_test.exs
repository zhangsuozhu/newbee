defmodule Newbee.Web.SessionSearchDeepTest do
  @moduledoc """
  会话搜索必须能搜到「未加载」的老会话。

  现场证据（浏览器轮次 R605/R606 修复前、R610/R611 修复后）：搜索是纯前端过滤，只匹配
  已加载的 state.allSessions（初始50 条）；服务端 total=77/78 时，第51 条之后的老会话输入
  关键词直接 matches=0（UI 显示「查无此会话」），用户不知道还有未加载的页。
  修法：有关键词时按需补页（命中即停、每次最多6 页、用序号丢弃过期输入）。
  """
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "输入关键词会触发补页加载", %{js: js} do
    assert js =~ "async function loadSessionsForFilter(maxPages)"
    assert js =~ "if (sessionFilter.trim()) {"
    assert js =~ "try { loadSessionsForFilter(6); } catch (err) {}"
    # 命中即停 / 已到末页即停，避免每次输入都全量拉取
    assert js =~ "if (hit) return;"
    assert js =~ "if ((state.allSessions || []).length >= total) return;"
  end

  test "补页循环有过期输入守卫（连打字不并发拉取）", %{js: js} do
    assert js =~ "let sessionFilterLoadSeq = 0;"
    assert js =~ "const seq = ++sessionFilterLoadSeq;"
    assert js =~ "if (seq !== sessionFilterLoadSeq) return;"
    # 输入处理器先作废旧循环
    assert js =~ "sessionFilterLoadSeq++;"
  end

  test "过滤谓词仍同时匹配显示标题与 id", %{js: js} do
    assert js =~
             "const visible = (s) => !kw || sessionDisplayTitle(s).toLowerCase().includes(kw) || String(s.id).toLowerCase().includes(kw);"
  end
end
