defmodule Newbee.ReaderAuditTest do
  use ExUnit.Case, async: true

  test "schemes/0 登记12协议" do
    schemes = Newbee.schemes()
    assert length(schemes) == 12
    assert Enum.any?(schemes, &(&1.scheme == "memory://"))
    assert Enum.any?(schemes, &(&1.scheme == "history://"))
  end

  test "memory://空键列主题不返回not_found" do
    assert {:ok, body} = Newbee.read("memory://")
    assert is_binary(body)
    refute body == ""
  end

  test "skill://后缀幂等：缺失时两种写法同错" do
    assert {:error, :skill_not_found} = Newbee.read("skill://definitely-not-here-xyz")
    assert {:error, :skill_not_found} = Newbee.read("skill://definitely-not-here-xyz.md")
  end

  test "Json.get缺段返回error，显式null返回ok nil" do
    assert :error = Newbee.Tools.Json.get(%{"a" => 1}, "b")
    assert {:ok, nil} = Newbee.Tools.Json.get(%{"a" => nil}, "a")
    assert :error = Newbee.Tools.Json.get(%{"a" => [1]}, "a[5]")
    assert {:ok, 1} = Newbee.Tools.Json.get(%{"a" => [1, 2]}, "a[0]")
  end

  test "events://超大n被钳制不崩" do
    assert {:ok, _} = Newbee.read("events://?n=99999")
    assert {:ok, _} = Newbee.read("events://?n=5")
  end

  test "http私网被拦" do
    assert {:error, {:ssrf_blocked, _}} = Newbee.read("http://127.0.0.1/")
    assert {:error, {:ssrf_blocked, _}} = Newbee.read("http://169.254.169.254/")
    assert {:error, {:ssrf_blocked, _}} = Newbee.read("http://localhost/")
  end

  test "conflict坏块不崩" do
    path = Path.join(System.tmp_dir!(), "newbee-conflict-bad-#{:erlang.unique_integer([:positive])}.txt")
    File.write!(path, "head\n<<<<<<< ours-no-separator\ntail\n")
    assert {:ok, body} = Newbee.read("conflict://" <> path)
    assert body =~ "has no conflict hunks"
    File.rm!(path)
  end

  test "rules过滤空与无命中都ok" do
    assert {:ok, _} = Newbee.read("rules://")
    assert {:ok, body} = Newbee.read("rules://definitely-no-such-rule-xyz")
    assert is_binary(body)
  end

  test "agent缺段返回path_not_found（造dummy）" do
    id = "audit-#{:erlang.unique_integer([:positive])}"
    dir = Path.join([System.user_home!(), ".newbee", "agents", id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "result.json"), Jason.encode!(%{"findings" => "hi", "nested" => %{"a" => 1}}))
    assert {:ok, _} = Newbee.read("agent://" <> id <> "/findings")
    assert {:error, :path_not_found} = Newbee.read("agent://" <> id <> "/nope.missing")
    File.rm_rf!(dir)
  end
end
