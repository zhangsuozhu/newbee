defmodule Newbee.Web.ModelConfigUiTest do
  use ExUnit.Case, async: true

  test "模型配置表单只生成规范 API 值并提交逐模型覆盖" do
    html = File.read!("priv/web/index.html")
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
end
