defmodule Newbee.Colony.ConversationExecutionTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, ConversationWork, Runtime}
  @moduletag :tmp_dir

  defmodule Endpoint do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      messages = conn.body_params["messages"]
      latest = Enum.filter(messages, &(&1["role"] == "user")) |> List.last()
      text = if latest, do: to_string(latest["content"]), else: ""

      summary =
        cond do
          String.contains?(text, "【分工计划输出契约】") ->
            Jason.encode!(%{
              "summary" => "两项独立分析后集成验证",
              "tasks" => [
                %{
                  "id" => "analysis",
                  "title" => "核对目标",
                  "scope" => "只读核对项目目标与约束，给出证据。",
                  "depends_on" => [],
                  "acceptance" => ["报告约束与证据"]
                },
                %{
                  "id" => "review",
                  "title" => "独立验证",
                  "scope" => "独立检查目标与边界，给出验证报告。",
                  "depends_on" => [],
                  "acceptance" => ["报告验证结果与限制"]
                }
              ]
            })

          String.contains?(text, "【本阶段输出契约") ->
            ~s({"route":"self","reason":"确定性测试：范围明确","participants":[]})

          true ->
            "确定性模型协议已完成：目标和约束已核对；本测试不声称真实模型质量。"
        end

      message = fixture_message(messages, text, summary, conn.body_params["tools"] || [])
      calls = Map.get(message, :tool_calls, []) |> Enum.map(&Map.put(&1, :index, 0))
      delta = if calls == [], do: %{role: "assistant", content: summary}, else: %{role: "assistant", tool_calls: calls}
      body = %{choices: [%{index: 0, delta: delta, finish_reason: nil}]}

      ending = %{
        choices: [%{index: 0, delta: %{}, finish_reason: if(calls == [], do: "stop", else: "tool_calls")}],
        usage: %{prompt_tokens: 10, completion_tokens: 10, total_tokens: 20}
      }

      if conn.body_params["stream"] do
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(
          200,
          "data: " <> Jason.encode!(body) <> "\n\ndata: " <> Jason.encode!(ending) <> "\n\ndata: [DONE]\n\n"
        )
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            choices: [%{message: message, finish_reason: if(calls == [], do: "stop", else: "tool_calls")}],
            usage: %{prompt_tokens: 10, completion_tokens: 10, total_tokens: 20}
          })
        )
      end
    end

    # Protocol fixture: the real Loop executes the offered tool in its own DEE. This
    # verifies isolated writes and real-file integration, without claiming model quality.
    defp fixture_message(messages, text, summary, tools) do
      task =
        Newbee.Colony.Store.list_tasks()
        |> Enum.find(
          &String.contains?(
            text,
            Jason.encode!(%{"id" => &1["id"]}) |> String.trim_leading("{") |> String.trim_trailing("}")
          )
        )

      tool_enabled = Enum.any?(tools, &(get_in(&1, ["function", "name"]) == "run_elixir"))

      call_id =
        if task, do: "fixture-write-" <> task["id"] <> "-" <> Integer.to_string(task["context_revision"]), else: "none"

      used = Enum.any?(messages, fn message -> Enum.any?(message["tool_calls"] || [], &(&1["id"] == call_id)) end)

      if task && task["mode"] == "execution" && tool_enabled && not used do
        code =
          if task["conversation_child"] == true do
            {:ok, root} = Newbee.Colony.Store.get_task(task["workflow_root"])
            index = Enum.find_index(root["workflow"]["children"], &(&1 == task["id"]))
            file = if index == 0, do: "implementation.txt", else: "verification.txt"
            path = Path.join(task["workspace"]["path"], file)

            "Newbee.Tools.Fs.write!(" <>
              inspect(path) <> ", " <> inspect(file <> " produced in isolated worker\n") <> ")"
          else
            Enum.map(task["workflow"]["children"], fn id ->
              {:ok, child} = Newbee.Colony.Store.get_task(id)
              index = Enum.find_index(task["workflow"]["children"], &(&1 == id))
              file = if index == 0, do: "implementation.txt", else: "verification.txt"
              source = Path.join(child["workspace"]["path"], file)
              target = Path.join(task["workspace"]["path"], file)
              "Newbee.Tools.Fs.write!(" <> inspect(target) <> ", Newbee.Tools.Fs.read!(" <> inspect(source) <> "))"
            end)
            |> Enum.join("\n")
          end

        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: call_id,
              type: "function",
              function: %{name: "run_elixir", arguments: Jason.encode!(%{code: code, title: "确定性验收：写入或集成真实文件"})}
            }
          ]
        }
      else
        %{role: "assistant", content: summary}
      end
    end

    get "/models" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{data: [%{id: "conversation-fixture", context_length: 128_000}]}))
    end

    match(_, do: send_resp(conn, 404, "not found"))
  end

  @tag timeout: 300_000
  test "the real dispatcher, Session, Loop and model HTTP return a current result in the original conversation", %{
    tmp_dir: root
  } do
    Store.clear_all()
    File.mkdir_p!(root)
    server = start_supervised!({Bandit, plug: Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    path = Path.join(root, "model.json")

    config = %{
      providers: %{
        fixture: %{
          baseUrl: "http://127.0.0.1:#{port}",
          api: "openai-completions",
          apiKey: "test-only",
          models: ["conversation-fixture"],
          contextWindow: 128_000
        }
      },
      roles: %{default: %{provider: "fixture", model: "conversation-fixture"}}
    }

    File.write!(path, Jason.encode!(put_in(config, [:providers, :fixture, :apiKey], "")))
    old = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", path)
    sid = "execution-origin-#{System.unique_integer([:positive])}"
    :ok = Newbee.Session.set_cwd(sid, root)
    :ok = Newbee.Session.mark_created(sid)
    :ok = Newbee.Session.set_provider(sid, "fixture")
    :ok = Newbee.Session.set_model(sid, "conversation-fixture")

    on_exit(fn ->
      for task <- Store.list_tasks(), is_binary(task["session_id"]), do: Newbee.Web.Session.destroy(task["session_id"])
      if old, do: System.put_env("NEWBEE_MODEL_JSON", old), else: System.delete_env("NEWBEE_MODEL_JSON")
    end)

    {:ok, upload} = Newbee.Upload.store(sid, "constraints.txt", "text/plain", "read-only analysis\n")
    {:ok, result} = ConversationWork.start(sid, root, "只分析已授权范围，不修改文件", "start", upload_ids: [upload.id])

    id = result["work"]["id"]
    :ok = Runtime.sweep()
    {:ok, blocked} = ConversationWork.fetch(sid, id)
    assert blocked["status"] == "blocked"
    assert blocked["next_step"] =~ "模型凭据未配置"
    assert Newbee.Web.Session.lookup("work-" <> id) == {:error, :not_found}
    File.write!(path, Jason.encode!(config))
    assert {:ok, _} = ConversationWork.control(sid, id, "retry")
    assert length(Store.list_tasks()) == 1
    resumed = Enum.find(Store.all("deliveries"), &(&1["task_id"] == id and &1["status"] == "pending"))
    assert resumed["upload_ids"] == [upload.id]
    assert resumed["upload_sid"] == sid

    await_result(id, System.monotonic_time(:millisecond) + 240_000)
    {:ok, task} = ConversationWork.fetch(sid, id)
    assert task["status"] == "pending_review"
    assert task["execution_generation"] == 2
    assert task["session_id"] == "work-" <> id
    assert Newbee.Session.provider(task["session_id"]) == "fixture"
    assert Newbee.Session.model(task["session_id"]) == "conversation-fixture"
    assert task["workspace"]["root"] == root
    assert task["workspace"]["path"] != root
    assert task["consumed_context_revision"] == task["context_revision"]
    assert Enum.all?(task["inputs"], &is_integer(&1["consumed_at"]))
    assert ConversationWork.view(task)["result"]["content"] =~ "确定性模型协议已完成"
    assert length(Store.all("honey")) == 3
    coordination = ConversationWork.view(task)["coordination"]
    assert coordination["total"] == 2
    assert coordination["completed"] == 2
    assert length(ConversationWork.list(sid)) == 1
    children = Store.list_tasks() |> Enum.filter(&(&1["conversation_child"] == true))
    assert length(children) == 2
    assert Enum.all?(children, &(&1["status"] in ["pending_review", "done"]))
    paths = Enum.map([task | children], &get_in(&1, ["workspace", "path"]))
    assert length(Enum.uniq(paths)) == 3
    assert File.read!(Path.join(task["workspace"]["path"], "implementation.txt")) =~ "produced in isolated worker"
    assert File.read!(Path.join(task["workspace"]["path"], "verification.txt")) =~ "produced in isolated worker"
    refute File.exists?(Path.join(root, "implementation.txt"))
    refute File.exists?(Path.join(root, "verification.txt"))

    assert Enum.all?(
             children,
             &(Newbee.Session.provider(&1["session_id"]) == "fixture" and
                 Newbee.Session.model(&1["session_id"]) == "conversation-fixture")
           )

    assert Newbee.Web.Session.lookup(sid) == {:error, :not_found}
  end

  defp fail_result(id) do
    {:ok, task} = Store.get_task(id)

    facts = %{
      session:
        case Newbee.Web.Session.lookup(task["session_id"] || "") do
          {:ok, pid} -> GenServer.call(pid, :state, 3000) |> Map.take([:busy, :booting, :kernel_ready, :queued, :turns])
          _ -> :not_found
        end,
      task: Map.take(task, ~w(status next_step mode workflow session_id execution_generation context_revision)),
      deliveries:
        Store.all("deliveries")
        |> Enum.filter(&(&1["task_id"] == id))
        |> Enum.map(&Map.take(&1, ~w(status error session_id execution_generation context_revision))),
      child_sessions:
        Store.list_tasks()
        |> Enum.filter(&(&1["conversation_child"] == true))
        |> Enum.map(fn child ->
          case Newbee.Web.Session.lookup(child["session_id"] || "") do
            {:ok, pid} ->
              GenServer.call(pid, :state, 3000) |> Map.take([:sid, :busy, :queued, :turns, :booting, :kernel_ready])

            error ->
              error
          end
        end),
      children:
        Store.list_tasks()
        |> Enum.filter(&(&1["conversation_child"] == true))
        |> Enum.map(&Map.take(&1, ~w(id status next_step context_revision consumed_context_revision session_id result))),
      child_deliveries:
        Store.all("deliveries")
        |> Enum.reject(&(&1["task_id"] == id))
        |> Enum.map(&Map.take(&1, ~w(task_id status error session_id execution_generation context_revision))),
      controls: Store.all("controls") |> Enum.map(&Map.take(&1, ~w(paused action scope target_id)))
    }

    flunk("real execution did not produce a result: " <> inspect(facts, limit: :infinity))
  end

  defp await_result(id, deadline) do
    Runtime.sweep()

    case Store.get_task(id) do
      {:ok, %{"status" => "pending_review"}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          fail_result(id)
        else
          Process.sleep(200)
          await_result(id, deadline)
        end
    end
  end
end
