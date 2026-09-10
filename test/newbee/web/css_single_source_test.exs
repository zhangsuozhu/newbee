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
end
