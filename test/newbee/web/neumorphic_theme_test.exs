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
    .btn-danger .collab-filter-row button .collab-member .collab-group-status .collab-verify-badge
    .mc-file .queue-item .collab-verification .evo-guide .collab-write-conflicts .dir-entries
    .mcfg-plist .file-viewer-modes .md-code .mc-test-result .mc-step-detail .terminal-panel
    .evo-health-pill .evo-status-tag .collab-workspace-badge .attach-item .wc-item .xm-cap
    .ctx-chip .ctx-editor .group-status .dir-crumb .evo-layers-detail
    .md-copy .qa-show-btn .session-group-toggle .debug-detail .collab-review-diff .file-viewer-mode.current
    .menu-btn .msg-user-file .qa-top-text .evo-tech .media-download
    .media-body .media-text-markdown .media-text-source .attach-file-icon .md-inline
    .evo-approve .diff-owner .mc-file-owner .collab-accept-note
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

  test "login and phone pages carry no picker; the app menu still offers all four styles",
       %{index: index, pair: pair} do
    for page <- [index, pair] do
      assert page =~ "/theme.js"
      refute page =~ "data-theme-picker", "login/phone page should not offer a theme picker"
    end

    # 应用内仍保留紧凑图标菜单（见下一个测试），四个风格在菜单项里可选。
    assert index =~ ~s(data-theme-value="neumorphic-dark")
    refute pair =~ ~r/<select[^>]*data-theme-picker/
  end

  test "the topbar uses a compact accessible icon menu instead of a native select", %{index: index} do
    assert index =~ ~s(id="theme-toggle" class="icon-btn theme-icon-btn")
    assert index =~ ~s(data-theme-button)
    assert index =~ ~s(aria-haspopup="menu")
    assert index =~ ~s(id="theme-menu")
    refute index =~ ~r/<select id="theme-toggle"/
  end

  test "theme.js owns persistence, pre-paint apply, neumorphic default and unknown-value fallback" do
    js = File.read!(@theme_js)
    assert js =~ "newbee.theme"
    assert js =~ "neumorphic-dark"
    evalc = Regex.run(~r/function apply\(theme, persist = false\) \{(.*?)\n  \}/s, js) |> Enum.at(1)
    assert evalc =~ ~s(theme = "neumorphic"), "unknown values should fall back to 浅色拟物"
    init = Regex.run(~r/function init\(\) \{(.*?)\n  \}/s, js) |> Enum.at(1)

    assert init =~ ~s|apply(themes.includes(saved) ? saved : "neumorphic")|,
           "first visit should default to 浅色拟物"

    refute js =~ "prefers-color-scheme"
    assert js =~ "document.documentElement.dataset.theme"
    assert js =~ "aria-checked"
    assert js =~ "placeMenu"
  end

  test "required component families carry the neumorphic material", %{scope: scope} do
    missing = Enum.reject(@required_material, &(scope =~ &1))
    assert missing == [], "missing neumorphic material for: #{inspect(missing)}"
  end

  # 对话框/会话预览里的正文按用户要求保持纯文本：不做物化面板（凸起 + 高光让长句难读）。
  test "dialog and conversation-preview body text stays plain, not a raised plate", %{css: css} do
    plate_group =
      Regex.run(
        ~r/:where\(\.msg-user-file[^)]*\)\s*\{[^}]*box-shadow:\s*var\(--nb-neu-small\)/s,
        css
      )
      |> List.last()

    refute plate_group =~ ".modal-body"
    refute plate_group =~ ".xm-conv-body"
    refute plate_group =~ ".modal-body"
    refute plate_group =~ ".xm-conv-body"
  end

  # 影响小结同样是正文型文字（一句话风险摘要），按用户要求只留底色、不做材质。
  test "impact summary stays plain text in the neumorphic scope", %{css: css} do
    [_, neu_scope] = String.split(css, @marker, parts: 2)

    refute Regex.match?(
             ~r/:where\([^)]*\.mc-impact-summary[^)]*\)\s*\{[^}]*box-shadow:\s*var\(--nb-neu-/s,
             neu_scope
           ),
           "影响小结不应再套材质（凸起/内陷）"
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
    assert css =~ ".session-group .swipe-cell .session-item { border-bottom-color: transparent; }"
    assert css =~ ~r/\.session-tools #new-session\s*\{[^}]*border-radius:\s*50%/s

    assert scope =~ ".group-modal-fields .xg-check"
    assert scope =~ "border-radius: 8px"
    assert scope =~ "backdrop-filter: none"
    assert index =~ ~s(class="ico stop-icon")
    assert scope =~ "#interrupt.btn-icon-round"
    assert scope =~ "fill: var(--nb-red)"
  end

  test "mission control controls render with the soft material", %{scope: scope} do
    assert scope =~
             ~r/:is\(\[data-theme="neumorphic"\], \[data-theme="neumorphic-dark"\]\) \.collab-filter-row button \{/

    assert scope =~ ".collab-filter-row button:hover:not(.active)"
    assert scope =~ ".btn-danger:active:not(:disabled)"
    assert scope =~ ".collab-member.active"
    # 取消按钮必须有自己的拟物底与语义描红，不能退回浏览器默认外观。
    assert scope =~ ~r/\.btn-danger \{[^}]*border: 1px solid color-mix\(in srgb, var\(--nb-red\) 42%/s
  end

  test "primary and danger buttons stay readable and identically sized", %{css: css, scope: scope} do
    # 主按钮在拟物下不反色，必须显式给文字色，否则白字落在浅底上看不见。
    assert scope =~ ~r/:is\(\.btn-primary, \.btn-send[^{]*\{\s*[^}]*color: var\(--nb-label-1\)/s
    # 取消与暂停共用同一档几何，避免同类按钮大小不一。
    assert css =~ ~r/\.btn-primary, \.btn-ghost, \.btn-danger \{ min-height: var\(--ui-h-lg\); \}/
    assert css =~ ~r/\.btn-primary, \.btn-ghost, \.btn-danger, \.btn-allow, \.btn-deny \{/
    assert css =~ ~r/\.btn-danger \{[^}]*padding: 7px 14px;[^}]*font-size: 13px;/s
  end

  test "the terminal keeps its recessed window treatment", %{scope: scope} do
    # 用户明确认可的内陷窗口：整体凹槽 + 14px 圆角，工具栏与屏幕收在槽内。
    assert scope =~
             ~r/:where\([^)]*\.terminal-panel\) \{\s*background: var\(--nb-bg\);[^}]*box-shadow: var\(--nb-neu-inset\)/s

    assert scope =~ ~r/\.terminal-panel \{ border-radius: 14px; \}/
    assert scope =~ ~r/\.terminal-panel \.terminal-screen,/
  end

  test "second-wave surfaces gain material without losing semantic states", %{scope: scope} do
    # 用 :where() 压低特异性，保证 .pass/.pending/.healthy 这类语义状态仍然生效。
    assert scope =~ ~r/:where\(\.attach-item, \.wc-item, \.xm-cap, \.ctx-chip\)/
    assert scope =~ ~r/:where\(\.ctx-editor, \.evo-layers-detail\)/
    assert scope =~ ~r/:where\(\.mc-test-result, \.mc-step-detail, \.md-code,/
    assert scope =~ ~r/:where\(\.group-status, \.dir-crumb\)/
    assert scope =~ ~r/:where\(\.collab-write-conflicts\) \{\s*box-shadow/
    refute scope =~ ~r/:where\(\.collab-write-conflicts\) \{[^}]*border-color: transparent/s
  end

  test "task cards collapse secondary actions into a single menu", %{css: css} do
    app = File.read!("priv/web/app.js")

    # 主操作只留一个：验收 > 应用变更 > 领取 > 重试。
    assert app =~ ~s|function renderTaskActions(task, group)|
    assert app =~ ~s|if (coordinator && status === "submitted") primary =|
    assert app =~ ~s|else if (canDecide) primary =|
    assert app =~ ~s|else if (!assigned && status === "pending") primary =|
    # 其余操作进「⋯」菜单，且菜单项点击后自动收起。
    assert app =~ ~s|class="collab-task-more"|
    assert app =~ ~s|class="collab-task-menu"|
    assert app =~ "menu.open = false"
    # 验收按钮必须绑定到验收，而不是重试（修复历史上的错误嵌套）。
    assert app =~ ~s|await verifyCollaborationTask(button.dataset.verifyTask)|

    refute app =~
             ~r/querySelectorAll\("\[data-verify-task\]"\)\.forEach\(\(button\) => \{\s*list\.querySelectorAll\("\[data-retry-task\]"\)/s

    for cls <- [".collab-task-more", ".collab-task-menu", ".collab-task-menu button.danger"], do: assert(css =~ cls)
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
