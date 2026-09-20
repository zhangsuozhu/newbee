defmodule Newbee.Compaction.JevClient do
  @moduledoc """
  Host 内 TypeSafe/Jev 评分客户端。凭证只在 Host HTTP worker 中读取。
  """

  alias Newbee.Compaction.{Config, Policy}

  @poll_ms 50

  def score(state, batches, config, opts \\ []) do
    interrupt? = Keyword.get(opts, :interrupt?) || fn -> false end
    timeout = Keyword.get(opts, :rpc_timeout, config.total_timeout_ms + 1_000)

    if interrupt?.() do
      {:interrupted, empty_stats()}
    else
      Newbee.Host.call(
        __MODULE__,
        :score_on_host,
        [state, batches, config, Keyword.take(opts, [:transport, :interrupt?, :clock, :caller])],
        timeout
      )
      |> normalize_host_result()
    end
  rescue
    _ -> {:error, :rpc_error, empty_stats()}
  catch
    _, _ -> {:error, :rpc_error, empty_stats()}
  end

  def score_on_host(state, batches, config, opts \\ []) do
    interrupt? = Keyword.get(opts, :interrupt?) || fn -> false end
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    transport = Keyword.get(opts, :transport, &http_post/4)
    caller = Keyword.get(opts, :caller, self())
    deadline = clock.() + config.total_timeout_ms
    started = clock.()

    run_bounded(
      fn ->
        do_score(state, batches, config, interrupt?, clock, transport, deadline, started)
      end,
      caller,
      deadline,
      clock,
      interrupt?
    )
  end

  def build_request(state, questions, config) do
    %{
      url: Config.endpoint(),
      method: :post,
      body:
        Jason.encode!(%{
          "model" => config.model,
          "state" => state,
          "questions" => questions
        })
    }
  end

  def parse_response(status, body, expected_ids) when is_integer(status) and is_binary(body) do
    cond do
      status in 401..403 ->
        {:error, {:auth_error, status}}

      status == 429 ->
        {:error, {:rate_limited, status}}

      status >= 500 ->
        {:error, {:server_error, status}}

      status < 200 or status >= 300 ->
        {:error, {:http_status, status}}

      byte_size(body) > Config.max_response_bytes() ->
        {:error, :response_too_large}

      true ->
        decode_answers(body, expected_ids)
    end
  end

  def parse_response(_, _, _), do: {:error, :malformed_response}

  # ── bounded execution ──

  defp run_bounded(fun, caller, deadline, clock, interrupt?) do
    supervisor = compaction_supervisor()

    worker =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :worker_crash, empty_stats()}
        catch
          _, _ -> {:error, :worker_crash, empty_stats()}
        end
      end)

    watchdog =
      Task.Supervisor.async_nolink(supervisor, fn ->
        watch_owner(caller, worker.pid, deadline, clock)
      end)

    try do
      await_result(worker, interrupt?, deadline, clock)
    after
      shutdown_task(worker)
      shutdown_task(watchdog)
      drain()
    end
  end

  defp watch_owner(caller, worker, deadline, clock) do
    caller_ref = Process.monitor(caller)
    worker_ref = Process.monitor(worker)

    wait_owner(caller_ref, worker_ref, worker, deadline, clock)
  end

  defp wait_owner(caller_ref, worker_ref, worker, deadline, clock) do
    remaining = max(deadline - clock.(), 0)

    receive do
      {:DOWN, ^caller_ref, :process, _, _} ->
        Process.exit(worker, :kill)
        :ok

      {:DOWN, ^worker_ref, :process, _, _} ->
        :ok
    after
      remaining ->
        Process.exit(worker, :kill)
        :ok
    end
  end

  defp await_result(worker, interrupt?, deadline, clock) do
    remaining = max(deadline - clock.(), 0)

    cond do
      interrupt?.() ->
        shutdown_task(worker)
        {:interrupted, empty_stats()}

      remaining <= 0 ->
        shutdown_task(worker)
        {:error, :timeout, empty_stats()}

      true ->
        case Task.yield(worker, min(@poll_ms, remaining)) do
          {:ok, result} ->
            result

          {:exit, _} ->
            {:error, :worker_crash, empty_stats()}

          nil ->
            await_result(worker, interrupt?, deadline, clock)
        end
    end
  end

  defp shutdown_task(%Task{pid: pid, ref: ref}) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp shutdown_task(_), do: :ok

  defp drain do
    receive do
      {_ref, _result} -> drain()
      {:DOWN, _ref, :process, _pid, _reason} -> drain()
    after
      0 -> :ok
    end
  end

  defp compaction_supervisor do
    if Process.whereis(Newbee.Compaction.Tasks) do
      Newbee.Compaction.Tasks
    else
      {:ok, pid} = Task.Supervisor.start_link()
      pid
    end
  end

  # ── scoring ──

  defp do_score(_state, [], _config, _interrupt?, _clock, _transport, _deadline, started) do
    {:ok, %{}, %{requests: 0, elapsed_ms: 0, started: started}}
  end

  defp do_score(state, batches, config, interrupt?, clock, transport, deadline, started) do
    key = resolve_api_key(config)

    cond do
      interrupt?.() ->
        {:interrupted, elapsed_stats(started, clock, 0)}

      not is_binary(key) or String.trim(key) == "" ->
        {:error, :missing_key, elapsed_stats(started, clock, 0)}

      true ->
        score_batches(state, batches, config, interrupt?, clock, transport, deadline, started, key, %{}, 0)
    end
  end

  defp score_batches(_state, [], _config, _interrupt?, clock, _transport, _deadline, started, _key, answers, n) do
    {:ok, answers, elapsed_stats(started, clock, n)}
  end

  defp score_batches(state, [batch | rest], config, interrupt?, clock, transport, deadline, started, key, answers, n) do
    remaining = deadline - clock.()

    cond do
      interrupt?.() ->
        {:interrupted, elapsed_stats(started, clock, n)}

      remaining <= 0 ->
        {:error, :timeout, elapsed_stats(started, clock, n)}

      true ->
        questions =
          Enum.reduce(batch, %{}, fn call, acc -> Map.merge(acc, Policy.questions_for(call)) end)

        expected =
          Enum.flat_map(batch, fn call -> ["call_#{call.id}", "result_#{call.id}"] end)

        request = build_request(state, questions, config)

        case transport.(request, key, min(remaining, config.request_timeout_ms), config) do
          {:ok, status, body} ->
            case parse_response(status, body, expected) do
              {:ok, batch_answers} ->
                score_batches(
                  state,
                  rest,
                  config,
                  interrupt?,
                  clock,
                  transport,
                  deadline,
                  started,
                  key,
                  Map.merge(answers, batch_answers),
                  n + 1
                )

              {:error, reason} ->
                {:error, reason, elapsed_stats(started, clock, n + 1)}
            end

          {:error, reason} ->
            {:error, reason, elapsed_stats(started, clock, n + 1)}
        end
    end
  end

  defp decode_answers(body, expected_ids) do
    case Jason.decode(body) do
      {:ok, %{"answers" => answers}} when is_map(answers) ->
        Enum.reduce_while(expected_ids, {:ok, %{}}, fn id, {:ok, acc} ->
          case answers[id] do
            %{"noul" => noul} ->
              if valid_noul?(noul) do
                {:cont, {:ok, Map.put(acc, id, noul)}}
              else
                {:halt, {:error, :malformed_response}}
              end

            _ ->
              {:halt, {:error, :malformed_response}}
          end
        end)

      {:ok, _} ->
        {:error, :malformed_response}

      {:error, _} ->
        {:error, :malformed_response}
    end
  end

  defp valid_noul?(n) when is_integer(n) and n >= 0 and n <= 1, do: true
  defp valid_noul?(n) when is_float(n) and n >= 0 and n <= 1, do: true
  defp valid_noul?(_), do: false

  defp http_post(request, key, timeout_ms, _config) do
    timeout = max(timeout_ms, 1)
    max_bytes = Config.max_response_bytes()

    req =
      Req.new(
        method: request.method,
        url: request.url,
        headers: [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}],
        body: request.body,
        retry: false,
        redirect: false,
        decode_body: false,
        connect_options: [timeout: timeout],
        receive_timeout: timeout,
        pool_timeout: timeout,
        into: bounded_collector(max_bytes)
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: _status, body: {:too_large, _}}} ->
        {:error, :response_too_large}

      {:ok, %Req.Response{status: status, body: body}} when is_binary(body) ->
        if byte_size(body) > max_bytes, do: {:error, :response_too_large}, else: {:ok, status, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        text = IO.iodata_to_binary(List.wrap(body))
        if byte_size(text) > max_bytes, do: {:error, :response_too_large}, else: {:ok, status, text}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Newbee.DebugLog.log(:compact, "jev transport=" <> inspect(reason))
        {:error, :network_error}

      {:error, other} ->
        Newbee.DebugLog.log(:compact, "jev http_error=" <> inspect(other.__struct__))
        {:error, :network_error}
    end
  rescue
    _ -> {:error, :network_error}
  catch
    _, _ -> {:error, :network_error}
  end

  defp bounded_collector(max_bytes) do
    fn
      {:data, data}, {req, resp} ->
        current = IO.iodata_to_binary(resp.body || "")
        combined = current <> data

        if byte_size(combined) > max_bytes do
          {:halt, {req, %{resp | body: {:too_large, byte_size(combined)}}}}
        else
          {:cont, {req, %{resp | body: combined}}}
        end

      :done, acc ->
        acc
    end
  end

  defp resolve_api_key(config) do
    env_name = config[:api_key_env] || Config.default_api_key_env()
    provider = config[:api_key_provider] || "typesafe"
    env_key = System.get_env(env_name)

    cond do
      present_key?(env_key) ->
        env_key

      Mix.env() == :test ->
        nil

      true ->
        key = Newbee.LLM.Config.provider_api_key(provider)
        if present_key?(key), do: key, else: nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp present_key?(key) when is_binary(key), do: String.trim(key) != ""
  defp present_key?(_), do: false

  defp empty_stats, do: %{requests: 0, elapsed_ms: 0}

  defp elapsed_stats(started, clock, requests) do
    %{requests: requests, elapsed_ms: max(clock.() - started, 0)}
  end

  defp normalize_host_result({:badrpc, _}), do: {:error, :rpc_error, empty_stats()}
  defp normalize_host_result({:ok, answers, stats}), do: {:ok, answers, stats}
  defp normalize_host_result({:error, reason, stats}), do: {:error, reason, stats}
  defp normalize_host_result({:interrupted, stats}), do: {:interrupted, stats}
  defp normalize_host_result(_), do: {:error, :rpc_error, empty_stats()}
end
