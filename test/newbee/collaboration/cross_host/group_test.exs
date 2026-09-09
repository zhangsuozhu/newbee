defmodule Newbee.Collaboration.CrossHost.GroupTest do
  use ExUnit.Case, async: true
  alias Newbee.Collaboration.CrossHost.Group
  test "create auto password and verify" do
    assert {:ok, g, plain} = Group.create("order-dev", "order-system")
    assert plain != ""
    assert Group.verify_password(g, plain) == true
    assert Group.verify_password(g, "wrong-pass-123") == false
  end
  test "reject short and common" do
    assert {:error, "weak_password", _} = Group.create("g", "p", password: "1234567")
    assert {:error, "weak_password", _} = Group.create("g", "p", password: "12345678")
    assert {:error, "invalid_project", _} = Group.create("g", "")
  end
  test "change invalidates old" do
    assert {:ok, g, plain} = Group.create("g2", "proj", password: "s3cure-pass-9")
    assert {:ok, g2} = Group.change_password(g, "n3w-secure-10")
    assert Group.verify_password(g2, plain) == false
    assert Group.verify_password(g2, "n3w-secure-10") == true
  end
  test "gen length 16" do
    p = Group.generate_password()
    assert String.length(p) == 16
  end
end
