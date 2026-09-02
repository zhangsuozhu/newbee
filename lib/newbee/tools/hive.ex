defmodule Newbee.Tools.Hive do
  @moduledoc """
  协作 v2 (Hive)：黑板 + 边沿等待 + 递归护栏 + 角色实体化。

  与旧 Collaboration 并存（旧的已标记 legacy）。Hive 适用多代理并行大任务。

  ## 设计（docs/collab-v2-analysis.md）

  - Board：任务黑板，CAS(expected_revision) + DAG 依赖 + writeScope 诊断
  - Rendezvous：wait 边沿触发，醒来必重读板，禁止轮询
  - SpawnGate：max_depth/max_total 硬墙，防递归爆炸
  - Persona：角色编译成真实配置差异（模型/工具/预算）

  ## 函数清单

  - open(title, opts) — 建组
  - delegate(group_id, title, opts) — 派生（persona:/acceptance:/isolate:/fork_turns:）
  - board_put(group_id, task_map) — 写任务（CAS）
  - board_claim(group_id, task_id, expected_revision) — 认领
  - board_dep(group_id, task_id, depends_on, expected_revision) — 加依赖
  - board(group_id) — 读板（权威状态）
  - board_diagnose(group_id) — writeScope 重叠诊断
  - wait(group_id, opts) — 边沿等待（since_rev:/timeout_ms:）
  - send(group_id, to, body, opts) — 发消息（wake: true 唤醒）
  - inbox(group_id) — 读自己信箱
  - report(group_id, task_id, body) — 汇报义务（非终态，可重复）
  - roster(group_id) — 名册
  - interrupt(group_id, session_id) — 打断但保留信箱
  - close(group_id, session_id) — 显式回收
  - personas() — 可用角色清单
  ## 可跑示例

    {:ok, g} = Newbee.Tools.Hive.open("重构", goal: "目标")
    {:ok, w} = Newbee.Tools.Hive.delegate(g["group_id"], "子任务", persona: "worker")
    {:ok, b} = Newbee.Tools.Hive.board_put(g["group_id"], %{"title" => "t"})
    {:ok, c} = Newbee.Tools.Hive.board_claim(g["group_id"], "t1")
    {:ok, d} = Newbee.Tools.Hive.board_dep(g["group_id"], "t2", "t1")
    {:ok, board} = Newbee.Tools.Hive.board(g["group_id"])
    {:ok, diag} = Newbee.Tools.Hive.board_diagnose(g["group_id"])
    {:ok, edge} = Newbee.Tools.Hive.wait(g["group_id"], since_rev: 0)
    {:ok, m} = Newbee.Tools.Hive.send(g["group_id"], "sid", "hi")
    {:ok, box} = Newbee.Tools.Hive.inbox(g["group_id"])
    {:ok, _} = Newbee.Tools.Hive.report(g["group_id"], "t1", "done")
    {:ok, _} = Newbee.Tools.Hive.ack(g["group_id"], "hm_x")
    {:ok, r} = Newbee.Tools.Hive.roster(g["group_id"])
    {:ok, _} = Newbee.Tools.Hive.interrupt(g["group_id"], "sid")
    {:ok, _} = Newbee.Tools.Hive.close(g["group_id"], "sid")
    names = Newbee.Tools.Hive.personas()


  ## 安全约束

  - 无协作身份（非 Agent.Loop 上下文）调用一律拒绝
  - 每个会话只能操作自己所在组
  - 深度/总数硬墙不可越过
  """

  @context_key {__MODULE__, :context}

  # ── 身份 ──

  defp hive_identity do
    case Process.get(@context_key) do
      %{session_id: sid, project_root: root} -> {:ok, %{session_id: sid, project_root: root}}
      _ -> fallback_identity()
    end
  end

  # 无 DEE 上下文时退回当前会话（TUI/直接调用场景）
  defp fallback_identity do
    case Process.get({Newbee.Tools.Collaboration, :context}) do
      %{session_id: sid, project_root: root} -> {:ok, %{session_id: sid, project_root: root}}
      _ -> {:error, "no_execution_context", "无协作身份，Hive 需在 Agent.Loop 或已注册会话内调用"}
    end
  end

  defp server, do: Newbee.Collab.Group

  # ── 组 ──

  @doc "建协作组，自己是 lead。opts: goal:/project_root:/max_depth:/max_total:"
  def open(title, opts \\ []) when is_binary(title) do
    with {:ok, id} <- hive_identity() do
      server_started?()

      Newbee.Collab.Group.create_group(
        %{
          "session_id" => id.session_id,
          "title" => title,
          "goal" => Keyword.get(opts, :goal, title),
          "project_root" => Keyword.get(opts, :project_root, id.project_root),
          "command_id" => "open-#{System.unique_integer([:positive])}",
          "max_depth" => Keyword.get(opts, :max_depth, 3),
          "max_total" => Keyword.get(opts, :max_total, 16)
        },
        server()
      )
    end
  end

  # ── 派生 ──

  @doc "派生子代理。opts: persona:/acceptance:/isolate:/fork_turns:/name:"
  def delegate(group_id, title, opts \\ []) when is_binary(group_id) and is_binary(title) do
    with {:ok, id} <- hive_identity(),
         {:ok, persona_name} <- resolve_persona(Keyword.get(opts, :persona, "worker")),
         {:ok, persona} <- Newbee.Collab.Persona.resolve(persona_name),
         {:ok, _group} <- Newbee.Collab.Group.get(group_id, server()) do
      parent_depth = member_depth(group_id, id.session_id)

      child_opts = [
        session_id: Newbee.Web.Session.gen_session_id(),
        name: Keyword.get(opts, :name, title),
        role: persona_name,
        persona: persona,
        depth: parent_depth + 1,
        parent_session_id: id.session_id,
        description: Keyword.get(opts, :description),
        acceptance: Keyword.get(opts, :acceptance),
        isolate: Keyword.get(opts, :isolate, :auto),
        fork_turns: Keyword.get(opts, :fork_turns, :none)
      ]

      case spawn_child(group_id, id, title, child_opts, persona) do
        {:ok, child} -> {:ok, Map.put(child, "persona_config", Newbee.Collab.Persona.compile(persona))}
        err -> err
      end
    end
  end

  defp resolve_persona(p) when is_binary(p), do: {:ok, p}
  defp resolve_persona(_), do: {:ok, "worker"}

  defp member_depth(group_id, sid) do
    case Newbee.Collab.Group.roster(group_id, server()) do
      {:ok, roster} ->
        case Enum.find(roster, &(&1["session_id"] == sid)) do
          %{"depth" => d} -> d
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp spawn_child(group_id, identity, title, opts, persona) do
    gid_sid = opts[:session_id]

    with {:ok, member} <-
           Newbee.Collab.Group.join(
             group_id,
             %{
               "session_id" => gid_sid,
               "name" => opts[:name],
               "role" => opts[:role],
               "persona" => persona,
               "depth" => opts[:depth],
               "parent_session_id" => opts[:parent_session_id],
               "command_id" => "join-#{System.unique_integer([:positive])}"
             },
             server()
           ) do
      # 工作区 + 会话拉起走现有 Delegator 流水线（隔离+补偿）
      case Newbee.Host.call(Newbee.Collaboration.Delegator, :delegate, [
             legacy_group_id(group_id),
             identity.session_id,
             title,
             [
               name: opts[:name],
               role: opts[:role],
               description: opts[:description],
               acceptance: opts[:acceptance],
               isolate: opts[:isolate],
               session_id: gid_sid,
               command_id: "hive-spawn-#{System.unique_integer([:positive])}"
             ]
           ]) do
        {:ok, _} = _ok ->
          _ = inject_persona(gid_sid, persona, title, opts)
          {:ok, %{"session_id" => gid_sid, "member" => member, "delegated" => true}}

        {:error, code, msg} ->
          # 组已 join 成功但会话拉起失败 → 补偿离队
          _ = Newbee.Collab.Group.close(group_id, gid_sid, server())
          {:error, code, msg}
      end
    end
  end

  # 旧 Delegator 需要 legacy group；建映射（向后兼容，共享 workspace/补偿逻辑）
  defp legacy_group_id(hive_gid) do
    # 用一个影子 legacy group 承载 workspace；若不存在则建
    case Process.get({__MODULE__, :legacy_map, hive_gid}) do
      nil ->
        case Newbee.Host.call(Newbee.Collaboration.Coordinator, :create_group, [
               %{
                 "session_id" => "hive-shadow-#{hive_gid}",
                 "title" => "hive-shadow",
                 "goal" => "hive workspace shadow",
                 "project_root" => File.cwd!(),
                 "command_id" => "shadow-#{hive_gid}"
               }
             ]) do
          {:ok, g} ->
            Process.put({__MODULE__, :legacy_map, hive_gid}, g["group_id"])
            g["group_id"]

          {:error, _, _} ->
            hive_gid
        end

      gid ->
        gid
    end
  end

  defp inject_persona(sid, persona, title, opts) do
    patch = persona["system_patch"] || ""

    hint = """
    [Hive 子代理身份]
    角色: #{persona["role"]} | 任务: #{title}
    #{patch}
    验收: #{inspect(opts[:acceptance] || [])}
    完成前调用 Newbee.Tools.Hive.report(group_id, task_id, 事实结果)。
    """

    Newbee.Host.call(Newbee.Web.Session, :deliver_collaboration_message, [
      sid,
      %{"body" => hint, "sender_session_id" => "hive", "kind" => "system", "group_id" => "hive"}
    ])
  rescue
    _ -> :ok
  end

  # ── 黑板 ──

  @doc "写任务。task_map 含 title:/description:/acceptance:/depends_on:/write_scope:/expected_revision:"
  def board_put(group_id, task_map) when is_map(task_map) do
    with {:ok, _id} <- hive_identity() do
      Newbee.Collab.Group.board_put(group_id, Map.put_new(task_map, "command_id", "bp-#{System.unique_integer([:positive])}"), server())
    end
  end

  @doc "认领任务（CAS expected_revision）"
  def board_claim(group_id, task_id, expected_revision \\ nil) do
    with {:ok, id} <- hive_identity() do
      Newbee.Collab.Group.board_claim(group_id, task_id, id.session_id, expected_revision, server())
    end
  end

  @doc "加依赖边（DAG，拒环）"
  def board_dep(group_id, task_id, depends_on, expected_revision \\ nil) do
    with {:ok, id} <- hive_identity() do
      Newbee.Collab.Group.board_add_dep(group_id, task_id, depends_on, expected_revision, id.session_id, server())
    end
  end

  @doc "读板（权威状态）"
  def board(group_id), do: Newbee.Collab.Group.board_read(group_id, server())

  @doc "writeScope 重叠诊断"
  def board_diagnose(group_id), do: Newbee.Collab.Group.board_scope_diagnose(group_id, server())

  # ── 等待 ──

  @doc "边沿触发等待。opts: since_rev:/timeout_ms: 。醒后必须 board/1 重读。"
  def wait(group_id, opts \\ []) do
    with {:ok, id} <- hive_identity() do
      Newbee.Collab.Group.wait(
        group_id,
        Keyword.get(opts, :since_rev, 0),
        id.session_id,
        Keyword.get(opts, :timeout_ms, 30_000),
        server()
      )
    end
  end

  # ── 消息 ──

  @doc "发消息。opts: wake: true 唤醒对方（默认安静注入）。kind:"
  def send(group_id, to, body, opts \\ []) do
    with {:ok, id} <- hive_identity() do
      Newbee.Collab.Group.send_message(
        group_id,
        %{
          "from_session_id" => id.session_id,
          "to_session_id" => to,
          "body" => body,
          "kind" => Keyword.get(opts, :kind, "chat"),
          "wake" => Keyword.get(opts, :wake, false),
          "command_id" => "msg-#{System.unique_integer([:positive])}"
        },
        server()
      )
    end
  end

  @doc "读自己信箱（未 ack）"
  def inbox(group_id) do
    with {:ok, id} <- hive_identity() do
      Newbee.Collab.Group.inbox(group_id, id.session_id, [], server())
    end
  end

  @doc "确认消息已处理"
  def ack(group_id, message_id) do
    with {:ok, id} <- hive_identity() do
      Newbee.Collab.Group.ack(group_id, id.session_id, message_id, server())
    end
  end

  # ── 汇报 ──

  @doc "汇报义务：非终态、可重复、只跨一边。body=事实结果。"
  def report(group_id, task_id, body) do
    with {:ok, id} <- hive_identity() do
      case Newbee.Collab.Group.get(group_id, server()) do
        {:ok, g} ->
          Newbee.Collab.Group.send_message(
            group_id,
            %{
              "from_session_id" => id.session_id,
              "to_session_id" => g["lead_session_id"],
              "body" => "[report #{task_id}] #{body}",
              "kind" => "task_result",
              "wake" => false,
              "command_id" => "rep-#{System.unique_integer([:positive])}"
            },
            server()
          )

        err ->
          err
      end
    end
  end

  # ── 名册/生命周期 ──

  @doc "名册"
  def roster(group_id), do: Newbee.Collab.Group.roster(group_id, server())

  @doc "打断但保留信箱（唤醒后任务继续）"
  def interrupt(_group_id, session_id) do
    Newbee.Host.call(Newbee.Web.Session, :interrupt, [session_id])
    {:ok, %{"interrupted" => session_id}}
  end

  @doc "显式回收（完成后调用，防泄漏）"
  def close(group_id, session_id) do
    Newbee.Collab.Group.close(group_id, session_id, server())
  end

  @doc "可用角色清单"
  def personas, do: Newbee.Collab.Persona.list()

  # ── 内部 ──

  defp server_started? do
    case Process.whereis(server()) do
      nil ->
        {:ok, _} = Newbee.Collab.Group.start_link(name: server())
        :ok

      _ ->
        :ok
    end
  end
end
