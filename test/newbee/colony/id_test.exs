defmodule Newbee.Colony.IdTest do
  use ExUnit.Case, async: true

  alias Newbee.Colony.Id

  test "new/2 生成带实体前缀与作用域标签的 ID" do
    assert String.starts_with?(Id.new(:colony, :local), "col_l_")
    assert String.starts_with?(Id.new(:colony, :xhost), "col_x_")
    assert String.starts_with?(Id.new(:task, :local), "task_l_")
    assert String.starts_with?(Id.new(:bee, :xhost), "bee_x_")
    assert String.starts_with?(Id.new(:honey, :local), "hon_l_")
    assert String.starts_with?(Id.new(:garden, :xhost), "g_x_")
  end

  test "默认作用域 local 且每次生成唯一" do
    assert String.contains?(Id.new(:task), "task_l_")
    ids = for _ <- 1..200, do: Id.new(:task)
    assert length(Enum.uniq(ids)) == 200
  end

  test "parse/kind/scope/valid?" do
    id = Id.new(:task, :xhost)
    assert {:ok, %{kind: :task, scope: :xhost}} = Id.parse(id)
    assert Id.kind(id) == :task
    assert Id.scope(id) == :xhost
    assert Id.valid?(id)

    assert Id.parse("garbage") == :error
    assert Id.kind("nope") == nil
    assert Id.scope(nil) == nil
    refute Id.valid?("random")
  end

  test "legacy_classify 归类存量前缀" do
    assert Id.legacy_classify("grp_abc") == {:ok, :colony, :local}
    assert Id.legacy_classify("mem_abc") == {:ok, :bee, :local}
    assert Id.legacy_classify("task_abc") == {:ok, :task, :local}
    assert Id.legacy_classify("msg_abc") == {:ok, :signal, :local}
    assert Id.legacy_classify("t_abc") == {:ok, :task, :xhost}
    assert Id.legacy_classify("k_abc") == {:ok, :honey, :xhost}
    assert Id.legacy_classify("delivery_abc") == {:ok, :delivery, :xhost}
    assert Id.legacy_classify("zzz") == :error
    assert Id.legacy_classify(nil) == :error
  end
end
