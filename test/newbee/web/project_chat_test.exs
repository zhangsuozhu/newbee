defmodule Newbee.Web.ProjectChatTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.Chat.{Room, Runner}
  alias Newbee.Collaboration.CrossHost.{Auth, Group, Store, Transport}

  defmodule ModelEndpoint do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      body = conn.body_params

      valid =
        body["max_tokens"] in [800, 1600] and is_list(body["messages"]) and body["tools"] == nil and
          (body["model"] != "deepseek-v4-flash" or get_in(body, ["thinking", "type"]) == "disabled")

      response =
        if valid do
          %{
            choices: [%{message: %{role: "assistant", content: "建议：先验证句柄关闭顺序。依据：当前议题。分歧：尚无独立复现。验收：两台主机回归通过。"}}],
            usage: %{prompt_tokens: 90, completion_tokens: 40, total_tokens: 130}
          }
        else
          %{error: "invalid model request"}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(response))
    end
  end

  setup do
    Store.clear()
    server = start_supervised!({Bandit, plug: Newbee.Web.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, group, _} = Group.create("HTTP聊天室", "project-chat-test")
    {:ok, group, a} = Auth.issue_device(group, "a", "主机A")
    {:ok, group, b} = Auth.issue_device(group, "b", "主机B")
    Store.put_group(group)
    %{base: "http://127.0.0.1:#{port}", gid: group["id"], a: a, b: b}
  end

  defp rpc(base, action, payload, headers \\ []) do
    response = Req.post!(base <> "/api/" <> action, json: %{rpcId: "chat-test", payload: payload}, headers: headers)
    response.body["result"]
  end

  defp chat(base, gid, action, params \\ %{}),
    do: rpc(base, "xgroup.chat", %{groupId: gid, action: action, params: params})

  defp remote(base, dev, action, params \\ %{}),
    do:
      Transport.rpc(base, "xgroup.bridge.chat", %{"deviceId" => dev["id"], "action" => action, "params" => params},
        device_token: dev["plain"],
        allow_insecure: true
      )

  test "actual HTTP bridge authenticates, prevents impersonation and returns owned work", %{
    base: base,
    gid: gid,
    a: a,
    b: b
  } do
    assert {:ok, ra} = remote(base, a, "representative.create", %{"device_id" => b["id"], "name" => "A代表"})
    assert ra["device_id"] == a["id"]
    assert {:ok, _} = remote(base, b, "representative.create", %{"name" => "B代表"})

    assert {:error, "forbidden", _} =
             remote(base, b, "representative.update", %{"representative_id" => ra["id"], "name" => "冒充"})

    assert {:ok, topic} = remote(base, a, "topic.open", %{"title" => "接口冲突", "problem" => "两台主机的实现不一致"})
    assert {:error, "bad_request", _} = remote(base, b, "discussion.start", %{"topic_id" => topic["id"]})
    assert {:ok, _} = remote(base, a, "discussion.start", %{"topic_id" => topic["id"], "rounds" => 1})

    assert {:ok, polled} =
             Transport.rpc(base, "xgroup.bridge.poll", %{"deviceId" => b["id"]},
               device_token: b["plain"],
               allow_insecure: true
             )

    assert length(polled["chat_jobs"]) == 1
    assert hd(polled["chat_jobs"])["device_id"] == b["id"]
    assert polled["snapshot"]["chat"]["group_id"] == gid
    assert {:error, _, _} = remote(base, %{a | "plain" => "invalid"}, "snapshot")
    assert %{"error" => _} = rpc(base, "xgroup.bridge.chat", %{"deviceId" => a["id"], "action" => "snapshot"})
    assert {:error, "bad_request", _} = remote(base, a, "settings", %{"auto_discuss" => true})
  end

  test "Web UI assets and RPC work over HTTP, invalid payloads do not crash the room", %{base: base, gid: gid, a: a} do
    assert %{"ok" => _} =
             chat(base, gid, "representative.create", %{device_id: a["id"], name: "<img src=x onerror=alert(1)>"})

    assert %{"error" => _} = chat(base, gid, "representative.create", %{device_id: a["id"], name: []})
    assert %{"ok" => %{"representatives" => [_]}} = chat(base, gid, "snapshot")
    # 登录后主页是蜂群；会话界面在 /workspace.html，静态资源与会话语义仍照常提供。
    assert Req.get!(base <> "/").body =~ "/colony/app.js"
    assert Req.get!(base <> "/workspace.html").body =~ "/app.js"
    response = Req.get!(base <> "/project-chat.js")
    assert response.status == 200
    assert response.body =~ "window.NewbeeProjectChat"
    assert response.body =~ "textContent"
    refute response.body =~ "innerHTML"
    assert :ok = Newbee.Environment.ToolContract.validate_builtin(Newbee.Tools.Hive)
  end

  test "real LLM HTTP protocol and remote return path complete a bounded discussion", %{
    base: base,
    gid: gid,
    a: a,
    b: b
  } do
    model_server = start_supervised!({Bandit, plug: ModelEndpoint, port: 0, ip: {127, 0, 0, 1}}, id: :chat_model)
    {:ok, {_, port}} = ThousandIsland.listener_info(model_server)
    path = Path.join(Newbee.GlobalStore.root(), "chat-model-#{System.unique_integer([:positive])}.json")

    config = %{
      providers: %{
        deepseek: %{
          baseUrl: "http://127.0.0.1:#{port}",
          api: "openai-completions",
          apiKey: "fixture-only",
          models: ["deepseek-v4-flash"],
          contextWindow: 32000
        }
      },
      roles: %{
        default: %{provider: "deepseek", model: "deepseek-v4-flash"},
        advisor: %{provider: "deepseek", model: "deepseek-v4-flash"}
      }
    }

    File.write!(path, Jason.encode!(config))
    previous = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", path)

    on_exit(fn ->
      if previous, do: System.put_env("NEWBEE_MODEL_JSON", previous), else: System.delete_env("NEWBEE_MODEL_JSON")
      File.rm(path)
    end)

    for dev <- [a, a, b], do: assert({:ok, _} = remote(base, dev, "representative.create", %{}))
    assert %{"ok" => topic} = chat(base, gid, "topic.open", %{title: "实际模型协议验证", problem: "讨论跨平台文件句柄问题"})
    assert %{"ok" => _} = chat(base, gid, "discussion.start", %{topic_id: topic["id"], rounds: 1})
    runner = __MODULE__.RemoteRunner
    start_supervised!({Runner, name: runner, tick: false})

    for _ <- 1..6 do
      for dev <- [a, b] do
        assert {:ok, payload} =
                 Transport.rpc(base, "xgroup.bridge.poll", %{"deviceId" => dev["id"]},
                   device_token: dev["plain"],
                   allow_insecure: true
                 )

        route = {base, dev["id"], [allow_insecure: true, device_token: dev["plain"]]}
        Runner.enqueue(payload["chat_jobs"], route, runner)
      end

      wait_idle(runner)
    end

    result = Room.snapshot(gid)
    assert hd(result["topics"])["status"] == "proposed"
    # 3 independent + 2 discussing (the last speaker is skipped as silent) + 1 summary.
    assert hd(result["topics"])["calls"] == 6
    assert hd(result["topics"])["skips"] == 1
    assert hd(result["topics"])["usage"]["total_tokens"] == 780
    assert Enum.count(result["messages"], &(&1["kind"] == "agent")) == 6
    # Silence is recorded publicly instead of costing a model call.
    assert Enum.count(result["messages"], &(&1["kind"] == "skipped")) == 1

    assert Enum.any?(result["messages"], &(&1["device_id"] == a["id"]))
    assert Enum.any?(result["messages"], &(&1["device_id"] == b["id"]))
  end

  defp wait_idle(name, tries \\ 250)
  defp wait_idle(_, 0), do: flunk("runner timeout")

  defp wait_idle(name, tries) do
    state = :sys.get_state(name)

    if state.active == nil and state.queue == [],
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_idle(name, tries - 1)
        )
  end
end
