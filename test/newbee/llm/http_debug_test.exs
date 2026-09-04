defmodule Newbee.LLM.HttpDebugTest do
  use ExUnit.Case, async: false
  alias Newbee.LLM.HttpDebug

  setup do
    prev = HttpDebug.enabled?()
    :ok = HttpDebug.clear()
    :ok = HttpDebug.set_enabled(true) |> then(fn _ -> :ok end)
    HttpDebug.clear()

    on_exit(fn ->
      HttpDebug.clear()
      HttpDebug.set_enabled(prev)
    end)

    :ok
  end

  test "disabled start returns nil and records nothing" do
    HttpDebug.set_enabled(false)
    assert HttpDebug.start_exchange(%{req_body: %{a: 1}}) == nil
    assert HttpDebug.list(10, 0) == []
    HttpDebug.set_enabled(true)
  end

  test "full lifecycle with redacted auth header" do
    id =
      HttpDebug.start_exchange(%{
        session_id: "s1",
        model: "m",
        base_url: "https://x",
        endpoint: "/chat/completions",
        method: "POST",
        url: "https://x/chat/completions",
        api: "chat",
        req_headers: [
          {"authorization", "Bearer sk-secret1234567890"},
          {"content-type", "application/json"}
        ],
        req_body: %{model: "m", messages: [%{role: "user", content: "hi"}]}
      })

    assert is_integer(id)
    HttpDebug.note_current_response(200, %{"content-type" => ["text/event-stream"]})
    HttpDebug.append_raw("data: 1\n\n")
    HttpDebug.finish_current({:ok, %{"role" => "assistant", "content" => "hi"}, %{}})

    [sum] = HttpDebug.list(10, 0)
    assert sum.id == id
    assert sum.phase == "done"
    assert sum.status == 200
    assert sum.sse_bytes == 9

    full = HttpDebug.get(id)
    assert full.session_id == "s1"
    assert full.req_body =~ "hi"
    assert full.sse_raw == "data: 1\n\n"
    [[k, v]] = Enum.filter(full.req_headers, fn [h, _] -> h == "authorization" end)
    assert k == "authorization"
    assert v =~ "7890"
    refute v =~ "sk-secret1234567890"
    assert full.resp_body =~ "hi"
  end

  test "error and interrupted phases" do
    HttpDebug.start_exchange(%{req_body: %{}})
    HttpDebug.finish_current({:error, {:http_error, 429, "busy"}})
    [sum] = HttpDebug.list(10, 0)
    assert sum.phase == "error"
    assert sum.status == 429

    HttpDebug.start_exchange(%{req_body: %{}})
    HttpDebug.start_exchange(%{req_body: %{}})
    HttpDebug.finish_current({:interrupted, "part"})
    entries = HttpDebug.list(10, 0)
    assert List.last(entries).phase == "interrupted"
  end

  test "list since filtering and clear" do
    HttpDebug.start_exchange(%{req_body: %{a: 1}}) |> then(fn id -> HttpDebug.finish(id, {:ok, %{}, %{}}) end)
    HttpDebug.start_exchange(%{req_body: %{a: 2}}) |> then(fn id -> HttpDebug.finish(id, {:ok, %{}, %{}}) end)
    all = HttpDebug.list(10, 0)
    assert length(all) == 2
    [first | _] = all
    rest = HttpDebug.list(10, first.id)
    assert length(rest) == 1
    HttpDebug.clear()
    assert HttpDebug.list(10, 0) == []
  end

  test "session id from cache key" do
    assert HttpDebug.session_id_from_cache_key("newbee-abc123") == "abc123"
    assert HttpDebug.session_id_from_cache_key(nil) == nil
    assert HttpDebug.session_id_from_cache_key("other") == nil
  end
end
