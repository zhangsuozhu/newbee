defmodule Newbee.Tools.Team do
  @moduledoc """
  Colony team templates: main proposes a team, a human approves, roles + operating loop become a reusable template; start projects from it.

  Stages hand accepted artifacts downstream; review gates wait for a human; rejects rework to `rework_to` within `max_rounds`.
  Approval/review are human-only via WebUI; this tool never approves. Runs under an Agent.Loop capability context.

  ## Runnable example
      {:ok, %{"templates" => ts}} = Newbee.Tools.Team.templates()
      {:ok, %{"template" => t}} = Newbee.Tools.Team.seed()
      {:ok, %{"proposal" => _p}} = Newbee.Tools.Team.propose("组建产研团队做记账产品")
      {:ok, %{"run" => r}} = Newbee.Tools.Team.start(t["id"], "记账产品：收支记录与月报")
      Newbee.Tools.Team.proposals(); Newbee.Tools.Team.runs(); Newbee.Tools.Team.status(r["id"])
  """

  @context_key {Newbee.Tools.Team, :context}

  @doc "List reusable team templates (global assets)."
  def templates, do: host_call(Newbee.Colony.Team, :list_templates, []) |> wrap("templates")

  @doc "Seed the builtin product-team template (idempotent); returns {:ok, %{\"template\" => t}}."
  def seed, do: call_with_actor(&Newbee.Colony.Team.seed_builtin/1, "template")

  @doc "Ask the main role to plan a team for goal; a human must approve the draft in the colony WebUI."
  def propose(goal, opts \\ [])

  def propose(goal, opts) when is_binary(goal) and is_list(opts) do
    with {:ok, actor, colony_id} <- identity(opts) do
      attrs = %{"goal" => goal, "colony_id" => colony_id, "origin_session_id" => actor.session_id}
      host_call(Newbee.Colony.Team, :start_proposal, [attrs, actor.bee_id]) |> wrap("proposal")
    end
  end

  def propose(_, _), do: {:error, "bad_request", "goal must be text"}

  @doc "List team proposals in the current colony (draft status, goal, ids)."
  def proposals do
    with {:ok, _actor, colony_id} <- identity([]) do
      {:ok, %{"proposals" => host_call(Newbee.Colony.Team, :list_proposals, [[colony_id: colony_id]])}}
    end
  end

  @doc "Start a project from a template: creates the project colony, all role bees and the first stage task."
  def start(template_id, goal, opts \\ [])

  def start(template_id, goal, opts) when is_binary(template_id) and is_binary(goal) and is_list(opts) do
    with {:ok, actor, _colony_id} <- identity(opts) do
      attrs = %{
        "template_id" => template_id,
        "goal" => goal,
        "name" => Keyword.get(opts, :name),
        "cwd" => Keyword.get(opts, :cwd, actor.project_root)
      }

      host_call(Newbee.Colony.Team, :start_run, [attrs, actor.bee_id]) |> wrap("run")
    end
  end

  def start(_, _, _), do: {:error, "bad_request", "template_id and goal must be text"}

  @doc "List team project runs in the current colony."
  def runs do
    with {:ok, _actor, colony_id} <- identity([]) do
      {:ok, %{"runs" => host_call(Newbee.Colony.Team, :list_runs, [[colony_id: colony_id]])}}
    end
  end

  @doc "Project status: run record, per-stage states, current task and members."
  def status(run_id) when is_binary(run_id),
    do: host_call(Newbee.Colony.Team, :run_view, [run_id])

  def status(_), do: {:error, "bad_request", "run_id must be text"}

  # ── identity ──

  defp call_with_actor(fun, key) do
    with {:ok, actor, _cid} <- identity([]) do
      fun.(actor.bee_id) |> wrap(key)
    end
  end

  defp identity(opts) do
    colony_id = Keyword.get(opts, :colony_id)

    case Process.get(@context_key) do
      %{capability: token} when is_binary(token) ->
        with {:ok, ctx} <- host_call(Newbee.Collaboration.Capability, :resolve, [token]) do
          resolve_actor(ctx, colony_id)
        end

      _ ->
        {:error, "no_execution_context", "Team tools must run under a capability context issued by Agent.Loop"}
    end
  end

  defp resolve_actor(ctx, colony_id) do
    binding = host_call(Newbee.Colony.Control, :binding, [ctx.session_id])

    case binding do
      %{"bee_id" => bee_id, "colony_id" => cid} ->
        {:ok, %{bee_id: bee_id, session_id: ctx.session_id, project_root: ctx.project_root}, colony_id || cid}

      _ ->
        # 普通会话没有蜂群绑定：提案/项目会在需要时创建自己的蜂群，actor 用 nil（系统发起）。
        {:ok, %{bee_id: nil, session_id: ctx.session_id, project_root: ctx.project_root}, colony_id}
    end
  end

  defp wrap({:ok, value}, key), do: {:ok, %{key => value}}
  defp wrap({:error, _code, _message} = error, _key), do: error
  defp wrap({:error, reason}, _key), do: {:error, "operation_failed", inspect(reason)}
  defp wrap(:ok, key), do: {:ok, %{key => nil}}

  defp host_call(module, function, args), do: Newbee.Host.call(module, function, args)
end
