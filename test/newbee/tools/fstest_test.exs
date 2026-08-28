defmodule Newbee.Tools.FsTest do
  use ExUnit.Case, async: true
  alias Newbee.Tools.Fs

  test "工程树内路径放行" do
    tmp =
      Path.join(File.cwd!(), ".newbee-tmp-test-#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}")

    assert :ok = Fs.guard_path!(tmp)
    File.rm_rf(tmp)
  end

  test "~/.newbee 内路径放行" do
    assert :ok = Fs.guard_path!(Path.join(System.user_home!(), ".newbee/tmp-x"))
  end

  test "工程树外写入被拒（§8 工作目录隔离）" do
    outside =
      Path.join(
        System.tmp_dir!(),
        "newbee_guard_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.txt"
      )

    assert_raise ArgumentError, ~r/工程树外/, fn ->
      Fs.write!(outside, "x")
    end

    assert_raise ArgumentError, ~r/工程树外/, fn ->
      Fs.append!(outside, "x")
    end

    assert {:error, %{reason: :out_of_bounds, hint: hint}} = Fs.rm(outside)
    assert hint =~ "工程树外"
    assert {:error, %{reason: :out_of_bounds}} = Fs.rm_rf(outside)
  end
end
