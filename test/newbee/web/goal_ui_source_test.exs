defmodule Newbee.Web.GoalUiSourceTest do
  use ExUnit.Case, async: false

  # 前端目标的源码级回归（不启浏览器）：
  #   - goal 状态条结构存在，且六个事件各有渲染分支
  #   - 不引入旧调色板别名（--bg/--fg/--accent/--border 裸名）
  #   - conversation-work 静态资源版本号未被回退到旧的 delegation-icon
  #
  # 这些断言刻意保持「源码存在性 + 形状」级别，避免和 DOM 实现细节耦合。

  @app_js "priv/web/app.js"
  @index_html "priv/web/index.html"
  @style_css "priv/web/style.css"

  test "goal 状态条元素齐全" do
    html = File.read!(@index_html)

    for id <- ~w(goal-bar goal-dot goal-text goal-meta goal-progress goal-progress-fill goal-pause goal-stop) do
      assert html =~ ~s(id="#{id}"), "index.html 缺少 ##{id}"
    end
  end

  test "六个事件都有渲染分支，不再落到 default: break" do
    js = File.read!(@app_js)

    for event <- ~w(goal_budget_limited goal_blocked goal_verification_block goal_status goal_updated goal_budget) do
      assert js =~ ~s(case "#{event}"), "app.js 缺少 case \"#{event}\" 分支"
    end
  end

  test "goal 事件渲染会驱动状态条而不是只写一条 notice" do
    js = File.read!(@app_js)

    # renderGoal 存在且被事件分支与状态轮询共同调用
    assert js =~ "function renderGoal("
    assert js =~ "function refreshGoalFromState("
    assert js =~ "refreshGoalFromState(st)"
  end

  test "状态条覆盖五种状态的文案" do
    js = File.read!(@app_js)
    assert js =~ "GOAL_STATUS_TEXT"

    for status <- ~w(active paused blocked budget_limited complete) do
      assert js =~ status, "app.js 未处理状态 #{status}"
    end
  end

  test "未引入旧调色板别名" do
    legacy = ~r/var\(--(bg|bg2?|fg|fg2?|accent|border)\)/

    for path <- [@app_js, @style_css] do
      assert Regex.scan(legacy, File.read!(path)) == [], "#{path} 出现了旧调色板变量"
    end
  end

  test "goal 状态条只用已定义的 --nb-* 变量" do
    css = File.read!(@style_css)
    defs = Regex.scan(~r/--([a-zA-Z0-9-]+)\s*:/, css) |> Enum.map(fn [_, n] -> n end) |> MapSet.new()

    # 用「从 .goal-bar 到下一个非 goal 选择器」的区间截取样式块。
    # 不用跨行正则（dot 默认不匹配换行，且 .goal-bar 块内还有嵌套花括号）。
    lines = String.split(css, "\n")
    start = Enum.find_index(lines, &String.starts_with?(&1, ".goal-bar {"))
    assert start != nil, "未找到 .goal-bar 样式块"

    goal_block =
      lines
      |> Enum.drop(start)
      |> Enum.take_while(&(not String.starts_with?(&1, ".mobile-details-handle")))
      |> Enum.join("\n")

    assert goal_block =~ ".goal-progress-fill"

    refs =
      Regex.scan(~r/var\(--([a-zA-Z0-9-]+)/, goal_block)
      |> Enum.map(fn [_, n] -> n end)
      |> MapSet.new()

    assert refs != MapSet.new()
    assert MapSet.to_list(MapSet.difference(refs, defs)) == []
  end

  test "conversation-work 静态资源版本号未被回退到旧的 delegation-icon" do
    html = File.read!(@index_html)

    # 版本号随上游演进（delegation-icon → workcard-progress → team-mutex …），
    # 断言只守住「不回退」这一不变量，不绑定某个具体上游批次的字面量。
    refute html =~ "?v=delegation-icon-", "conversation-work 资源版本号被回退到 delegation-icon"

    for asset <- ["conversation-work.css", "conversation-work.js"] do
      assert Regex.match?(Regex.compile!("/" <> Regex.escape(asset) <> "\\?v=[A-Za-z0-9.-]+"), html),
             asset <> " 缺少缓存版本号 ?v="
    end
  end
end
