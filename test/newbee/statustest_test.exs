defmodule Newbee.StatusTest do
  use ExUnit.Case, async: false

  test "render 用模型组织为功能数据纯文本" do
    client = Newbee.LLM.Client.new(api_key: "test")

    complete = fn _client, messages, _opts ->
      assert Enum.any?(messages, &(&1["role"] == "system"))
      {:ok, "功能：事件总线 数据：运行中，订阅者3个\n功能：热载工具 数据：12个", %{}}
    end

    output = Newbee.Status.render(client, complete)
    assert output == "功能：事件总线 数据：运行中，订阅者3个\n功能：热载工具 数据：12个"
    refute output =~ "|"
    refute output =~ "##"
  end

  test "模型失败时降级为纯文本" do
    client = Newbee.LLM.Client.new(api_key: "test")
    output = Newbee.Status.render(client, fn _, _, _ -> {:error, :offline} end)

    assert is_binary(output)
    refute output =~ "|"
    refute output =~ "##"
    refute output =~ "```"
  end

  test "无 client 时也返回纯文本" do
    output = Newbee.Status.render()

    assert is_binary(output)
    refute output =~ "|"
    refute output =~ "##"
    refute output =~ "```"
  end
end
