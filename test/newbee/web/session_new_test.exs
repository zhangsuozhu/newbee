defmodule Newbee.Web.SessionNewTest do
  use ExUnit.Case, async: false

  # /new：异步重启，不阻塞 session.state；广播 session_cleared 并清空 transcript
  test "/new async restart does not block state and clears transcript" do
    root = Path.join(System.tmp_dir!(), "newbee-session-new-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "model.json")
    sid = "test_new_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)

    File.write!(
      config_path,
      Jason.encode!(%{
        "providers" => %{
          "stub" => %{
            "baseUrl" => "https://example.test/v1",
            "apiKey" => "test",
            "models" => ["dummy"]
          }
        },
        "roles" => %{"default" => %{"provider" => "stub", "model" => "dummy"}}
      })
    )

    old_config = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", config_path)

    sess = Newbee.Session.open(sid)
    Newbee.Session.append(sess, %{"role" => "user", "content" => "old message"})
    assert length(Newbee.Session.messages(sess)) == 1

    {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :local, cwd: File.cwd!())
    {:ok, client} = Newbee.Web.Session.client_for_session(sid)

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: ev,
        session_id: sid,
        root: File.cwd!(),
        client_fun: fn _messages, _on_text -> {:error, :unused} end
      )

    st = %Newbee.Web.Session{
      sid: sid,
      kernel: kernel,
      client: client,
      busy: false,
      booting: false,
      queue: :queue.new()
    }

    Newbee.Bus.subscribe()

    on_exit(fn ->
      Newbee.Bus.unsubscribe()
      if old_config, do: System.put_env("NEWBEE_MODEL_JSON", old_config), else: System.delete_env("NEWBEE_MODEL_JSON")

      if Process.alive?(kernel),
        do:
          (try do
             GenServer.stop(kernel)
           catch
             _, _ -> :ok
           end)

      if Process.alive?(ev),
        do:
          (try do
             GenServer.stop(ev)
           catch
             _, _ -> :ok
           end)

      # 清理重启产生的 kernel（若已落地）
      receive do
        {:kernel_restarted, {:ok, new_kernel}} ->
          if Process.alive?(new_kernel),
            do:
              (try do
                 GenServer.stop(new_kernel)
               catch
                 _, _ -> :ok
               end)
      after
        0 -> :ok
      end

      Newbee.Session.delete(sid)
      File.rm_rf!(root)
    end)

    t0 = System.monotonic_time(:millisecond)
    {:noreply, new_st} = Newbee.Web.Session.handle_cast({:prompt, "/new"}, st)
    dt = System.monotonic_time(:millisecond) - t0

    assert dt < 500, "restart_kernel must be async, took #{dt}ms"
    assert new_st.booting == true
    assert new_st.kernel == nil
    assert Newbee.Session.messages(Newbee.Session.open(sid)) == []
    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :session_cleared, _}}, 500
    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :session_renewed, %{sessionId: ^sid}}}, 500

    assert {:reply, reply, _} = Newbee.Web.Session.handle_call(:state, self(), new_st)
    assert reply.sid == sid
    assert reply.booting == true

    # 等后台重启完成（成功或失败都不阻塞）
    receive do
      {:kernel_restarted, {:ok, new_kernel}} ->
        if Process.alive?(new_kernel), do: GenServer.stop(new_kernel)

      {:kernel_restarted, {:error, _}} ->
        :ok
    after
      4000 -> :ok
    end
  end

  @tag :node
  @tag timeout: 120_000
  test "异步 boot worker 退出后会话 evaluator 仍存活" do
    root = Path.join(System.tmp_dir!(), "newbee-session-evaluator-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "model.json")
    sid = "evaluator_owner_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)

    File.write!(
      config_path,
      Jason.encode!(%{
        "providers" => %{
          "stub" => %{
            "baseUrl" => "https://example.test/v1",
            "apiKey" => "test",
            "models" => ["dummy"]
          }
        },
        "roles" => %{"default" => %{"provider" => "stub", "model" => "dummy"}}
      })
    )

    old_config = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", config_path)

    on_exit(fn ->
      Newbee.Web.Session.destroy(sid)
      if old_config, do: System.put_env("NEWBEE_MODEL_JSON", old_config), else: System.delete_env("NEWBEE_MODEL_JSON")
      File.rm_rf!(root)
    end)

    assert {:ok, session, ^sid} = Newbee.Web.Session.ensure(sid, File.cwd!())

    state =
      Enum.reduce_while(1..600, nil, fn _, _ ->
        state = :sys.get_state(session)

        if is_pid(state.kernel) and not state.booting do
          {:halt, state}
        else
          Process.sleep(100)
          {:cont, nil}
        end
      end)

    assert state != nil
    assert {:ok, {evaluator, _scope}} = Newbee.SessionEvaluators.lookup(state.kernel)

    # boot worker 收到 ACK 后已经退出；旧实现会在这里连带正常停止 evaluator。
    Process.sleep(200)
    assert Process.alive?(evaluator)
    assert :ok = Newbee.DEE.Evaluator.set_cwd(evaluator, File.cwd!())

    result = Newbee.DEE.Evaluator.eval(evaluator, "File.cwd!()")
    assert result.status == :ok
    assert result.cwd == File.cwd!()
  end

  test "handle_call :state is non-blocking snapshot" do
    st = %Newbee.Web.Session{sid: "snapshot", busy: true, booting: false, client: nil, queue: :queue.new()}
    assert {:reply, m, ^st} = Newbee.Web.Session.handle_call(:state, self(), st)
    assert m.busy == true
  end
end
