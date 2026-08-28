defmodule Newbee.Tools.DocumentationContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "公开文档只描述唯一 Edit 协议" do
    readme = File.read!(Path.join(@root, "README.md"))
    design = File.read!(Path.join(@root, "DESIGN.md"))
    edit_design = File.read!(Path.join(@root, "docs/edit-design.md"))

    assert readme =~ "Newbee.Tools.Edit.show/2"
    assert readme =~ "source_literal/1"
    assert design =~ "文件快照 + 行号范围"
    assert edit_design =~ "唯一公开文本编辑协议"
    refute design =~ "文本轨 v2"
    refute File.exists?(Path.join(@root, "docs/edit-v2-design.md"))
  end

  test "源码文档引用现行设计文档" do
    edit = File.read!(Path.join(@root, "lib/newbee/tools/edit.ex"))
    snapshots = File.read!(Path.join(@root, "lib/newbee/tools/edit/snapshot_store.ex"))

    assert edit =~ "docs/edit-design.md"
    assert snapshots =~ "docs/edit-design.md"
    refute edit =~ "docs/edit-v2-design.md"
  end

  test "DESIGN 和 README 固定三层提示与去重 API" do
    design = File.read!(Path.expand("../../../DESIGN.md", __DIR__))
    readme = File.read!(Path.expand("../../../README.md", __DIR__))

    assert design =~ "常驻 function schema"
    assert design =~ "按需 `tool://`"
    assert readme =~ "Scaffold 只做工程创建/依赖"
    assert readme =~ "没有 `sh_long`"
    assert readme =~ "~/.newbee/jspace/"
    refute design =~ "edit/v2.ex"
  end
end
