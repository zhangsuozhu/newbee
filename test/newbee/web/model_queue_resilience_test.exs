# 模型选择器与队列栏的两处自愈（均由浏览器轮次取证）：
#   FIX#15a：openModels 的 await rpc 之前没有 try/catch，llm.models 一失败就是未处理 rejection
#            ——页面既不开窗也不提示，还刷 pageerror/console.error（R770 实测 ev 含 pageerror）；
#            加 try/catch 后 R773/R775/R778/R779 全绿且 flow 出现「加载模型列表失败: …」。
#   FIX#16：清空队列只发 WS+RPC 却忽略响应；服务端队列本就为空时（n=0）不广播 queue_updated，
#            于是点「清空队列」栏位8 秒不收（R774 实测 bar_hidden=false）；
#            改为以 RPC 响应同步 state.queue 后 R776/R777 bar_hidden=true。
defmodule Newbee.Web.ModelQueueResilienceTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "FIX#15a openModels 拉列表失败必须有反馈（不开静默）", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "async function openModels()"))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(22)
      |> Enum.join("\n")

    # 失败路径：try/catch + 明确错误文案 + 不再往下执行
    assert body =~ "try {"
    assert body =~ "rpc(\"llm.models\""
    assert body =~ "加载模型列表失败: "
    assert body =~ "请稍后重试"
    assert body =~ "return;"
    # 空态提示仍在（renderModels 里）
    assert ctx.js =~ "暂无可用模型"
  end

  test "FIX#16 清空队列以服务端响应为准同步栏位", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "async function clearQueueOnly()"))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(26)
      |> Enum.join("\n")

    assert body =~ "const res = await rpc(\"session.clearQueue\""
    assert body =~ "state.queue = (res && Array.isArray(res.queue)) ? res.queue : [];"
    assert body =~ "state.queueCurrent = null;"
    assert body =~ "renderQueue();"
    assert body =~ "清空队列失败"
  end
end
