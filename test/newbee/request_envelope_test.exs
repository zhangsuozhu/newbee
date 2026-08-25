defmodule Newbee.RequestEnvelopeTest do
  use ExUnit.Case, async: false

  alias Newbee.{RequestEnvelope, Session}

  setup do
    id = "env_#{:erlang.unique_integer([:positive])}"
    s = Session.open(id)
    on_exit(fn -> cleanup(id) end)
    {:ok, session: s, id: id}
  end

  defp cleanup(id) do
    File.rm(Path.join(System.user_home!(), ".newbee/sessions/#{id}.jsonl"))
    File.rm_rf(Path.join(System.user_home!(), ".newbee/session-artifacts/#{id}"))
  end

  defp client(opts \\ []) do
    Newbee.LLM.Client.new(
      Keyword.merge(
        [model: "test/model", api_key: "t", base_url: "http://localhost"],
        opts
      )
    )
  end

  defp msgs, do: [%{"role" => "system", "content" => "S"}, %{"role" => "user", "content" => "U"}]
  defp tools, do: [%{"type" => "function", "function" => %{"name" => "run_elixir"}}]

  test "record → load 往返，字段齐全且消息深比较一致", %{session: s} do
    assert :ok = RequestEnvelope.record(s, client(), msgs(), tools())
    env = RequestEnvelope.load(s)

    assert env["version"] == 1
    assert env["base_url"] == "http://localhost"
    assert env["model"] == "test/model"
    assert env["tools"] == tools()
    assert env["messages"] == msgs()
    assert env["message_count"] == 2
    assert is_binary(env["sha256"])
    assert is_binary(env["recorded_at"])
  end

  test "load 容错：缺失 → nil", %{session: s} do
    assert RequestEnvelope.load(s) == nil
  end

  test "load 容错：损坏 JSON → nil", %{session: s} do
    File.write!(RequestEnvelope.path(s), "not json")
    assert RequestEnvelope.load(s) == nil
  end

  test "load 容错：版本不符 → nil", %{session: s} do
    File.write!(RequestEnvelope.path(s), Jason.encode!(%{"version" => 99, "messages" => []}))
    assert RequestEnvelope.load(s) == nil
  end

  test "load 容错：缺关键字段 → nil", %{session: s} do
    File.write!(RequestEnvelope.path(s), Jason.encode!(%{"version" => 1}))
    assert RequestEnvelope.load(s) == nil
  end

  test "hit_eligible?：route 一致 → true；任一不一致 → false", %{session: s} do
    :ok = RequestEnvelope.record(s, client(), msgs(), tools())
    env = RequestEnvelope.load(s)

    assert RequestEnvelope.hit_eligible?(env, client())
    refute RequestEnvelope.hit_eligible?(env, client(model: "other"))
    refute RequestEnvelope.hit_eligible?(env, client(base_url: "http://other"))
  end

  test "record no-op：非 LLM client 或不落文件", %{session: s} do
    assert :ok = RequestEnvelope.record(s, %{}, msgs(), tools())
    refute File.exists?(RequestEnvelope.path(s))
  end

  test "record no-op：session nil", %{} do
    assert :ok = RequestEnvelope.record(nil, client(), msgs(), tools())
  end

  test "原子写：无 tmp 残留", %{session: s} do
    :ok = RequestEnvelope.record(s, client(), msgs(), tools())
    refute File.exists?(RequestEnvelope.path(s) <> ".tmp")
    assert File.exists?(RequestEnvelope.path(s))
  end
end
