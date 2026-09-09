defmodule Newbee.Collaboration.CrossHost.JoinCodeTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.CrossHost.Join
  alias Newbee.Collaboration.CrossHost.Store

  test "code roundtrip carries gid, fingerprint, and optional Hub URL" do
    g = %{"id" => "g-code-1", "server_fp" => "fp-abc", "server_url" => "https://192.168.0.20:4173"}
    code = Join.join_code(g)
    assert String.starts_with?(code, "XG1.")
    refute code =~ "secret-pw"

    assert {:ok,
            %{
              "gid" => "g-code-1",
              "fp" => "fp-abc",
              "url" => "https://192.168.0.20:4173"
            }} = Join.parse_code(code)
  end

  test "parse tolerates old invite links and bare ids" do
    assert {:ok, %{"gid" => "G1", "fp" => "F1"}} = Join.parse_code("http://h/xgroup?gid=G1&fp=F1")
    assert {:ok, %{"gid" => "G2"}} = Join.parse_code("G2")
    assert {:error, _, _} = Join.parse_code("not a code !!")
  end

  test "session bind list unbind scoped by group" do
    Store.clear()
    :ok = Store.bind_session(%{"session_id" => "s1", "group_id" => "g1", "member_id" => "m1", "device_id" => "d1"})
    :ok = Store.bind_session(%{"session_id" => "s2", "group_id" => "g2", "member_id" => "m2", "device_id" => nil})
    assert [%{"session_id" => "s1"}] = Store.sessions_for_group("g1")
    :ok = Store.unbind_session("s1")
    assert [] = Store.sessions_for_group("g1")
    assert [%{"session_id" => "s2"}] = Store.sessions_for_group("g2")
  end

  test "delete_group wipes tasks and bindings" do
    Store.clear()
    Store.put_group(%{"id" => "gd", "name" => "x"})
    Store.put_task(%{"id" => "t1", "group_id" => "gd"})
    Store.bind_session(%{"session_id" => "s9", "group_id" => "gd"})
    :ok = Store.delete_group("gd")
    assert {:error, _, _} = Store.get_group("gd")
    assert [] = Store.list_tasks("gd")
    assert [] = Store.sessions_for_group("gd")
  end
end
