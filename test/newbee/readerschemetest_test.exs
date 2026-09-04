defmodule Newbee.ReaderSchemeTest do
  use ExUnit.Case, async: true

  test "skill:// 不存在的技能返回错误" do
    assert {:error, :skill_not_found} = Newbee.read("skill://definitely-not-here")
  end

  test "agent:// 不存在的子代理返回错误" do
    assert {:error, :agent_not_found} = Newbee.read("agent://nope/findings")
  end

  test "conflict:// 在 git 仓库返回清单" do
    assert {:ok, _} = Newbee.read("conflict://")
  end

  test "tool:// 拉取模块文档含函数签名" do
    {:ok, docs} = Newbee.read("tool://Newbee.Tools.Edit")
    assert docs =~ "patch"
    assert docs =~ "show"
  end

  test "prompt:// 按需加载协作指南" do
    {:ok, body} = Newbee.read("prompt://collaboration")
    assert body =~ "delegate"
  end

  test "prompt:// 按需加载能力索引" do
    {:ok, body} = Newbee.read("prompt://capabilities")
    assert body =~ "Newbee.Tools"
  end

  test "prompt:// 按需加载项目记忆" do
    {:ok, body} = Newbee.read("prompt://project-memory")
    assert body =~ "Project memory"
  end

  test "prompt:// 未知段返回错误" do
    assert {:error, {:unknown_prompt_section, _}} = Newbee.read("prompt://no-such-section")
  end

  test "schemes 注册 prompt://" do
    assert Enum.any?(Newbee.schemes(), &(&1.scheme == "prompt://"))
  end
end
