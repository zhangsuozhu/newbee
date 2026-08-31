defmodule Newbee.Agent.Worker do
  @moduledoc """
  Worker Agent（DESIGN §7.1）：用 active 环境干活的唯一前台 Agent。

  - 只做一件便宜事：发一条 `need` 消息（进化线索，urgency: low）；
  - 用完模块给**版本级** feedback（score 绑定具体 release_id）；
  - 发现退化发 rollback_request；
  - 收 module_ready（经 Projection 进下一次视图，执行中排队不打断）；
  - 循环引擎 = Agent.Loop（turn/step 状态机，§6.5）。
  """

  alias Newbee.Agent.Protocol

  # ── 循环引擎（Agent.Loop 直委托）──

  defdelegate start_link(opts), to: Newbee.Agent.Loop
  defdelegate submit(loop, text), to: Newbee.Agent.Loop
  defdelegate set_goal(loop, text, opts), to: Newbee.Agent.Loop
  defdelegate clear_goal(loop), to: Newbee.Agent.Loop
  defdelegate goal(loop), to: Newbee.Agent.Loop
  defdelegate usage(loop), to: Newbee.Agent.Loop
  defdelegate switch_model(loop, client), to: Newbee.Agent.Loop
  defdelegate interrupt(loop), to: Newbee.Agent.Loop
  defdelegate compact(loop), to: Newbee.Agent.Loop
  defdelegate awaiting_permission?(loop), to: Newbee.Agent.Loop

  # ── 进化协作（worker 的三条轻量通道，§7.1）──

  @doc "发一条 need 消息（一句话便宜事，不分心）。"
  def need(capability, opts \\ []) do
    {:ok, message_id} = Protocol.need(capability, Keyword.put(opts, :sender, "worker"))

    Newbee.Bus.emit(:need, %{capability: capability, message_id: message_id})
    {:ok, message_id}
  end

  @doc "版本级 feedback（真实使用评价层证据，§8.2 Real usage）。"
  def feedback(plugin_id, release_id, outcome, opts \\ []) do
    {:ok, message_id} = Protocol.feedback(plugin_id, release_id, outcome, Keyword.put(opts, :sender, "worker"))

    # 同步记 Coordinator（价签记账 + 可选自动回退受理）
    if Process.whereis(Newbee.Environment.Coordinator) do
      Newbee.Environment.Coordinator.feedback(
        Map.new(opts)
        |> Map.merge(%{plugin_id: plugin_id, release_id: release_id, outcome: outcome})
      )
    end

    {:ok, message_id}
  end

  @doc "回退请求（target 只是线索，Coordinator 重解析依赖图，§8.4）。"
  def rollback_request(plugin_id, release_id, target, reason, opts \\ []) do
    Protocol.rollback_request(plugin_id, release_id, target, reason, Keyword.put(opts, :sender, "worker"))
  end
end
