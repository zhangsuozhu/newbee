defmodule Newbee.Web.ModelConfigUiTest do
  use ExUnit.Case, async: true

  test "workspace loads the hierarchical catalog editor" do
    html = File.read!("priv/web/workspace.html")
    js = File.read!("priv/web/model-catalog.js")
    assert html =~ "/model-catalog.js"

    for value <- ~w(llm.catalogConfig llm.saveCatalog llm.catalogModels openai-completions openai-responses anthropic),
        do: assert(js =~ value)

    # 厂家级 TLS：自签 / 私有 CA 网关的三个字段都要能在编辑器里配置，
    # 且「从此分组导入模型」必须带上未保存的 tls 草稿。
    for value <- ~w(catalog-tls-ca catalog-tls-skip catalog-tls-pin caFile insecureSkipVerify pinnedSha256),
        do: assert(js =~ value)

    assert js =~ "tls: v.tls,"
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
