defmodule Newbee.SessionSecurityTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "newbee-session-security-" <> Integer.to_string(System.unique_integer([:positive])))

    previous = Application.get_env(:newbee, :global_root_override)
    Application.put_env(:newbee, :global_root_override, root)

    on_exit(fn ->
      Application.put_env(:newbee, :global_root_override, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "rejects traversal and separators in session ids" do
    for id <- ["../outside", "../../tmp/x", "a/b", "/tmp/x", "a\\b", "", ".", ".."] do
      refute Newbee.Session.valid_id?(id)
      assert_raise ArgumentError, fn -> Newbee.Session.open(id) end
      assert_raise ArgumentError, fn -> Newbee.Session.media_dir(id) end
      assert_raise ArgumentError, fn -> Newbee.Session.uploads_dir(id) end
      assert {:error, :invalid_session_id} = Newbee.Session.delete(id)
    end
  end

  test "delete never removes a directory outside the session store" do
    outside =
      Path.join(System.tmp_dir!(), "newbee-session-outside-" <> Integer.to_string(System.unique_integer([:positive])))

    File.mkdir_p!(outside)
    sentinel = Path.join(outside, "keep")
    File.write!(sentinel, "safe")
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, :invalid_session_id} = Newbee.Session.delete("../" <> Path.basename(outside))
    assert File.read!(sentinel) == "safe"
  end

  test "valid ids still open and delete normally" do
    id = "safe_session-1.2"
    session = Newbee.Session.open(id)
    assert Newbee.Session.valid_id?(id)
    assert File.dir?(session.dir)
    assert :ok = Newbee.Session.delete(id)
    refute File.dir?(session.dir)
  end
end
