defmodule Newbee.Tools.HotReloadTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Newbee.Tools.HotReload

  @demo_v1 """
  defmodule HotReloadDemo do
    def version, do: "v1"
    def add(a, b), do: a + b
  end
  """

  @demo_v2 """
  defmodule HotReloadDemo do
    def version, do: "v2"
    def add(a, b), do: a + b + 100
  end
  """

  setup do
    # 清掉测试模块，避免跨 case 污染
    :code.purge(HotReloadDemo)
    :code.delete(HotReloadDemo)
    :ok
  end

  test "replace/2 源码字符串热替换并即时生效" do
    assert %{ok: true, modules: [%{module: HotReloadDemo}]} = HotReload.replace(@demo_v1)
    assert HotReloadDemo.version() == "v1"
    assert HotReloadDemo.add(1, 2) == 3

    assert %{ok: true, modules: [%{new_md5: md5}]} = HotReload.replace(@demo_v2)
    assert HotReloadDemo.version() == "v2"
    assert HotReloadDemo.add(1, 2) == 103
    assert is_binary(md5) and byte_size(md5) == 32
  end

  test "load_file/2 从 .exs 文件加载替换" do
    path = Path.join(System.tmp_dir!(), "hot_reload_demo_#{System.unique_integer([:positive])}.exs")
    File.write!(path, @demo_v1)

    assert %{ok: true} = HotReload.load_file(path)
    assert HotReloadDemo.version() == "v1"

    File.write!(path, @demo_v2)
    assert %{ok: true} = HotReload.load_file(path)
    assert HotReloadDemo.version() == "v2"

    File.rm(path)
  end

  test "status/1 返回模块加载信息" do
    HotReload.replace(@demo_v1)
    s = HotReload.status(HotReloadDemo)
    assert s.ok
    assert s.module == HotReloadDemo
    assert s.loaded?
    assert is_binary(s.md5)
    assert s.old_code? == false
  end

  test "unload/1 卸载模块" do
    HotReload.replace(@demo_v1)
    assert HotReloadDemo.version() == "v1"

    %{ok: true} = HotReload.unload(HotReloadDemo)
    assert :code.is_loaded(HotReloadDemo) == false
  end

  test "非法源码返回 ok:false 不崩溃" do
    r = HotReload.replace("defmodule Broken do")
    assert r.ok == false
    assert is_binary(r.error)
  end
end
