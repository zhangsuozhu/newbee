defmodule Newbee.SessionStallRegressionTest do
  use ExUnit.Case, async: false

  alias Newbee.LLM.Client
  alias Newbee.Tools.Edit.SnapshotStore
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  defp done_call(id) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{"id" => id, "type" => "function", "function" => %{"name" => "done", "arguments" => "{}"}}
      ]
    }
  end

  test "sanitize preserves new done order without placeholder" do
    msgs = [
      %{"role" => "user", "content" => "hi"},
      done_call("call_done"),
      %{"role" => "tool", "tool_call_id" => "call_done", "content" => "ok done"},
      %{"role" => "assistant", "content" => "done summary", "done" => true}
    ]

    san = Client.sanitize_messages(msgs)

    assert Enum.any?(san, fn m ->
             m["role"] == "tool" and m["tool_call_id"] == "call_done" and m["content"] == "ok done"
           end)

    refute Enum.any?(san, fn m ->
             m["role"] == "tool" and is_binary(m["content"]) and String.contains?(m["content"], "因进程重启")
           end)

    # order: tool before done summary
    tool_idx = Enum.find_index(san, fn m -> m["role"] == "tool" and m["tool_call_id"] == "call_done" end)
    done_idx = Enum.find_index(san, fn m -> m["role"] == "assistant" and m["done"] == true end)
    assert tool_idx != nil and done_idx != nil and tool_idx < done_idx
  end

  test "sanitize repairs legacy done order by reordering tool before done" do
    msgs = [
      %{"role" => "user", "content" => "hi"},
      done_call("call_legacy"),
      %{"role" => "assistant", "content" => "legacy summary", "done" => true},
      %{"role" => "tool", "tool_call_id" => "call_legacy", "content" => "ok done"}
    ]

    san = Client.sanitize_messages(msgs)
    # real tool must survive, no placeholder for this id
    assert Enum.any?(san, fn m ->
             m["role"] == "tool" and m["tool_call_id"] == "call_legacy" and m["content"] == "ok done"
           end)

    refute Enum.any?(san, fn m ->
             m["role"] == "tool" and m["tool_call_id"] == "call_legacy" and is_binary(m["content"]) and
               String.contains?(m["content"], "因进程重启")
           end)

    tool_idx = Enum.find_index(san, fn m -> m["role"] == "tool" and m["tool_call_id"] == "call_legacy" end)
    done_idx = Enum.find_index(san, fn m -> m["role"] == "assistant" and m["done"] == true end)
    assert tool_idx < done_idx
  end

  test "sanitize still placeholders truly dangling calls" do
    msgs = [
      %{"role" => "user", "content" => "hi"},
      done_call("call_orphan"),
      %{"role" => "user", "content" => "next"}
    ]

    san = Client.sanitize_messages(msgs)

    assert Enum.any?(san, fn m ->
             m["role"] == "tool" and m["tool_call_id"] == "call_orphan" and is_binary(m["content"]) and
               String.contains?(m["content"], "因进程重启")
           end)
  end

  test "snapshot record clears lock and stale lock is preempted" do
    tmp = Path.join(System.tmp_dir!(), "stall_snap_" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(tmp)
    orig = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      if File.cwd!() == tmp, do: File.cd!(orig)
      File.rm_rf(tmp)
      Application.delete_env(:newbee, :snapshot_lock_timeout_ms)
      Application.delete_env(:newbee, :snapshot_lock_stale_ms)
    end)

    SnapshotStore.clear()
    path = Path.join(tmp, "a.txt")
    File.write!(path, "hello\n")
    tag = SnapshotStore.record(path, "hello\n", [1])
    assert is_binary(tag)
    # lock file must be gone after success
    hash = :crypto.hash(:sha256, tmp) |> binary_part(0, 4) |> Base.encode16(case: :lower)
    lock = Path.join([Newbee.GlobalStore.root(), "edit_snapshots", hash <> ".lock"])
    refute File.exists?(lock)

    # stale lock from 2020 must be preempted immediately
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "stale-owner")
    File.touch!(lock, {{2020, 1, 1}, {0, 0, 0}})
    tag2 = SnapshotStore.record(path, "hello2\n", [1])
    assert is_binary(tag2)
    refute File.exists?(lock)
  end

  test "snapshot lock timeout carries diagnostics without request body" do
    tmp = Path.join(System.tmp_dir!(), "stall_lock_" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(tmp)
    orig = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      if File.cwd!() == tmp, do: File.cd!(orig)
      File.rm_rf(tmp)
      Application.delete_env(:newbee, :snapshot_lock_timeout_ms)
      Application.delete_env(:newbee, :snapshot_lock_stale_ms)
    end)

    SnapshotStore.clear()
    Application.put_env(:newbee, :snapshot_lock_timeout_ms, 200)
    Application.put_env(:newbee, :snapshot_lock_stale_ms, 60_000)

    hash = :crypto.hash(:sha256, tmp) |> binary_part(0, 4) |> Base.encode16(case: :lower)
    lock = Path.join([Newbee.GlobalStore.root(), "edit_snapshots", hash <> ".lock"])
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "fresh-owner-for-timeout")

    path = Path.join(tmp, "b.txt")
    File.write!(path, "x\n")

    assert_raise RuntimeError, fn -> SnapshotStore.record(path, "x\n", [1]) end

    try do
      SnapshotStore.record(path, "x\n", [1])
    rescue
      e in RuntimeError ->
        msg = Exception.message(e)
        assert msg =~ "snapshot store lock timeout"
        assert msg =~ "waited="
        assert msg =~ "stale_ms="
        assert msg =~ "owner=fresh-owner-for-timeout"
        assert msg =~ "node="
        refute msg =~ "hello-secret-body"
    end

    File.rm(lock)
  end

  test "loop done second submit has no placeholder for real done" do
    {:ok, ev} = Evaluator.start(mode: :local)

    done = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "call_done2",
          "type" => "function",
          "function" => %{"name" => "done", "arguments" => Jason.encode!(%{summary: "second ok"})}
        }
      ]
    }

    {:ok, agent} = Agent.start_link(fn -> 0 end)

    client_fun = fn messages, _on_text ->
      n = Agent.get_and_update(agent, fn c -> {c, c + 1} end)

      if n == 0 do
        {:ok, done, %{}}
      else
        # second turn must see real tool, not placeholder
        assert Enum.any?(messages, fn m ->
                 m["role"] == "tool" and m["tool_call_id"] == "call_done2" and m["content"] == "✓ done"
               end)

        refute Enum.any?(messages, fn m ->
                 m["role"] == "tool" and is_binary(m["content"]) and String.contains?(m["content"], "因进程重启")
               end)

        {:ok, %{"role" => "assistant", "content" => "after done", "tool_calls" => []}, %{}}
      end
    end

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: client_fun)
    assert {:done, "second ok"} = Loop.submit(kernel, "first")
    assert {:text, "after done"} = Loop.submit(kernel, "second")
    GenServer.stop(kernel)
  end
end
