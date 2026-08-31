defmodule Newbee.Environment.AntibodiesTest do
  use ExUnit.Case, async: false

  alias Newbee.Environment.Antibodies

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ab_#{System.system_time(:native)}_#{System.system_time(:native)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, scope: dir}
  end

  test "两态生命周期：observed_failure → verified_regression_test", %{scope: dir} do
    {:ok, entry} =
      Antibodies.observe(
        "f1",
        %{input: "1 + 1", error: "boom", release_id: "tool.x@abc", revision: 3},
        scope: dir
      )

    assert entry["state"] == "observed_failure"
    assert Antibodies.verified_count(scope: dir) == 0

    # 晋升需要 oracle（check）+ 可重放（expect_ok 在干净求值器中成功）
    {:ok, verified} =
      Antibodies.verify("f1", %{"kind" => "expect_ok", "pattern" => "2"}, scope: dir)

    assert verified["state"] == "verified_regression_test"
    assert Antibodies.verified_count(scope: dir) == 1
  end

  test "不可复现的失败不充当门（§8.2）", %{scope: dir} do
    Antibodies.observe("f2", %{input: "raise \"boom\"", error: "boom"}, scope: dir)

    # expect_ok 永远失败（代码必 raise）→ 不可晋升
    assert {:error, {:not_reproducible, _}} =
             Antibodies.verify("f2", %{"kind" => "expect_ok", "pattern" => "ok"}, scope: dir)

    # 未验证的抗体不进确定性门
    assert {:pass, %{ran: 0}} = Antibodies.gate(scope: dir)
  end

  test "确定性门：verified 抗体零复现（§15.13）", %{scope: dir} do
    # 一个 expect_error 抗体：代码必须失败于某模式（回归信号）
    Antibodies.observe("f3", %{input: "1 / 0", error: "ArithmeticError"}, scope: dir)

    {:ok, _} =
      Antibodies.verify("f3", %{"kind" => "expect_error", "pattern" => "ArithmeticError"}, scope: dir)

    # 门通过 = 抗体断言成立（错误仍然复现 = 环境没破坏已知行为）
    assert {:pass, %{ran: 1}} = Antibodies.gate(scope: dir)

    # 一个会失败的抗体（expect_ok 但代码 raise）——先绕过 verify 的独立验证直接注入
    entry = %{
      "id" => "f4",
      "state" => "verified_regression_test",
      "tier" => "hot",
      "input" => "raise \"still broken\"",
      "check" => %{"kind" => "expect_ok", "pattern" => "ok"},
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "last_triggered_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(Path.join(dir, "f4.json"), Jason.encode!(entry))

    assert {:fail, %{failed: 1, failures: [{:fail, "f4", _}]}} = Antibodies.gate(scope: dir)
  end

  test "分层 GC：hot → warm → cold，相关变更唤醒 cold", %{scope: dir} do
    old = (System.system_time(:second) - 70 * 86_400) |> DateTime.from_unix!() |> DateTime.to_iso8601()

    entry = %{
      "id" => "old1",
      "state" => "verified_regression_test",
      "tier" => "hot",
      "input" => "1",
      "check" => %{"kind" => "expect_ok", "pattern" => "1"},
      "release_id" => "tool.x@abc",
      "last_triggered_at" => old,
      "created_at" => old
    }

    File.write!(Path.join(dir, "old1.json"), Jason.encode!(entry))

    Antibodies.gc(scope: dir)
    {:ok, after_gc} = Antibodies.get("old1", scope: dir)
    assert after_gc["tier"] == "cold"

    # 相关变更唤醒
    Antibodies.gc(scope: dir, touched_plugin_ids: ["tool.x"])
    {:ok, woken} = Antibodies.get("old1", scope: dir)
    assert woken["tier"] == "warm"
  end
end
