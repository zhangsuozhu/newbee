defmodule Newbee.Collaboration.CrossHost.AuthTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.CrossHost.Auth
  alias Newbee.Collaboration.CrossHost.Group
  test "server pin fail closed" do
    assert :ok = Auth.verify_server("fp-abcdef-12345678", "fp-abcdef-12345678")
    assert {:error, "fake_server", _} = Auth.verify_server("fp-abcdef-12345678", "fp-abcdef-87654321")
    assert {:error, "bad_server_identity", _} = Auth.verify_server("", "x")
  end
  test "device issue verify pause remove" do
    assert {:ok, g, _} = Group.create("g", "p", password: "s3cure-pass-9")
    assert {:ok, g2, dev} = Auth.issue_device(g, "m1", "dev-8")
    plain = Map.get(dev, "plain")
    did = Map.get(dev, "id")
    assert Auth.verify_device(g2, did, plain) == true
    assert Auth.verify_device(g2, did, "bad") == false
    g3 = Auth.pause_device(g2, did, true)
    assert Auth.verify_device(g3, did, plain) == false
    g4 = Auth.pause_device(g3, did, false)
    assert Auth.verify_device(g4, did, plain) == true
    g5 = Auth.remove_device(g4, did)
    assert Auth.verify_device(g5, did, plain) == false
  end
  test "remove member clears devices" do
    assert {:ok, g, _} = Group.create("g", "p", password: "s3cure-pass-9")
    assert {:ok, g2, d1} = Auth.issue_device(g, "m1", "a")
    assert {:ok, g3, _} = Auth.issue_device(g2, "m1", "b")
    g4 = Auth.remove_member(g3, "m1")
    assert Auth.verify_device(g4, Map.get(d1, "id"), Map.get(d1, "plain")) == false
    assert Map.get(g4, "devices") == %{}
  end
end
