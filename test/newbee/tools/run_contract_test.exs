defmodule Newbee.Tools.RunContractTest do
  use ExUnit.Case, async: true

  test "Run 使用统一 sh timeout 选项，不暴露项目特例或超时别名" do
    exports = Newbee.Tools.Run.__info__(:functions)
    assert {:sh, 1} in exports
    assert {:sh, 2} in exports
    refute Enum.any?(exports, fn {name, _} -> name in [:sh_long, :django_test] end)
  end

  test "mix helpers take the same opts as sh/2" do
    exports = Newbee.Tools.Run.__info__(:functions)
    assert {:mix_compile, 1} in exports
    assert {:mix_test, 2} in exports
    # `mix_format/2` used to be missing, so `timeout:` raised UndefinedFunctionError.
    assert {:mix_format, 2} in exports
  end
end
