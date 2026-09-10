# Regression: CSS single source --nb-*, no legacy aliases.
defmodule Newbee.Web.CssSingleSourceTest do
  use ExUnit.Case, async: false
  @legacy ~r/var\(--(bg2?|fg2?|accent|border)\)/
  test "app.js has no legacy refs" do
    {:ok, js} = File.read("priv/web/app.js")
    assert Regex.scan(@legacy, js) == []
  end

  test "style.css has no legacy refs and single root" do
    {:ok, css} = File.read("priv/web/style.css")
    assert Regex.scan(@legacy, css) == []
    assert length(Regex.scan(~r/:root\s*\{/, css)) == 1
  end

  test "all var refs defined" do
    {:ok, css} = File.read("priv/web/style.css")
    {:ok, js} = File.read("priv/web/app.js")
    defs = Regex.scan(~r/--([a-zA-Z0-9-]+)\s*:/, css) |> Enum.map(fn [_, n] -> n end) |> MapSet.new()

    refs =
      (Regex.scan(~r/var\(--([a-zA-Z0-9-]+)\)/, css) ++ Regex.scan(~r/var\(--([a-zA-Z0-9-]+)\)/, js))
      |> Enum.map(fn [_, n] -> n end)
      |> MapSet.new()

    assert MapSet.to_list(MapSet.difference(refs, defs)) == []
  end

  test "swipe rows cannot shrink out of the scrollable session list" do
    css = File.read!("priv/web/style.css")
    assert Regex.match?(~r/\.swipe-cell\s*\{[^}]*flex-shrink:\s*0\s*;/, css)
  end

  # 回归：会话列表是 flex column + overflow:auto，整块子项默认 flex-shrink:1
  # 会被压成 2px（只剩边框），工作组标题与成员行全部被 overflow:hidden 裁掉。
  test "block-level list children cannot shrink inside the scrollable session list" do
    css = File.read!("priv/web/style.css")

    for selector <- [
          ".session-group",
          ".session-group-label",
          ".xgroup-empty",
          ".session-empty"
        ] do
      assert Regex.match?(
               ~r/#session-list > #{Regex.escape(selector)}[^{}]*\{[^}]*flex:\s*none\s*;/,
               css
             ),
             "#{selector} 缺少 #session-list > … { flex: none }，会被 flex 压扁"
    end
  end

  test "swipe foreground covers delete actions until translated" do
    css = File.read!("priv/web/style.css")
    assert [_, foreground] = Regex.run(~r/\.swipe-cell \.session-item\s*\{([^}]*)\}/, css)
    assert foreground =~ "z-index: 1;"
    assert foreground =~ "background: var(--nb-bg-panel);"
    assert foreground =~ "position: relative;"
  end

  test "terminal and scrollbars follow the active color theme" do
    css = File.read!("priv/web/style.css")
    js = File.read!("priv/web/app.js")

    assert css =~ "--terminal-bg: #0b0f14;"
    assert css =~ ~r/\[data-theme="light"\] \.terminal-panel \{[^}]*--terminal-bg: #ffffff;/s
    assert css =~ "*::-webkit-scrollbar-thumb"
    assert css =~ "background: var(--nb-scrollbar-thumb) content-box;"
    assert css =~ "scrollbar-color: var(--nb-scrollbar-thumb) var(--terminal-scrollbar-track);"
    assert js =~ "getPropertyValue(name)"
    assert js =~ "terminal.term.options.theme = terminalTheme()"
    assert js =~ "const ansi = light"
  end

  # app.js 是 ~8.6k 行手写大文件：字符串匹配断言抓不到括号错位这类语法问题
  # （曾经在插入 doneBubble 时吃掉 addAssistantChrome 的收尾 `}`，只有浏览器里才暴露）。
  # 这里用真正的 JS 打包器解析一遍（`bun build` 会完整解析；
  # 注意 `new Function(src)` 是惰性解析，抓不到这类错误）；
  # 没有可用解析器时跳过（不阻塞无 bun 的环境）。
  test "web JS parses as valid JavaScript" do
    bun = System.find_executable("bun") || "/home/alanx/.bun/bin/bun"

    if File.exists?(bun) do
      out = Path.join(System.tmp_dir!(), "newbee-js-parse-check.js")

      for rel <- ["priv/web/app.js", "priv/web/theme.js"] do
        path = Path.expand(rel)
        assert File.exists?(path), "#{rel} 不存在"

        {msg, code} =
          System.cmd(bun, ["build", path, "--target", "browser", "--outfile", out], stderr_to_stdout: true)

        File.rm(out)
        assert code == 0, "#{rel} 不是合法 JavaScript：\n#{msg}"
      end
    end
  end

  # 回归：最终交付（done）曾经走纯文本总结卡渲染路径，既没有气泡也没有复制按钮，
  # 与助手回复不一致。现在所有 done 出口都必须经过 doneBubble/2。
  test "every done message renders as a boxed bubble with copy chrome" do
    js = File.read!("priv/web/app.js")

    # doneBubble 必须挂上复制外壳与原始 markdown（供 ⧉ 复制整条）
    assert js =~ "function doneBubble(text, createdAt)"
    assert js =~ "addAssistantChrome(d)"
    assert js =~ "d.dataset.raw = text || \"\""

    # 不允许其它地方再裸调 line("done", ...)（会退回无气泡/无复制的旧路径）；
    # doneBubble 自身那一处是唯一合法出口。
    [_, after_def] = String.split(js, "function doneBubble(text, createdAt)", parts: 2)
    [body, rest] = String.split(after_def, "\n  }", parts: 2)
    assert body =~ ~r/\bline\("done",/
    assert body =~ "addAssistantChrome(d)"
    assert Regex.scan(~r/\bline\("done",/, rest) == []
    assert Regex.scan(~r/\bline\("done",/, rest) == []
  end
end
