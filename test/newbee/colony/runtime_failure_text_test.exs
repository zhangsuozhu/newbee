# 回归：投递失败原因写进任务 next_step 后会直接显示在工作卡上，
# 所以 provider 错误必须转成可读文案，不能把 {:http_error, 400, "..."} 原样丢给用户。
defmodule Newbee.Colony.RuntimeFailureTextTest do
  use ExUnit.Case, async: true

  alias Newbee.Colony.Runtime

  test "HTTP 400 转成带状态码与 provider 说明的中文提示" do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "invalid_value",
          "message" => "The image data you provided does not represent a valid image.",
          "type" => "invalid_request_error"
        }
      })

    text = Runtime.format_failure({:http_error, 400, body})

    assert text =~ "HTTP 400"
    assert text =~ "does not represent a valid image"
    refute text =~ "{:http_error"
    refute text =~ "invalid_request_error"
  end

  test "上游与流式错误也转成人话" do
    assert Runtime.format_failure({:upstream_error, :closed}) =~ "上游暂时不可用"
    assert Runtime.format_failure({:stream_error, :timeout}) =~ "流式请求失败"
  end

  test "会话错误事件不再把原始元组丢给用户" do
    src = File.read!("lib/newbee/web/session.ex")

    # 回归：encode_event({:error, e}) 曾直接 message: inspect(e)，
    # 于是 {:http_error, 400, "..."} 原样出现在会话错误行和 colony 工作卡上。
    assert src =~ "defp encode_event({:error, e}), do: %{message: error_text(e)}"
    assert src =~ "defp error_text({:http_error, _, _} = error)"
    refute src =~ "message: inspect(e)"
  end

  test "未知原因保留 inspect 便于排查，字符串原样返回" do
    assert Runtime.format_failure(:weird_reason) == ":weird_reason"
    assert Runtime.format_failure("会话已被成员关闭") == "会话已被成员关闭"
  end
end
