defmodule Newbee.Collaboration.CrossHost.Firewall do
  @moduledoc "防火墙计划：只生成计划与校验，默认 Hub 单端口，Worker 只出站。"
  @spec loopback?(binary()) :: term()
  def loopback?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end
  def loopback?(_), do: false
  @spec preview_bind_ok?(binary()) :: term()
  def preview_bind_ok?(bind) when is_binary(bind) do
    b = String.trim(bind)
    b == "127.0.0.1" or b == "localhost" or b == "::1"
  end
  def preview_bind_ok?(_), do: false
  @spec plan(binary(), keyword()) :: map()
  def plan(hub_ip, opts \\ []) when is_binary(hub_ip) do
    lan = Keyword.get(opts, :lan, true)
    port = if lan, do: 8443, else: 443
    %{
      "hub_ip" => hub_ip,
      "hub_inbound" => [%{"proto" => "tcp", "port" => port, "src" => Keyword.get(opts, :src, "restricted")}],
      "worker" => "egress_only",
      "preview" => "loopback_only",
      "forbidden" => ["0.0.0.0/0", "3000", "4000", "ssh_change"]
    }
  end
  @spec verify_plan(map(), [map()]) :: :ok | {:error, term(), term()}
  def verify_plan(plan, actual) when is_map(plan) and is_list(actual) do
    need = get_in(plan, ["hub_inbound", Access.at(0), "port"])
    has_hub = Enum.any?(actual, fn r -> Map.get(r, "port") == need and Map.get(r, "proto") == "tcp" end)
    bad_open = Enum.any?(actual, fn r -> Map.get(r, "src") == "0.0.0.0/0" end)
    bad_preview = Enum.any?(actual, fn r -> Map.get(r, "port") in [3000, 4000] end)
    cond do
      not has_hub -> {:error, "missing_hub_rule", "缺少 Hub 入站规则"}
      bad_open -> {:error, "overbroad", "禁止 0.0.0.0/0"}
      bad_preview -> {:error, "preview_exposed", "预览端口不得对外"}
      true -> :ok
    end
  end
  @spec ufw_example(binary(), keyword()) :: [binary()]
  def ufw_example(hub_ip, opts \\ []) when is_binary(hub_ip) do
    lan = Keyword.get(opts, :lan, true)
    port = if lan, do: "8443", else: "443"
    ["ufw allow from restricted to " <> hub_ip <> " port " <> port <> " proto tcp", "ufw default deny incoming", "ufw --dry-run reload"]
  end
end
