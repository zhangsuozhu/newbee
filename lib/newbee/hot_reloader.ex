defmodule Newbee.HotReloader do
  @moduledoc """
  自动热载 newbee 自身的已编译 BEAM。

  监控应用 ebin 目录的内容哈希；编译产物变化后先 soft purge 旧版本，
  再 load_binary 新版本。仍有进程执行旧代码时按指数退避重试，
  避免为了热载杀掉活动会话，也避免高频 soft purge 占满调度器。
  """

  use GenServer
  require Logger

  @default_interval 5_000
  @default_retry_base 5_000
  @default_retry_max 60_000

  defstruct dirs: [],
            fingerprints: %{},
            deferred: %{},
            interval: @default_interval,
            retry_base: @default_retry_base,
            retry_max: @default_retry_max,
            reload_fun: nil,
            timer: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "立即扫描一次（诊断和测试用）。"
  def scan_now(server \\ __MODULE__), do: GenServer.call(server, :scan, 30_000)

  @doc "安全加载一个 BEAM 文件。"
  def reload_file(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, module} <- beam_module(path),
         true <- :code.soft_purge(module),
         {:module, ^module} <- :code.load_binary(module, String.to_charlist(path), binary) do
      {:ok, module}
    else
      false -> {:error, :old_code_in_use}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:load_failed, other}}
    end
  rescue
    error -> {:error, {:exception, error}}
  end

  @impl true
  def init(opts) do
    dirs = Keyword.get(opts, :dirs, default_dirs())
    interval = Keyword.get(opts, :interval, @default_interval)
    retry_base = Keyword.get(opts, :retry_base, @default_retry_base)
    retry_max = Keyword.get(opts, :retry_max, @default_retry_max)
    reload_fun = Keyword.get(opts, :reload_fun, &__MODULE__.reload_file/1)
    fingerprints = fingerprints(dirs)

    state = %__MODULE__{
      dirs: dirs,
      fingerprints: fingerprints,
      interval: interval,
      retry_base: retry_base,
      retry_max: retry_max,
      reload_fun: reload_fun
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:scan, _from, state) do
    {state, results} = scan(state, true)
    {:reply, results, state}
  end

  @impl true
  def handle_info(:scan, state) do
    {state, _results} = scan(%{state | timer: nil}, false)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp scan(state, force?) do
    current = fingerprints(state.dirs)
    now = System.monotonic_time(:millisecond)

    changed =
      current
      |> Enum.filter(fn {path, fingerprint} ->
        state.fingerprints[path] != fingerprint and
          (force? or retry_due?(state.deferred[path], fingerprint, now))
      end)
      |> Enum.sort_by(&elem(&1, 0))

    reload_fun = Map.get(state, :reload_fun) || (&__MODULE__.reload_file/1)

    {fingerprints, deferred, results} =
      Enum.reduce(changed, {state.fingerprints, state.deferred, []}, fn {path, fingerprint},
                                                                        {known, deferred, results} ->
        case reload_fun.(path) do
          {:ok, module} = result ->
            Logger.info("hot reloaded #{inspect(module)} from #{path}")
            Newbee.Events.emit(:hot_reload, {:hot_reload, module, path})
            {Map.put(known, path, fingerprint), Map.delete(deferred, path), [result | results]}

          {:error, :old_code_in_use} = result ->
            previous = Map.get(deferred, path)

            if not same_fingerprint?(previous, fingerprint) do
              Logger.warning("hot reload deferred " <> path <> ": :old_code_in_use")
            end

            retry = next_retry(previous, fingerprint, state, now)
            {known, Map.put(deferred, path, retry), [result | results]}

          {:error, reason} = result ->
            Logger.warning("hot reload deferred #{path}: #{inspect(reason)}")
            {known, Map.delete(deferred, path), [result | results]}
        end
      end)

    # 删除的 BEAM 不主动 purge：运行中的模块可能仍被会话使用。
    fingerprints = Map.take(fingerprints, Map.keys(current))
    deferred = Map.take(deferred, Map.keys(current))
    {%{state | fingerprints: fingerprints, deferred: deferred}, Enum.reverse(results)}
  end

  defp retry_due?(%{fingerprint: fingerprint, retry_at: retry_at}, fingerprint, now),
    do: now >= retry_at

  defp retry_due?(_retry, _fingerprint, _now), do: true

  defp same_fingerprint?(%{fingerprint: fingerprint}, fingerprint), do: true
  defp same_fingerprint?(_retry, _fingerprint), do: false

  defp next_retry(previous, fingerprint, state, now) do
    retry_base = Map.get(state, :retry_base, @default_retry_base)
    retry_max = Map.get(state, :retry_max, @default_retry_max)

    delay =
      case previous do
        %{fingerprint: ^fingerprint, delay: delay} -> min(delay * 2, retry_max)
        _ -> min(retry_base, retry_max)
      end

    %{fingerprint: fingerprint, delay: delay, retry_at: now + delay}
  end

  defp fingerprints(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, binary} -> Map.put(acc, path, :crypto.hash(:sha256, binary))
        {:error, _} -> acc
      end
    end)
  end

  defp beam_module(path) do
    case :beam_lib.info(String.to_charlist(path))[:module] do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  defp default_dirs do
    [Application.app_dir(:newbee, "ebin")]
  rescue
    _ -> []
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :scan, state.interval)}
  end
end
