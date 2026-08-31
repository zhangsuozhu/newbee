defmodule Newbee.Tools.StructuralTest do
  use ExUnit.Case, async: true
  alias Newbee.Tools.Structural

  @src """
  defmodule Demo.Target do
    @moduledoc false

    def hello, do: :world
  end
  """

  setup do
    path =
      Path.join(System.tmp_dir!(), "struct_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.ex")

    File.write!(path, @src)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "insert_function 在模块末尾插入", %{path: path} do
    assert {:ok, :inserted} = Structural.insert_function(path, Demo.Target, "def added(x), do: x + 1")

    body = File.read!(path)
    assert body =~ "def added(x)"
    # 原函数还在
    assert body =~ "def hello"
    # 语法仍然合法
    assert {:ok, _} = Sourceror.parse_string(body)
  end

  test "replace_function 整段替换", %{path: path} do
    assert {:ok, :replaced} = Structural.replace_function(path, Demo.Target, :hello, 0, "def hello, do: :mars")
    assert File.read!(path) =~ ":mars"
    refute File.read!(path) =~ ":world"
  end

  test "replace_function 找不到返回 error", %{path: path} do
    assert {:error, :function_not_found} = Structural.replace_function(path, Demo.Target, :nope, 0, "def nope, do: 1")
  end

  test "list_functions 列签名", %{path: path} do
    assert {:ok, sigs} = Structural.list_functions(path, Demo.Target)
    assert "def hello/0" in sigs
  end

  test "format 保持语义", %{path: path} do
    assert {:ok, :formatted} = Structural.format(path)
    assert {:ok, _} = Sourceror.parse_string(File.read!(path))
  end
end
