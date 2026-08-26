defmodule Newbee.Permissions do
  @moduledoc "Capability Policy (DESIGN 8.1): lenient(default)/ask/deny. Host Safety is hard boundary, not configurable."
  @levels [:lenient, :ask, :deny]
  @default :lenient
  @config Path.join(System.user_home!(), ".newbee/config.json")
  @risky_patterns [
    ~r/File\.(write|write!|rm|rm_rf|mkdir|cp|mv|rename|touch)/,
    ~r/Newbee\.Tools\.(Fs\.(write|write!|append!|rm|rm_rf)|Edit\.patch|Structural\.(insert|replace|format)|HotReload\.(replace|load_file|unload))/,
    ~r/System\.cmd|Port\.open|:os\.cmd/,
    ~r/Newbee\.Tools\.Run\.sh/,
    ~r/PluginManager\.(materialize|load_release)|Coordinator\.(activate|rollback)/,
    ~r/mix (test|compile|deps|format)|git (push|reset|rebase|clean|checkout|commit)/
  ]
  def levels, do: @levels
  def get do
    case File.read(@config) do
      {:ok, body} -> case Jason.decode(body) do {:ok, %{"permissions" => p}} when is_binary(p) -> String.to_atom(p); _ -> @default end
      _ -> @default
    end
  rescue _ -> @default
  end
  def set(level) when level in @levels do
    cfg = try do case File.read(@config) do {:ok, b} -> Jason.decode!(b); _ -> %{} end rescue _ -> %{} end
    File.mkdir_p!(Path.dirname(@config))
    File.write!(@config, Jason.encode!(Map.put(cfg, "permissions", to_string(level)), pretty: true))
    :ok
  end
  def risky?(code) when is_binary(code), do: Enum.any?(@risky_patterns, &Regex.match?(&1, code))

  @doc "Capability 检查：:ok 放行 | :ask 需用户确认 | {:deny, reason} 拒绝（§8.1）。"
  def check(code) do
    cond do
      not risky?(code) -> :ok
      get() == :deny -> {:deny, :capability_denied}
      get() == :ask -> :ask
      true -> :ok
    end
  end
end
