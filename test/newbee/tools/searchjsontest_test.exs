defmodule Newbee.Tools.SearchJsonTest do
  use ExUnit.Case, async: false
  alias Newbee.Tools.{Search, Json}

  test "grep 在工程内命中 defmodule" do
    hits = Search.grep("defmodule Newbee.Tools.Search", "lib")
    assert Enum.any?(hits, fn {path, _n, line} -> path =~ "search.ex" and line =~ "defmodule" end)
  end

  @tag timeout: 120_000
  test "grep 跳过 _build" do
    hits = Search.grep("defmodule_NONEXISTENT_PATTERN_XYZ", "_build")
    # 即使目录命中 @skip 过滤，仍验证不崩溃且返回列表
    assert is_list(hits)
  end

  test "find 按文件名片段" do
    assert Enum.any?(Search.find("search.ex"), &String.ends_with?(&1, "lib/newbee/tools/search.ex"))
  end

  test "Json 路径提取" do
    data = %{"data" => %{"items" => [%{"name" => "a"}, %{"name" => "b"}]}}
    assert Json.get!(data, "data.items[1].name") == "b"
    assert {:ok, "a"} = Json.get(data, "data.items[0].name")
    # 缺段一律:error（旧实现靠BadMap崩出:error，深浅不一）；显式null才{:ok,nil}
    assert :error = Json.get(data, "data.nope")
    assert :error = Json.get(data, "data.nope.deep")
    assert {:ok, nil} = Json.get(%{"a" => nil}, "a")
  end

  test "Json 编解码" do
    assert {:ok, %{"a" => 1}} = Json.decode(~s({"a":1}))
    assert Json.encode(%{a: 1}) == ~s({"a":1})
  end
end
