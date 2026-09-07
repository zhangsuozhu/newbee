defmodule Newbee.Agent.Explorer do
  @moduledoc """
  临时探索/测试子代理 (DESIGN §3.8) ⭐：独立 evaluator + 独立 kernel，
  git worktree 隔离（并行改代码互不干扰），返回**结构化结果**落盘
  `~/.newbee/agents/<id>/result.json`——主代理可用
  `Newbee.read("agent://<id>/<path>")` 按路径抠字段（§3.2 统一寻址）。

  模型角色走 model.json 的 `explorer`（最便宜档）。
  """

  @root Path.join(System.user_home!(), ".newbee/agents")

  @doc "跑一个探索/测试任务。返回结构化结果 map（同时落盘 result.json）。"
  def run(task, opts \\ []) do
    id = gen_id()
    File.mkdir_p!(@root)

    result =
      case Newbee.Tools.Git.worktree_add(worktree_path(id)) do
        {:ok, _} ->
          outcome = run_in_worktree(id, task, opts)
          Newbee.Tools.Git.worktree_remove(worktree_path(id))
          outcome

        {:error, reason} ->
          %{id: id, status: :error, error: inspect(reason), worktree: nil}
      end

    write_result(id, result)
    result
  end

  @doc "读取子代理结果（agent:// 统一寻址的底层）。"
  def read(id) do
    case File.read(Path.join([@root, id, "result.json"])) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, {:bad_json, reason}}
        end

      _ ->
        {:error, :agent_not_found}
    end
  end

  defp run_in_worktree(id, task, _opts) do
    client = Newbee.LLM.Config.client_for("explorer")

    File.cd!(worktree_path(id), fn ->
      {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :node)

      {:ok, k} =
        Newbee.Agent.Loop.start_link(client: client, evaluator: ev, session: false, render: fn _ -> :ok end)

      try do
        t0 = System.monotonic_time(:millisecond)
        reply = Newbee.Agent.Loop.submit(k, task)
        ms = System.monotonic_time(:millisecond) - t0

        %{
          id: id,
          status: :done,
          reply: elem(reply, 0),
          summary: summary_of(reply),
          usage: Newbee.Agent.Loop.usage(k),
          elapsed_ms: ms,
          findings: extract_findings(reply),
          worktree: worktree_path(id)
        }
      after
        GenServer.stop(k)
        GenServer.stop(ev)
      end
    end)
  rescue
    e -> %{id: id, status: :error, error: Exception.message(e)}
  end

  # 结构化结果（schema 校验的务实版：只收稳定字段，散文进 summary）
  defp extract_findings({:done, summary}), do: %{accepted: true, summary: summary}
  defp extract_findings({:ask, q}), do: %{accepted: false, question: q}
  defp extract_findings({:error, e}), do: %{accepted: false, error: inspect(e)}
  defp extract_findings(_), do: %{accepted: false}

  defp summary_of({:done, s}), do: s
  defp summary_of({:ask, q}), do: q
  defp summary_of({:error, e}), do: inspect(e)
  defp summary_of(_), do: ""

  defp write_result(id, result) do
    dir = Path.join(@root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "result.json"), Jason.encode_to_iodata!(result, pretty: true))
    :ok
  end

  defp worktree_path(id), do: Path.join(System.tmp_dir!(), "newbee-agent-#{id}")

  defp gen_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
