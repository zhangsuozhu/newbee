defmodule Newbee.Web.SessionModelRestoreTest do
  use ExUnit.Case, async: false

  test "restored model keeps its per-model API protocol" do
    root = Path.join(System.tmp_dir!(), "newbee-session-model-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "model.json")
    sid = "test_model_restore_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)

    File.write!(
      config_path,
      Jason.encode!(%{
        "providers" => %{
          "opencode" => %{
            "baseUrl" => "https://example.test/v1",
            "apiKey" => "test",
            "models" => ["default-model", "muse-spark-1.2-contributor"],
            "modelApis" => %{"muse-spark-1.2-contributor" => "openai-responses"}
          }
        },
        "roles" => %{
          "default" => %{"provider" => "opencode", "model" => "default-model"}
        }
      })
    )

    old_config = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", config_path)
    Newbee.Session.open(sid)
    :ok = Newbee.Session.set_provider(sid, "opencode")
    :ok = Newbee.Session.set_model(sid, "muse-spark-1.2-contributor")
    :ok = Newbee.Session.set_effort(sid, "off")

    on_exit(fn ->
      if old_config,
        do: System.put_env("NEWBEE_MODEL_JSON", old_config),
        else: System.delete_env("NEWBEE_MODEL_JSON")

      File.rm_rf!(root)
      Newbee.Session.delete(sid)
    end)

    assert {:ok, client} = Newbee.Web.Session.client_for_session(sid)
    assert client.provider == "opencode"
    assert client.model == "muse-spark-1.2-contributor"
    assert client.api == "openai-responses"
    assert client.reasoning_effort == "none"
  end

  test "busy 会话拒绝在 turn 中途切换工作根" do
    st = %Newbee.Web.Session{sid: "busy-workspace", busy: true}

    assert {:reply, {:error, :session_busy}, ^st} =
             Newbee.Web.Session.handle_call({:set_cwd, File.cwd!()}, self(), st)
  end

  test "异步 boot 完成时按 Session 最新工作根重新对齐 kernel" do
    original = File.cwd!()
    base = Path.join(System.tmp_dir!(), "newbee-web-boot-cwd-#{System.unique_integer([:positive])}")
    root_a = Path.join(base, "a")
    root_b = Path.join(base, "b")
    sid = "test_boot_cwd_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)
    {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :local, cwd: root_a)

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        root: root_a,
        client_fun: fn _messages, _on_text -> {:error, :unused} end
      )

    on_exit(fn ->
      if Process.alive?(kernel), do: GenServer.stop(kernel)
      if Process.alive?(ev), do: GenServer.stop(ev)
      if File.dir?(original), do: File.cd!(original)
      Newbee.Session.delete(sid)
      File.rm_rf!(base)
    end)

    :ok = Newbee.Session.set_cwd(sid, root_b)
    st = %Newbee.Web.Session{sid: sid, booting: true, client: %{}, queue: :queue.new()}

    assert {:noreply, next} = Newbee.Web.Session.handle_info({:kernel_booted, {:ok, kernel}}, st)
    assert next.kernel == kernel
    refute next.booting
    assert :sys.get_state(kernel).root == root_b
    assert Newbee.DEE.Evaluator.info(ev).cwd == root_b
  end
end
