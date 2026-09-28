defmodule Newbee.Web.SessionTitleRenameTest do
  @moduledoc """
  顶栏双击重命名的 finish 必须幂等。

  现场证据：Enter 提交后 blur 会再触发一次 finish，第二次 inp.replaceWith 抛
  NotFoundError（The node to be removed is no longer a child…）成为未捕获 Promise 拒绝，
  浏览器轮次 R91/R93 复现 pageerror；修复后 R95 归零。
  """
  use ExUnit.Case, async: true

  @js "priv/web/app.js"

  setup do
    %{js: File.read!(@js)}
  end

  test "finish 有一次性守卫", %{js: js} do
    assert js =~ "let finished = false;"
    assert js =~ "if (finished) return;"
  end

  test "replaceWith 只在输入框仍挂载时执行", %{js: js} do
    assert js =~ "if (inp.isConnected) {"
    assert js =~ ~r/if \(inp\.isConnected\) \{\s*inp\.replaceWith\(span\);/s
  end
end
