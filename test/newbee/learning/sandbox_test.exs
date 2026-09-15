defmodule Newbee.Learning.SandboxTest do
  use ExUnit.Case, async: false
  alias Newbee.Learning.Sandbox

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-sandbox-test-") <> Integer.to_string(System.unique_integer([:positive]))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "executes a simple program or fails closed", %{root: root} do
    if Sandbox.available?() do
      assert {:ok, result} = Sandbox.run("IO.puts(:BRS_OK)", root: root, memory: "m", timeout_ms: 40_000)
      assert result.exit_code == 0
      assert result.timed_out == false
      assert String.contains?(result.stdout, "BRS_OK")
      assert result.sandbox in [:bwrap, "bwrap"]
    else
      assert {:error, :unavailable} = Sandbox.run("IO.puts(:NO)", root: root)
    end
  end

  test "timeout is explicit and no home path is visible", %{root: root} do
    if Sandbox.available?() do
      code = "IO.puts(File.exists?(\"/home\")); :timer.sleep(5_000)"
      assert {:ok, result} = Sandbox.run(code, root: root, timeout_ms: 500, memory: "private")
      assert result.timed_out == true
      assert result.exit_code == nil
      refute String.contains?(result.stdout, "true")
    else
      assert {:error, :unavailable} = Sandbox.run("IO.puts(1)", root: root)
    end
  end

  test "host project files are not readable", %{root: root} do
    if Sandbox.available?() do
      read_path = "/home/alanx/data/git/newbee/.newbee/environment.json"
      code = "IO.inspect(File.read(" <> inspect(read_path) <> "))"
      assert {:ok, result} = Sandbox.run(code, root: root, timeout_ms: 40_000)
      assert result.exit_code == 0
      assert String.contains?(result.stdout, ":enoent")
    else
      assert {:error, :unavailable} = Sandbox.run("IO.puts(1)", root: root)
    end
  end
end
