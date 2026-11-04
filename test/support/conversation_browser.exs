# Local deterministic browser harness. Uses real HTTP/Store/Workspace/Apply; it does not claim model quality.
# ERL_FLAGS='+S 4:4' MIX_ENV=test mix run --no-start test/support/conversation_browser.exs
root = Path.expand(".newbee-tmp/conversation-browser-#{System.system_time(:millisecond)}")
project = Path.join(root, "project")
File.mkdir_p!(project)
File.write!(Path.join(project, "export.txt"), "original\n")
Application.put_env(:newbee, :global_root_override, Path.join(root, "global"))
Application.put_env(:newbee, :colony_background, false)
{:ok, _} = Application.ensure_all_started(:newbee)
:ok = Newbee.Colony.Store.clear_all()
Application.put_env(:newbee, :conversation_browser_project, project)
sid = "browser-origin"
:ok = Newbee.Session.set_cwd(sid, project)
:ok = Newbee.Session.mark_created(sid)

defmodule Newbee.Test.ConversationBrowser do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/__fixture/plan" do
    task =
      Newbee.Colony.Store.list_tasks()
      |> Enum.find(
        &(&1["conversation"] == true and &1["conversation_child"] != true and
            &1["status"] not in ~w(done failed cancelled))
      )

    {:ok, _} = Newbee.Colony.Workspace.ensure(task, task["source_root"])
    {:ok, task} = Newbee.Colony.Store.get_task(task["id"])

    for delivery <- Newbee.Colony.Store.all("deliveries"),
        delivery["task_id"] == task["id"],
        delivery["status"] == "pending" do
      {:ok, _} =
        Newbee.Colony.Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})

      :ok = Newbee.Colony.ConversationWork.consumed(delivery["id"])
    end

    plan = %{
      "summary" => "导出实现与独立兼容性验证分开进行，完成后统一集成。",
      "tasks" => [
        %{
          "id" => "export",
          "title" => "实现 CSV 导出",
          "scope" => "仅修改 export.txt，对空日期保留空字符串。",
          "depends_on" => [],
          "acceptance" => ["空日期和旧格式兼容"]
        },
        %{
          "id" => "compatibility",
          "title" => "独立验证兼容性",
          "scope" => "检查现有格式和边界条件，提交验证报告。",
          "depends_on" => [],
          "acceptance" => ["独立核对格式"]
        }
      ]
    }

    {:ok, _} = Newbee.Colony.Workflow.complete(task, Jason.encode!(plan), task["context_revision"])
    send_resp(conn, 200, "planned")
  end

  post "/__fixture/child_question" do
    child = Newbee.Colony.Store.list_tasks() |> Enum.find(&(&1["conversation_child"] == true))

    q =
      Newbee.Colony.ConversationWork.question(child, %{
        question: "空日期应保留为空字符串吗？",
        kind: "single",
        options: [%{label: "保留空字符串", value: "empty"}, %{label: "跳过这一行", value: "skip"}]
      })

    {:ok, _} =
      Newbee.Colony.Store.update(
        "tasks",
        child["id"],
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "waiting_for" => "user", "question" => q})}
      )

    send_resp(conn, 200, "child question")
  end

  post "/__fixture/children_ready" do
    for child <- Newbee.Colony.Store.list_tasks(), child["conversation_child"] == true do
      {:ok, path} = Newbee.Colony.Workspace.ensure(child, child["source_root"])
      File.write!(Path.join(path, "export.txt"), "fixed by deterministic decomposition fixture\n")

      for delivery <- Newbee.Colony.Store.all("deliveries"),
          delivery["task_id"] == child["id"],
          delivery["status"] in ["pending", "accepted"] do
        :ok = Newbee.Colony.ConversationWork.consumed(delivery["id"])

        {:ok, _} =
          Newbee.Colony.Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "completed")})
      end

      {:ok, child} =
        Newbee.Colony.Store.update(
          "tasks",
          child["id"],
          nil,
          &{:ok, Map.merge(&1, %{"status" => "running", "waiting_for" => nil, "question" => nil})}
        )

      {:ok, _} =
        Newbee.Colony.Work.submit(
          child["colony_id"],
          child["id"],
          %{
            "content" => "此项分工已完成；确定性夹具写入真实文件，非真实模型质量证明。",
            "evidence" => ["real export.txt fixture write"],
            "work_revision" => child["context_revision"]
          },
          child["assigned_bee_id"]
        )
    end

    :ok = Newbee.Colony.Workflow.advance()
    send_resp(conn, 200, "children ready")
  end

  post "/__fixture/ready" do
    task =
      Newbee.Colony.Store.list_tasks()
      |> Enum.find(
        &(&1["conversation"] == true and &1["conversation_child"] != true and
            &1["status"] not in ~w(done failed cancelled))
      )

    {:ok, path} = Newbee.Colony.Workspace.ensure(task, task["source_root"])
    File.write!(Path.join(path, "export.txt"), "fixed by deterministic fixture\n")

    {:ok, task} =
      Newbee.Colony.Store.update("tasks", task["id"], nil, fn t ->
        {:ok,
         Map.merge(t, %{
           "mode" => "execution",
           "status" => "running",
           "question" => nil,
           "workflow" =>
             Map.put(
               t["workflow"],
               "phase",
               if(Newbee.Colony.Decomposition.managed?(t), do: "integrating", else: "executing")
             )
         })}
      end)

    for delivery <- Newbee.Colony.Store.all("deliveries"),
        delivery["task_id"] == task["id"],
        delivery["status"] in ["pending", "accepted", "held"] do
      :ok = Newbee.Colony.ConversationWork.consumed(delivery["id"])

      {:ok, _} =
        Newbee.Colony.Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "completed")})
    end

    {:ok, _} =
      Newbee.Colony.Work.submit(
        task["colony_id"],
        task["id"],
        %{
          "content" => "修复完成，成果在独立目录；验证：本地确定性浏览器夹具，未调用真实模型。",
          "evidence" => ["fixture writes real export.txt"],
          "limitations" => ["验证交互与文件应用，不验证模型输出质量"]
        },
        task["assigned_bee_id"]
      )

    send_resp(conn, 200, "ready")
  end

  post "/__fixture/question" do
    task =
      Newbee.Colony.Store.list_tasks()
      |> Enum.find(
        &(&1["conversation"] == true and &1["conversation_child"] != true and
            &1["status"] not in ~w(done failed cancelled))
      )

    q =
      Newbee.Colony.ConversationWork.question(task, %{
        question: "空日期应保留为空字符串吗？",
        kind: "single",
        options: [%{label: "保留空字符串", value: "empty"}, %{label: "跳过这一行", value: "skip"}]
      })

    {:ok, _} =
      Newbee.Colony.Store.update(
        "tasks",
        task["id"],
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "question" => q})}
      )

    send_resp(conn, 200, "question")
  end

  post "/__fixture/conflict" do
    project = Application.fetch_env!(:newbee, :conversation_browser_project)
    File.write!(Path.join(project, "export.txt"), "user changed after review\n")
    send_resp(conn, 200, "conflict")
  end

  get "/__fixture/files" do
    project = Application.fetch_env!(:newbee, :conversation_browser_project)
    content = File.read!(Path.join(project, "export.txt"))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{content: content, tasks: Newbee.Colony.Store.list_tasks()}))
  end

  forward("/", to: Newbee.Web.Router)
end

{:ok, server} = Bandit.start_link(plug: Newbee.Test.ConversationBrowser, port: 0, ip: {127, 0, 0, 1})
{:ok, {_, port}} = ThousandIsland.listener_info(server)

File.write!(
  ".newbee-tmp/conversation-browser.json",
  Jason.encode!(%{base: "http://127.0.0.1:#{port}", sid: sid, project: project, root: root})
)

IO.puts("Browser fixture ready at http://127.0.0.1:#{port}/?session=#{sid}")

receive do
  :stop -> :ok
end
