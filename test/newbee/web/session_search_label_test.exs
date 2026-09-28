defmodule Newbee.Web.SessionSearchLabelTest do
  @moduledoc """
  侧栏搜索与列表渲染必须共用同一套标题回退。

  现场证据：新建的空会话在列表里显示为「新会话」，但过滤只看 s.title/s.id，
  用户搜「新会话」命中 0 条——显示出来的搜不到。
  """
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "回退语义集中在 sessionDisplayTitle", %{js: js} do
    assert js =~ "function sessionDisplayTitle(s)"
    assert js =~ ~r/sessionDisplayTitle\(s\).*新会话/s
  end

  test "过滤用展示标题而不是裸 s.title", %{js: js} do
    assert js =~ ~r/const visible = \(s\) => !kw \|\| sessionDisplayTitle\(s\)/
    refute js =~ ~r/const visible = \(s\) => !kw \|\| String\(s\.title/
  end

  test "条目渲染也走同一函数", %{js: js} do
    assert js =~ "const title = sessionDisplayTitle(s);"
  end
end
