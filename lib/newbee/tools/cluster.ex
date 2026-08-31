defmodule Newbee.Tools.Cluster do
  @moduledoc """
  Cluster probe helper - generic multi-host HTTP liveness check.
  Extracted from HA 8-node drill: repetitive for-ip ssh+curl with quoting and timeouts.
  Usable in any multi-host project.
  """
  @doc "Probe many hosts concurrently via ssh+curl. Returns list of maps."
  def probe_http(hosts, path, opts \\ []) when is_list(hosts) do
    timeout = Keyword.get(opts, :timeout_ms, 3000)
    port = Keyword.get(opts, :port, 5304)
    scheme = Keyword.get(opts, :scheme, "http")

    hosts
    |> Task.async_stream(
      fn host ->
        url = scheme <> "://127.0.0.1:" <> to_string(port) <> path
        secs = div(timeout, 1000) + 1

        cmd =
          "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@" <>
            host <> " \"curl -s --max-time " <> to_string(secs) <> " " <> url <> " 2>&1 | head -c 8192\""

        case Newbee.Tools.Run.sh(cmd, timeout: timeout + 2000) do
          %{exit: 0, output: out} -> %{host: host, ok: true, output: out}
          %{exit: code, output: out} -> %{host: host, ok: false, exit: code, output: out}
        end
      end,
      timeout: timeout + 5000,
      max_concurrency: 8
    )
    |> Enum.map(fn
      {:ok, r} -> r
      {:exit, reason} -> %{ok: false, error: inspect(reason)}
    end)
  end
end
