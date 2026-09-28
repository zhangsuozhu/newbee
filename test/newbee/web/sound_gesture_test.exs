defmodule Newbee.Web.SoundGestureTest do
  @moduledoc """
  提示音手势解锁的两条硬约束（均由浏览器轮次取证得到）：

  1. 没有用户手势前不得创建/恢复 AudioContext——否则 console 刷
     "AudioContext was not allowed to start" 且那次通知音丢失（修复前每轮6 条，R33/R34 归零）。
  2. 带 ctrl/meta/alt 的 keydown（如 mission 场景首个 Ctrl+M）在部分环境拿不到音频激活，
     会建出 suspended 上下文再刷告警（修复前 mission 轮次2-4 条，R574-R577 归零）。
  """
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "解锁走手势门控，并把手势前的通知音暂存补播", %{js: js} do
    assert js =~ "let soundUnlocked = false;"
    assert js =~ "let pendingSound = null;"
    assert js =~ "if (!soundUnlocked) { pendingSound = { kind: kind, at: now }; return; }"
    assert js =~ "document.addEventListener(\"pointerdown\", unlock)"
    assert js =~ "document.addEventListener(\"keydown\", unlock)"
    # 不再 once：被拦下后靠后续手势恢复
    refute js =~ "addEventListener(\"pointerdown\", unlock, { once: true })"
  end

  test "修饰键组合的 keydown 不参与解锁", %{js: js} do
    assert js =~ "if (e && e.type === \"keydown\" && (e.ctrlKey || e.metaKey || e.altKey)) return;"
  end

  test "ensureSoundCtx 只在解锁后创建，resume 只出现在手势回调里", %{js: js} do
    assert js =~ "if (!soundUnlocked) return null;"
    assert js =~ "if (soundCtx && soundCtx.state === \"suspended\") soundCtx.resume();"
  end
end
