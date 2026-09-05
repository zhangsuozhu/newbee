defmodule Newbee.DEE.EvalGuardian do
  @moduledoc false

  # One guardian per admitted job, outside the evaluator's mailbox.
  def start(evaluator, owner, target, peer, job_id, timeout) do
    spawn_monitor(fn ->
      refs = Enum.map(Enum.uniq([evaluator, owner]), &Process.monitor/1)
      timer = Process.send_after(self(), :deadline, timeout)
      watch(%{evaluator: evaluator, target: target, peer: peer, id: job_id, refs: refs, timer: timer})
    end)
  end

  defp watch(job) do
    receive do
      {:finished, id} when id == job.id ->
        Process.cancel_timer(job.timer)
        :ok

      {:cancel, id, reason} when id == job.id ->
        cancel(job, reason)

      :deadline ->
        cancel(job, :timed_out)

      {:DOWN, ref, :process, _pid, _reason} ->
        if ref in job.refs, do: cancel(job, :owner_down), else: watch(job)

      _ ->
        watch(job)
    end
  end

  defp cancel(job, reason) do
    send(job.evaluator, {:guardian_cancel, job.id, reason})
    # A stalled remote node must not prevent the escalation timer.
    {request, monitor} = spawn_monitor(fn -> cancel_remote(job) end)
    timer = Process.send_after(self(), :escalate, 1000)
    settling(job, request, monitor, timer)
  end

  defp settling(job, request, monitor, timer) do
    receive do
      {:finished, id} when id == job.id ->
        Process.cancel_timer(timer)
        if Process.alive?(request), do: Process.exit(request, :kill)
        Process.demonitor(monitor, [:flush])
        :ok

      :escalate ->
        if Process.alive?(request), do: Process.exit(request, :kill)
        # Only the primary handle captured for this job may be stopped.
        if is_pid(job.peer), do: Process.exit(job.peer, :kill)
        send(job.evaluator, {:eval_deadline, job.id})

        receive do
          {:finished, id} when id == job.id -> :ok
        after
          3000 ->
            # The evaluator did not acknowledge even after isolation.
            Process.exit(job.evaluator, :kill)
        end

      _ ->
        settling(job, request, monitor, timer)
    end
  end

  defp cancel_remote(job) do
    try do
      case job.target do
        %{mode: :local, worker: worker} ->
          GenServer.call(worker, {:cancel, job.id}, 500)

        %{node: remote, worker: worker} ->
          :rpc.call(remote, GenServer, :call, [worker, {:cancel, job.id}, 500], 750)
      end
    catch
      _, _ -> :ok
    end
  end
end
