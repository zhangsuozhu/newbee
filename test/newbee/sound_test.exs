defmodule Newbee.SoundTest do
  use ExUnit.Case, async: true

  test "kinds covers done/ask/error states" do
    kinds = Newbee.Sound.kinds()
    assert :done in kinds
    assert :ask in kinds
    assert :error in kinds
    assert :interrupted in kinds
    assert :info in kinds
  end

  test "normalize maps回合结果到声音种类" do
    assert Newbee.Sound.normalize(:done) == :done
    assert Newbee.Sound.normalize(:goal_done) == :done
    assert Newbee.Sound.normalize(:ask) == :ask
    assert Newbee.Sound.normalize(:permission_ask) == :ask
    assert Newbee.Sound.normalize(:goal_ask) == :ask
    assert Newbee.Sound.normalize(:error) == :error
    assert Newbee.Sound.normalize(:interrupted) == :interrupted
    assert Newbee.Sound.normalize(:text) == :info
    assert Newbee.Sound.normalize(:text_end) == :info
    assert Newbee.Sound.normalize({:turn_end, :done, 10}) == :done
    assert Newbee.Sound.normalize({:turn_end, :ask, 10}) == :ask
    assert Newbee.Sound.normalize("done") == :done
    assert Newbee.Sound.normalize(:unknown_kind_xyz) == :info
  end

  test "不同状态映射到不同系统声音" do
    assert Newbee.Sound.canberra_id(:done) != Newbee.Sound.canberra_id(:error)
    assert Newbee.Sound.canberra_id(:ask) != Newbee.Sound.canberra_id(:error)
    assert Newbee.Sound.canberra_id(:done) != Newbee.Sound.canberra_id(:ask)
    assert Newbee.Sound.macos_file(:done) != Newbee.Sound.macos_file(:error)
    assert Newbee.Sound.bell_pattern(:error) != Newbee.Sound.bell_pattern(:ask)
    assert Newbee.Sound.bell_pattern(:done) != Newbee.Sound.bell_pattern(:error)
  end

  test "enabled? respects NEWBEE_SOUND" do
    System.delete_env("NEWBEE_SOUND")
    Application.delete_env(:newbee, :sound_enabled)
    assert Newbee.Sound.enabled?() == true

    System.put_env("NEWBEE_SOUND", "0")
    assert Newbee.Sound.enabled?() == false

    System.put_env("NEWBEE_SOUND", "off")
    assert Newbee.Sound.enabled?() == false

    System.put_env("NEWBEE_SOUND", "1")
    assert Newbee.Sound.enabled?() == true

    System.delete_env("NEWBEE_SOUND")
    Application.put_env(:newbee, :sound_enabled, false)
    assert Newbee.Sound.enabled?() == false

    Application.delete_env(:newbee, :sound_enabled)
    assert Newbee.Sound.enabled?() == true
  end

  test "play永不阻塞抛异常（开/关都返回:ok）" do
    System.put_env("NEWBEE_SOUND", "0")
    assert Newbee.Sound.play(:done) == :ok
    assert Newbee.Sound.play(:ask) == :ok
    assert Newbee.Sound.play(:error) == :ok

    System.put_env("NEWBEE_SOUND", "1")
    assert Newbee.Sound.play(:done) == :ok
    assert Newbee.Sound.play({:turn_end, :error, 5}) == :ok
    assert Newbee.Sound.play(:unknown_kind_xyz) == :ok

    System.delete_env("NEWBEE_SOUND")
  end
end
