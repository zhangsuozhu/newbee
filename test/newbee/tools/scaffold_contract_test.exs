defmodule Newbee.Tools.ScaffoldContractTest do
  use ExUnit.Case, async: true

  test "Scaffold 只暴露脚手架职责，不重复 Run 编译测试 API" do
    exports = Newbee.Tools.Scaffold.__info__(:functions)
    assert {:new_project, 1} in exports
    assert {:deps_get, 0} in exports
    refute Enum.any?(exports, fn {name, _} -> name in [:compile, :test] end)
  end
end
