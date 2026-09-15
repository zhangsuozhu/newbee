defmodule Newbee.Colony.IntentTest do
  use ExUnit.Case, async: true

  alias Newbee.Colony.Intent

  test "帮助与进展" do
    assert {:ok, %{kind: :help}} = Intent.parse("你会做什么")
    assert {:ok, %{kind: :help}} = Intent.parse("能干嘛")
    assert {:ok, %{kind: :progress}} = Intent.parse("进展如何")
    assert {:ok, %{kind: :progress}} = Intent.parse("做到哪了")
  end

  test "建群（带名字 / 不带名字）" do
    assert {:ok, %{kind: :create_colony, name: "性能压测"}} = Intent.parse("建个群做性能压测")
    assert {:ok, %{kind: :create_colony, name: "文档"}} = Intent.parse("新建一个群叫文档")
    assert {:ok, %{kind: :create_colony}} = Intent.parse("建个群")
    # 「打开某群」不应误判为建群
    assert {:ok, %{kind: :switch, to: "文档"}} = Intent.parse("打开文档群")
  end

  test "加人 / 移出" do
    assert {:ok, %{kind: :add_bee, who: "bob"}} = Intent.parse("加 bob 进来")
    assert {:ok, %{kind: :add_bee, who: "charlie"}} = Intent.parse("把 charlie 拉进来")
    assert {:ok, %{kind: :remove_bee, who: "data-bot"}} = Intent.parse("把 data-bot 移出这个群")
  end

  test "退出与 Queen 交接" do
    assert {:ok, %{kind: :leave}} = Intent.parse("我退出")
    assert {:ok, %{kind: :leave, handover_to: "bob"}} = Intent.parse("我退出，让 bob 当 Queen")
    assert {:ok, %{kind: :handover, to: "bob"}} = Intent.parse("让 bob 当 Queen")
  end

  test "派活（指定人 / 不指定）" do
    assert {:ok, %{kind: :dispatch, assignee: "auth-bot", title: "补测试"}} =
             Intent.parse("让 auth-bot 补测试")

    assert {:ok, %{kind: :dispatch, assignee: nil, title: "重构登录模块"}} = Intent.parse("帮我重构登录模块")
    assert {:ok, %{kind: :dispatch, title: "重构 login 模块"}} = Intent.parse("重构 login 模块")
  end

  test "验收 / 打回 / 拆分 / 切换 / 解散" do
    assert {:ok, %{kind: :accept}} = Intent.parse("通过")
    assert {:ok, %{kind: :accept}} = Intent.parse("可以")
    assert {:ok, %{kind: :reject}} = Intent.parse("打回重做")

    assert {:ok, %{kind: :decompose, children: [%{"title" => "补测试"}, %{"title" => "写文档"}]}} =
             Intent.parse("拆出子任务：补测试、写文档")

    assert {:ok, %{kind: :switch, to: "文档"}} = Intent.parse("切换到文档群")
    assert {:ok, %{kind: :dissolve}} = Intent.parse("解散这个群")
  end

  test "解析不出来时回落到群聊而不是报错" do
    assert {:error, :unknown} = Intent.parse("今天天气不错")
    assert {:error, :unknown} = Intent.parse("")
  end

  test "能力自述的每条都是可执行的一句话" do
    groups = Intent.capabilities()
    assert length(groups) >= 5
    assert Enum.all?(groups, fn g -> g["examples"] != [] and is_binary(g["group"]) end)
  end
end
