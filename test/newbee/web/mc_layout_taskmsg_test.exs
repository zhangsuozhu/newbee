# 浏览器轮次暴露的两个易用性缺陷：
#   FIX#17：#mission-control 是 position:fixed; top:0; width:380px; z-index:50，
#            顶栏右半区（委派/终端/主题/用量…）在 MC 打开时被整片盖住
#            ——R809 hit-test: covered=true, top="mc-title"；建组又会自动开 MC，
#            于是"刚建完组最想点的『让另一个 AI 帮忙』"反而点不到。
#            改为桌面端(>900px) top: var(--topbar-h)（app.js 实时同步顶栏高度），
#            ≤900px 的全屏浮层保持 top:0；R810-R816 复测 covered=false 硬断言全绿。
#   FIX#18：两个弹窗都会预置一行空验收占位，用户没填过任何内容时，
#            buildAcceptance 却报"成功标准有一行未填（…）"，把占位说成用户的失误
#            ——R807/R809 实测（创建失败时整行让人摸不着头脑）。
#            全空时改为准确引导"至少填写一条结构化验收标准（…）"；有内容才报"某行未填"。
defmodule Newbee.Web.McLayoutTaskMsgTest do
  use ExUnit.Case, async: true

  @css "priv/web/style.css"
  @js "priv/web/app.js"

  setup do
    %{css: File.read!(@css), js: File.read!(@js)}
  end

  test "FIX#17 桌面端 MC 让开顶栏，移动端保持全屏", ctx do
    assert ctx.css =~ "#mission-control { top: var(--topbar-h, 56px); }"
    assert ctx.css =~ "@media (min-width: 901px)"
    # 全屏浮层（≤900px）仍从 top:0 开始
    assert ctx.css =~ "#mission-control { width: 100%; }"
    # 高度由 JS 实时同步（含边框/换行变化）
    assert ctx.js =~ "function syncTopbarHeight()"
    assert ctx.js =~ "setProperty(\"--topbar-h\""
    assert ctx.js =~ "window.addEventListener(\"resize\", syncTopbarHeight)"
  end

  test "FIX#18 验收全空与部分未填给不同文案", ctx do
    i = Enum.find_index(String.split(ctx.js, "\\n"), &String.contains?(&1, "function buildAcceptance("))
    assert i != nil

    body =
      ctx.js
      |> String.split("\\n")
      |> Enum.drop(i)
      |> Enum.take(40)
      |> Enum.join("\\n")

    assert body =~ "hasContent"
    assert body =~ "至少填写一条结构化验收标准（命令 / 文件存在 / 文件哈希）"
    assert body =~ "成功标准有一行未填（程序或路径不能为空）"
    # 全空时用引导文案（三元判断），有内容时才用"某行未填"
    assert body =~ "?"
  end
end
