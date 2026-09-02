defmodule Newbee.DEE.EvaluatorTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.Evaluator

  setup do
    {:ok, pid} = Evaluator.start(mode: :local)
    %{ev: pid}
  end

  test "求值并返回值", %{ev: ev} do
    r = Evaluator.eval(ev, "1 + 1", [])
    assert r.status == :ok
    assert r.value == "2"
  end

  test "绑定跨调用持久（模型的 IEx）", %{ev: ev} do
    Evaluator.eval(ev, "content = \"hello dee\"", [])
    r = Evaluator.eval(ev, "String.upcase(content)", [])
    assert r.status == :ok
    assert r.value =~ "HELLO DEE"
  end

  test "stdout 被捕获", %{ev: ev} do
    r = Evaluator.eval(ev, "IO.puts(\"from cell\")", [])
    assert r.output =~ "from cell"
  end

  test "错误返回格式化信息，绑定不污染", %{ev: ev} do
    Evaluator.eval(ev, "good = 1", [])
    r = Evaluator.eval(ev, "raise \"boom\"", [])
    assert r.status == :error
    assert r.error =~ "boom"
    # 失败调用前的绑定仍在
    assert Enum.any?(Evaluator.bindings_summary(ev), &(&1.name == :good))
  end

  test "默认 cell 不设置固定墙钟截止" do
    assert Newbee.DEE.EvalWorker.default_timeout() == :infinity
  end

  test "超时返回错误", %{ev: ev} do
    r = Evaluator.eval(ev, "Process.sleep(:infinity)", timeout: 100)
    assert r.status == :error
    assert r.error =~ "timeout"
  end

  test "外部 interrupt 可杀掉正在运行的 cell，worker 仍可复用", %{ev: ev} do
    task = Task.async(fn -> Evaluator.eval(ev, "Process.sleep(:infinity)") end)
    assert wait_until(fn -> is_pid(Newbee.DEE.EvalWorker.active_pid(ev)) end, 15_000)

    assert :ok = Evaluator.interrupt(ev)
    assert %{status: :error, error: "interrupted"} = Task.await(task, 5_000)
    assert %{status: :ok, value: "2"} = Evaluator.eval(ev, "1 + 1")
  end

  test "调用者死亡会取消无限 cell，worker 仍可复用", %{ev: ev} do
    caller = spawn(fn -> Evaluator.eval(ev, "Process.sleep(:infinity)") end)
    assert wait_until(fn -> is_pid(Newbee.DEE.EvalWorker.active_pid(ev)) end, 5_000)

    Process.exit(caller, :kill)

    follow_up = Task.async(fn -> Evaluator.eval(ev, "1 + 1") end)
    assert %{status: :ok, value: "2"} = Task.await(follow_up, 5_000)
  end

  test "bindings_summary 只给摘要不给内容", %{ev: ev} do
    Evaluator.eval(ev, "secret = \"x\" |> String.duplicate(100_000)", [])
    [b] = Evaluator.bindings_summary(ev)
    assert b.name == :secret
    assert b.type == :binary
    assert b.size >= 10_000
  end

  test "reset 清空绑定", %{ev: ev} do
    Evaluator.eval(ev, "x = 1", [])
    Evaluator.reset(ev)
    assert Evaluator.bindings_summary(ev) == []
  end

  test "每个 evaluator 在 cell 前恢复自己的稳定工作根" do
    original = File.cwd!()
    base = Path.join(System.tmp_dir!(), "newbee-evaluator-cwd-#{System.unique_integer([:positive])}")
    root_a = Path.join(base, "a")
    root_b = Path.join(base, "b")
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)
    {:ok, ev_a} = Evaluator.start(mode: :local, cwd: root_a)
    {:ok, ev_b} = Evaluator.start(mode: :local, cwd: root_b)

    on_exit(fn ->
      if Process.alive?(ev_a), do: GenServer.stop(ev_a)
      if Process.alive?(ev_b), do: GenServer.stop(ev_b)
      if File.dir?(original), do: File.cd!(original)
      File.rm_rf!(base)
    end)

    assert %{status: :ok, value: value_a, cwd: ^root_a} = Evaluator.eval(ev_a, "File.cwd!()")
    assert value_a == inspect(root_a)
    assert %{status: :ok, value: value_b, cwd: ^root_b} = Evaluator.eval(ev_b, "File.cwd!()")
    assert value_b == inspect(root_b)

    assert %{status: :ok, cwd: ^root_b} = Evaluator.eval(ev_a, "File.cd!(" <> inspect(root_b) <> ")")

    assert %{status: :ok, value: restored, cwd: ^root_a} =
             Evaluator.eval(ev_a, "File.cwd!()")

    assert restored == inspect(root_a)
    shell = Evaluator.eval(ev_a, ~S|Newbee.Tools.Run.sh("pwd").output|)
    assert shell.status == :ok
    assert shell.value =~ root_a
  end

  defp wait_until(predicate, remaining) when remaining <= 0, do: predicate.()

  defp wait_until(predicate, remaining) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      wait_until(predicate, remaining - 10)
    end
  end
end
