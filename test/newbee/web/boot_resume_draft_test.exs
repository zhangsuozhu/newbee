# FIX#19 启动不认 localStorage 会话（浏览器轮次 R828-R830 取证）：
#   bootApp() 只看 URL 的 ?session=，没有就 newSession() ——
#   ① restoreDraft 注释写明"刷新/切会话后恢复未发送的文字"，但普通刷新从不走 resume()，
#      草稿永远丢（实测：刷新前后 sid 必变、samples 恒空、旧草稿键留在 localStorage）；
#   ② 每次 F5 都往侧栏塞一个空会话（loadmore 场景里成堆的空会话即由此而来）。
#   改为 resumeSid = URL 参数 ?? localStorage.newbee.sid，resume 失败再新建；
#   R831/R832 复测：sid_same=true、草稿在轮询窗口恢复、清空后键被删。
defmodule Newbee.Web.BootResumeDraftTest do
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "启动回退到 localStorage 会话，失败才新建", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "const resumeSid ="))
    assert i != nil, "bootApp 应有 resumeSid 回退"

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(8)
      |> Enum.join("\n")

    assert body =~ "localStorage.getItem(\"newbee.sid\")"
    assert body =~ "try { await resume(resumeSid); }"
    assert body =~ "catch (e) { try { await newSession(); }"
    assert body =~ "} else await newSession();"
    # 取证轮次留档
    assert ctx.js =~ "R828-R830"
  end

  test "resume 内先写 state.sid 再 restoreDraft（顺序反了读不到草稿键）", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "async function resume(sid)"))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(50)
      |> Enum.join("\n")

    pos = fn hay, needle ->
      case :binary.match(hay, needle) do
        {i, _len} -> i
        :nomatch -> nil
      end
    end

    i_sid = pos.(body, "state.sid = sid;")
    i_draft = pos.(body, "restoreDraft();")
    assert i_sid != nil, "resume 应先设置 state.sid"
    assert i_draft != nil, "resume 应调用 restoreDraft"
    assert i_sid < i_draft, "赋值必须在恢复草稿之前"
  end

  test "resume 在断开 WebSocket 前发送 terminal_close（避免旧 PTY 残留）", ctx do
    i = Enum.find_index(String.split(ctx.js, "\n"), &String.contains?(&1, "async function resume(sid)"))
    assert i != nil

    body =
      ctx.js
      |> String.split("\n")
      |> Enum.drop(i)
      |> Enum.take(20)
      |> Enum.join("\n")

    pos = fn hay, needle ->
      case :binary.match(hay, needle) do
        {i, _len} -> i
        :nomatch -> nil
      end
    end

    i_close = pos.(body, "closeTerminal(true);")
    i_disconnect = pos.(body, "disconnectSocket();")
    assert i_close != nil, "resume 应显式关闭旧终端"
    assert i_disconnect != nil, "resume 应断开旧 WebSocket"
    assert i_close < i_disconnect, "必须先发 terminal_close 再断开，否则关闭帧会被丢弃"
  end
end
