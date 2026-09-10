defmodule Newbee.Web.NeumorphicThemeTest do
  @moduledoc """
  Regression for the optional neumorphic themes.

  The WebUI ships four styles: the original dark/light plus light and dark
  neumorphic. Every component that draws its own surface must therefore get a
  neumorphic treatment, while the original themes must stay untouched.
  """
  use ExUnit.Case, async: false

  @index "priv/web/index.html"
  @pair "priv/web/pair.html.eex"
  @css "priv/web/style.css"
  @theme_js "priv/web/theme.js"
  @themes ~w(neumorphic neumorphic-dark)
  @marker "/* Optional soft surfaces."

  # Deliberate exceptions: pixel content, invisible hit areas, state suffixes.
  @shadow_exceptions ~w(nb-lightbox session-select mine)

  # Component families that must render with the soft-surface material.
  @required_material ~w(
    #sidebar #topbar #mission-control .modal-box .login-box .pair-card .composer-card
    .msg-user .msg-assistant .msg-tool .msg-ask .msg-media .msg-archive .queue-bar
    .permission-bar .session-item .group-member .group-task .collab-task .collab-message
    .evo-change .evo-intro .mc-step .debug-item .webauthn-cred-item
    .btn-primary .btn-ghost .icon-btn .xg-btn .ask-btn .ask-send .terminal-send .btn-retry
    .btn-steer .btn-tool-copy .pair-refresh .pair-deny .collab-dep-chip .evo-explain
    .group-task-claim .mc-action-btn .theme-picker .theme-menu .mcfg-box .mcfg-pitem .mcfg-model-row
    .file-viewer-box .file-viewer-mode.current .terminal-panel .ctx-menu .at-dropdown
    .effort-segments .model-opt.current .model-provider.current .xg-dev.mine
  )

  setup_all do
    %{
      css: File.read!(@css),
      index: File.read!(@index),
      pair: File.read!(@pair),
      scope: File.read!(@css) |> String.split(@marker, parts: 2) |> List.last()
    }
  end

  test "both neumorphic themes are opt-in and the original themes survive", %{css: css} do
    for theme <- @themes, do: assert(css =~ ~s([data-theme="#{theme}"]))
    assert css =~ ~r/\[data-theme="light"\]\s*\{/
    assert css =~ ~r/:root\s*\{/
  end

  test "each theme defines its colors and the shared material defines the geometry",
       %{scope: scope} do
    colors =
      ~w(--nb-bg --nb-bg-panel --nb-bg-elev --nb-border --nb-label-1 --nb-label-2
         --nb-label-3 --nb-label-caption --nb-accent --nb-neu-shadow --nb-neu-light
         --nb-neu-plate
         --nb-neu-warm --nb-neu-warm-ink)

    geometry = ~w(--nb-neu-raised --nb-neu-small --nb-neu-inset)

    for theme <- @themes do
      block = Regex.run(~r/\[data-theme="#{theme}"\]\s*\{(.*?)\n\}/s, scope) |> List.last()
      for token <- colors, do: assert(block =~ token, "#{theme} is missing #{token}")
    end

    for token <- geometry, do: assert(scope =~ token, "shared material is missing #{token}")
  end

  test "the picker offers all four styles on the app, login and phone pages",
       %{index: index, pair: pair} do
    for page <- [index, pair] do
      assert page =~ "/theme.js"
      assert page =~ "data-theme-picker"

      for theme <- @themes ++ ~w(dark light) do
        assert page =~ ~s(value="#{theme}"), "missing option #{theme}"
      end
    end
  end

  test "the topbar uses a compact accessible icon menu instead of a native select", %{index: index} do
    assert index =~ ~s(id="theme-toggle" class="icon-btn theme-icon-btn")
    assert index =~ ~s(data-theme-button)
    assert index =~ ~s(aria-haspopup="menu")
    assert index =~ ~s(id="theme-menu")
    refute index =~ ~r/<select id="theme-toggle"/
  end

  test "theme.js owns persistence, pre-paint apply and unknown-value fallback" do
    js = File.read!(@theme_js)
    assert js =~ "newbee.theme"
    assert js =~ "neumorphic-dark"
    assert js =~ "prefers-color-scheme"
    assert js =~ "document.documentElement.dataset.theme"
    assert js =~ "aria-checked"
    assert js =~ "placeMenu"
  end

  test "required component families carry the neumorphic material", %{scope: scope} do
    missing = Enum.reject(@required_material, &(scope =~ &1))
    assert missing == [], "missing neumorphic material for: #{inspect(missing)}"
  end

  test "components that draw a shadow in the base theme are covered too", %{css: css, scope: scope} do
    classes =
      Regex.scan(~r/([^{}]+)\{([^{}]*)\}/s, String.split(css, @marker, parts: 2) |> hd())
      |> Enum.flat_map(fn [_, selector, declarations] ->
        if declarations =~ ~r/box-shadow\s*:/ and not (declarations =~ ~r/box-shadow\s*:\s*none/) do
          Regex.scan(~r/\.([a-zA-Z][\w-]*)/, selector) |> Enum.map(fn [_, class] -> class end)
        else
          []
        end
      end)
      |> Enum.uniq()

    missing =
      Enum.reject(classes, fn class ->
        scope =~ ~r/\.#{Regex.escape(class)}(?![-\w])/ or class in @shadow_exceptions
      end)

    assert missing == [], "shadowed components without neumorphic styling: #{inspect(missing)}"
  end


  test "the polished sidebar uses icon QR, linear rows, a current marker and soft checkboxes",
       %{css: css, index: index, scope: scope} do
    app = File.read!("priv/web/app.js")

    assert index =~ ~s(id="qa-show" class="icon-btn qa-icon-btn")
    refute index =~ ">手机扫码<"
    assert app =~ "session-current-mark"
    assert scope =~ ".swipe-cell .session-item"
    assert scope =~ "border-bottom"
    assert scope =~ ".session-select-mark"
    assert scope =~ ~s(content: "✓")
    assert scope =~ ".sidebar-foot .logout-btn"
    assert scope =~ "align-self: flex-end"

    assert app =~ ~s(mkEmptyBtn("建群", "建一个项目协作群", "")
    assert app =~ ~s(mkEmptyBtn("加群", "用加群码加入协作群", "")
    assert index =~ "允许群主完全控制本机"
    refute index =~ "接受完全控制（群主可在本机执行任意代码和系统命令）"
    assert index =~ "xg-check-mark"
    assert index =~ ~s(id="new-session" class="icon-btn new-session-icon")
    assert css =~ ".session-tools"
    assert css =~ ~r/\.session-tools #new-session\s*\{[^}]*border-radius:\s*50%/s

    assert scope =~ ".group-modal-fields .xg-check"
    assert scope =~ "border-radius: 8px"
    assert scope =~ "backdrop-filter: none"
    assert index =~ ~s(class="ico stop-icon")
    assert scope =~ "#interrupt.btn-icon-round"
    assert scope =~ "fill: var(--nb-red)"
  end

  test "swipe delete stays hidden until one row is actively swiped", %{css: css} do
    app = File.read!("priv/web/app.js")

    assert css =~ ~r/\.swipe-cell \.swipe-actions\s*\{[^}]*visibility:\s*hidden/s
    assert css =~ ~r/\.swipe-cell \.swipe-actions\s*\{[^}]*pointer-events:\s*none/s
    assert css =~ ~s(.swipe-cell[data-swipe-active="1"] .swipe-actions)
    assert css =~ ~s(.swipe-cell[data-swipe-open="1"] .swipe-actions)
    assert app =~ ~s(wrap.dataset.swipeActive = "1")
    assert app =~ "delete wrap.dataset.swipeActive"
    assert app =~ "delete wrap.dataset.swipeOpen"
  end
  test "semantic status colors are not frozen to one theme", %{scope: scope} do
    refute scope =~
             ~r/\.(mc-file-added|mc-file-deleted|login-error|pair-msg)[^{]*\{[^}]*#[0-9a-fA-F]{3,6}/
  end
end
