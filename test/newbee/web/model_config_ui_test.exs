defmodule Newbee.Web.ModelConfigUiTest do
  use ExUnit.Case, async: true

  test "模型配置表单只生成规范 API 值并提交逐模型覆盖" do
    # AI 对话界面（含终端/模型配置）现在是工作区表面，蜂群主页只负责导航与工具入口。
    html = File.read!("priv/web/workspace.html")
    js = File.read!("priv/web/app.js")

    assert html =~ ~s(option value="openai-completions")
    assert html =~ ~s(option value="openai-responses")
    assert html =~ ~s(option value="auto")
    refute html =~ ~s(option value="responses")

    assert js =~ "modelApis: modelApis"
    assert js =~ "contextWindows: ctxw"
    assert js =~ "modelResponsesContinuations: modelRespCont"
    assert js =~ "mcfgCanonicalApi"
  end

  test "终端入口包含面板和 WebSocket 命令协议" do
    html = File.read!("priv/web/workspace.html")
    js = File.read!("priv/web/app.js")

    assert html =~ ~s|id="terminal-toggle"|
    assert html =~ ~s|id="terminal-panel"|
    assert html =~ ~s|id="terminal-screen"|
    assert html =~ ~s|id="terminal-fullscreen"|
    assert html =~ ~s|id="terminal-minimize"|
    assert html =~ "/vendor/xterm.js"
    assert html =~ ~s|id="terminal-input"|
    assert html =~ ~s|id="terminal-interrupt"|

    assert js =~ "terminal_open"
    assert js =~ "terminal_interrupt"
    assert js =~ "terminalInterrupt"

    assert js =~ "terminal_input"
    assert js =~ "terminal_resize"
    assert js =~ "requestFullscreen"
    assert js =~ "toggleTerminalMinimize"
    assert js =~ "is-minimized"
    assert js =~ "window.Terminal"
    assert js =~ "onTerminalFrame"
  end
end
