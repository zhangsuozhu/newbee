# 模型选择器「刷新」保留当前浏览位置（浏览器轮次 R780 取证）：
#   FIX#17：点刷新原先是 openModels() 重建列表，pending/currentProvider 回到已保存模型
#           （保存的厂家不在配置里时回落列表第一个），搜索词也被清空——用户看到「刷新跳到第一个厂商」。
#           现在刷新把当前厂家 / 高亮模型 / 搜索词作为 keep 传回 openModels：
#             * keep 的厂家仍在配置里就保持选中，否则回退已保存厂家、再回退第一个；
#             * 高亮沿用 keep 的模型，初次打开仍按已保存模型预选；
#             * 搜索词沿用，当前厂家 / 高亮模型滚动回视野。
#           浏览器轮次 R780（真实 DOM + 真实源码，真源码抓取后抽取 openModels 执行）：
#             * 基线（修复前 app.js）：浏览第 2 个厂家 → 刷新 → 高亮跳回第 1 个厂家 zhipu，
#               搜索词清空、新拉取的模型不显示、确定提交的还是 zhipu/deepseek-flash（bug 复现）；
#             * 首版补丁：初次打开 keep=undefined 时 `keep.model` 直接抛 TypeError（选择器开不出来），
#               加 keep 判空后复测全绿：仍停在第 2 个厂家，新模型可见，确定提交 guoyu-grok/grok-4.7；
#             * 只浏览厂家不选模型：刷新不产生凭空高亮，确定仍提交已保存模型（与旧行为一致）。
defmodule Newbee.Web.ModelPickerRefreshTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "FIX#17 刷新保留当前厂家/高亮模型/搜索词", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "async function openModels(keep)"))
    assert i != nil

    # 窗口要覆盖到厂家渲染段（高亮 class 在函数中部，OpenModels 头部有 20+ 行注释）
    body = ctx.js |> String.split("\n") |> Enum.drop(i) |> Enum.take(60) |> Enum.join("\n")

    # keep 的厂家优先，其次已保存厂家，再次第一个；空厂家（无模型）不参与
    assert body =~ "const usable = (x) => !!(x && x.name && (x.models || []).length);"
    assert body =~ "const keepProv = keep ? rendered.find((x) => x.name === keep.provider) : null;"
    assert body =~ "const targetProv = keepProv || rendered.find((x) => x.name === curProvider) || rendered[0];"
    # 高亮跟随 currentProvider（而非固定 curProvider），并记住当前厂家条用于滚动
    assert body =~ "po.className = \"model-provider\" + (p.name === currentProvider ? \" current\" : \"\");"
    assert body =~ "if (p.name === currentProvider) currentPo = po;"

    # 初次打开才用已保存模型预选；带 keep 时沿用 keep.model（keep 必须判空，R780 首版就是漏判开不出选择器）
    assert body =~ "if (keep && modelIn(keepProv, keep.model)) return keep.model;"
    assert body =~ "if (!keep && modelIn(targetProv, curModel)) return curModel;"
  end

  test "FIX#17 刷新按钮把浏览态作为 keep 传回 openModels", ctx do
    refute ctx.js =~ "$(\"model-refresh\").onclick = () => openModels();"

    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "$(\"model-refresh\").onclick"))
    assert i != nil

    body = ctx.js |> String.split("\n") |> Enum.drop(i) |> Enum.take(8) |> Enum.join("\n")
    assert body =~ "openModels({"
    assert body =~ "provider: currentProvider,"
    assert body =~ "model: pending.provider === currentProvider ? pending.model : \"\","
    assert body =~ "query: searchInput ? searchInput.value : \"\","

    # 搜索框回填 keep 的搜索词（不再是每次清空）
    assert ctx.js =~ "searchInput.value = keepQuery;"
    # 打开入口不把 click 事件当成 keep 参数
    assert ctx.js =~ "$(\"model-label\").onclick = () => openModels();"
  end
end
