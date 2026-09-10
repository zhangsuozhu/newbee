# 手机端底部：详细信息默认收起、输入框贴底、上滑查看详情。
defmodule Newbee.Web.MobileComposerTest do
  use ExUnit.Case, async: true

  @index "priv/web/index.html"
  @css "priv/web/style.css"
  @js "priv/web/app.js"

  setup do
    %{
      index: File.read!(@index),
      css: File.read!(@css),
      js: File.read!(@js)
    }
  end

  test "the stats bar lives inside a collapsible mobile details drawer", %{index: index} do
    assert index =~ ~s(id="mobile-details" class="mobile-details")
    assert index =~ ~s(id="mobile-details-handle")

    drawer = Regex.run(~r/<div id="mobile-details".*?<\/div>\s*<\/footer>/s, index) |> List.last()
    assert drawer =~ ~s(id="statsbar"), "statsbar should be inside the drawer"
    assert drawer =~ ~s(aria-expanded="false"), "drawer starts collapsed"
  end

  test "desktop keeps the handle hidden; mobile collapses the drawer and pins the composer",
       %{css: css} do
    {hide_at, _} = :binary.match(css, ".mobile-details-handle { display: none; }")
    {show_at, _} = :binary.match(css, ".mobile-details-handle {\n    display: flex;")

    assert hide_at < show_at,
           "the desktop hide rule must precede the mobile rule, otherwise the cascade hides the handle"

    assert Regex.match?(~r/\.mobile-details \{ order: 1; overflow: hidden; max-height: 0;/, css)
    assert Regex.match?(~r/\.mobile-details\.open \{ max-height: 168px; \}/, css)
    assert Regex.match?(~r/\.composer-card \{ order: 3; \}/, css)
    assert Regex.match?(~r/#composer \{ display: flex; flex-direction: column; \}/, css)
  end

  test "the drawer opens by drag or tap, and only on mobile", %{js: js} do
    block = Regex.run(~r/mobile-details-handle'\);(?s).*?\n  \}\)\(\);/x, js) |> List.last()
    assert block =~ "pointerdown"
    assert block =~ "pointermove"
    assert block =~ "pointerup"
    assert block =~ "isMobile()"
    assert block =~ "setOpen("
    assert block =~ "OPEN_H"
  end
end
