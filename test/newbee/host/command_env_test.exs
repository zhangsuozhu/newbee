# Regression: child must not inherit NEWBEE_CWD.
defmodule Newbee.Host.CommandEnvTest do
  use ExUnit.Case, async: false

  test "Host.Command.run unsets NEWBEE_CWD in child" do
    System.put_env("NEWBEE_CWD", "/tmp/newbee-cwd-leak-probe")
    on_exit(fn -> System.delete_env("NEWBEE_CWD") end)
    cwd = System.tmp_dir!()
    result = Newbee.Host.Command.run(self(), "printf %s \"${NEWBEE_CWD-unset}\"", 5_000, cwd)
    assert result.exit == 0
    assert String.trim(result.output) == "unset"
  end

  test "Evaluator filter unsets NEWBEE_CWD keeps unrelated" do
    System.put_env("NEWBEE_CWD", "/tmp/newbee-cwd-leak-probe")
    System.put_env("NEWBEE_PROBE_KEEP", "keepme")

    on_exit(fn ->
      System.delete_env("NEWBEE_CWD")
      System.delete_env("NEWBEE_PROBE_KEEP")
    end)

    :ok = Newbee.DEE.Evaluator.__filter_env__(["OPENROUTER_"], ["_KEY"])
    assert System.get_env("NEWBEE_CWD") == nil
    assert System.get_env("NEWBEE_PROBE_KEEP") == "keepme"
  end

  test "terminal env guard mentions NEWBEE_CWD" do
    {:ok, src} = File.read("lib/newbee/web/terminal.ex")
    assert src =~ "NEWBEE_CWD"
  end
end
