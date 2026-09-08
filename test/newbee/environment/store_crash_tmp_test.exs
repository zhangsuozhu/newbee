defmodule Newbee.Environment.StoreCrashTmpTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Store

  test "ensure keeps fresh tmp files and removes stale ones" do
    Store.ensure!()
    fresh_dir = Store.change_dir("chg_fresh_tmp_test")
    stale_dir = Store.change_dir("chg_stale_tmp_test")
    File.mkdir_p!(fresh_dir)
    File.mkdir_p!(stale_dir)
    fresh = Path.join(fresh_dir, "change.json.tmp.1")
    stale = Path.join(stale_dir, "change.json.tmp.2")
    File.write!(fresh, "{}")
    File.write!(stale, "{}")
    :ok = :file.change_time(String.to_charlist(stale), {{2020, 1, 1}, {0, 0, 0}})

    Store.ensure!()

    assert File.exists?(fresh)
    refute File.exists?(stale)
  end
end
