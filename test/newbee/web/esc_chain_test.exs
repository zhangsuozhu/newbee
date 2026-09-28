# FIX#20 普通模式 Esc 链（浏览器轮次 R845→R854 迭代取证）：
#   ① 原面板/弹窗 Esc 只写在 initEmbedPanels 里且被 !embedMode() 挡住 → 普通模式
#      R845 实测 目录弹窗/扫码浮层/终端/MC 四项按 Esc 全无反应（after=true）。
#   ② 终端聚焦时 xterm 在 target 上 stopPropagation → 冒泡段收不到：
#      R852 实测 capture 计数=1 而链条 acted=null，必须把整条链移到捕获段。
#   ③ 弹窗内焦点在输入字段时不关窗（模型搜索 Esc 清空等局部行为要保留）。
#   复测：R853/R854/R855/R856 五项全绿（含终端 acted="terminal"）。
defmodule Newbee.Web.EscChainTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "Esc 链在捕获阶段注册，含弹窗/扫码浮层/MC/终端与中断兜底", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "Esc 统一走捕获阶段"))
    assert i != nil, "应有捕获阶段 Esc 处理器注释"

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(70)
      |> Enum.join("\n")

    assert body =~ "}, true);", "必须以捕获阶段注册（终端 xterm 会 stopPropagation）"
    assert body =~ "closeQuickAccess();"
    assert body =~ "setMCOpen(false);"
    assert body =~ "const tc = $(\"terminal-close\");"
    assert body =~ "interrupt();"
    assert body =~ "xterm-helper-textarea", "要识别 xterm 焦点"
    assert body =~ "const inField =", "弹窗内字段聚焦时不关窗"
    assert body =~ "button[id$='-cancel'], button[id$='-close']"
    assert body =~ "window.__escChainActed"
  end

  test "冒泡段只放行非 Escape 键（避免与捕获段重复处理）", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "function initGlobalKeys()"))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(140)
      |> Enum.join("\n")

    assert body =~ "if (e.key === \"Escape\") return;", "冒泡段应跳过 Escape"
    assert body =~ "if (modalOpen) return;"
  end
end
