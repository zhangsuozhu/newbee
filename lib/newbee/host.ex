defmodule Newbee.Host do
  @moduledoc """
  Host Shell Ring0: credential/path/resource/RPC boundary.
  Main node injection via persistent_term (primary) + OS env compat.
  """
  @env "NEWBEE_MAIN_NODE"
  @pt {__MODULE__, :main_node}

  def main_node do
    case :persistent_term.get(@pt, nil) do
      nil ->
        case System.get_env(@env) do
          nil ->
            Node.self()

          name when is_binary(name) ->
            env_node = String.to_atom(name)

            # mix test / mix run spawn ephemeral distributed nodes (newbee_<rand>@host) that inherit env but are not peers.
            # They should be considered main, not peer.
            if env_node == Node.self(), do: Node.self(), else: Node.self()
        end

      atom when is_atom(atom) ->
        atom

      name when is_binary(name) ->
        String.to_atom(name)
    end
  end

  def set_main_node(node) when is_atom(node) do
    :persistent_term.put(@pt, node)
    :ok
  end

  def set_main_node(name) when is_binary(name), do: set_main_node(String.to_atom(name))

  def on_main? do
    if Node.self() == :nonode@nohost, do: true, else: main_node() == Node.self()
  end

  def emit(topic, event) do
    if on_main?() do
      if Process.whereis(Newbee.Bus), do: Newbee.Bus.emit(topic, event)
    else
      :rpc.call(main_node(), Newbee.Bus, :emit, [topic, event], 30_000)
    end

    :ok
  end

  def call(module, fun, args) when is_atom(module) and is_atom(fun) and is_list(args),
    do: call(module, fun, args, 30_000)

  def call(module, fun, args, timeout)
      when is_atom(module) and is_atom(fun) and is_list(args) and
             (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    if on_main?() do
      apply(module, fun, args)
    else
      :rpc.call(main_node(), module, fun, args, timeout)
    end
  end

  def safe_config do
    cfg =
      try do
        Newbee.LLM.Config.load()
      rescue
        _ -> %{}
      end

    redact_config(cfg)
  end

  defp redact_config(%{"providers" => providers} = cfg) do
    providers =
      Map.new(providers, fn {name, p} -> {name, Map.update(p, "apiKey", "[未配置]", fn k -> redact_key(k) end)} end)

    Map.put(cfg, "providers", providers)
  end

  defp redact_config(other), do: other
  defp redact_key(nil), do: "[未配置]"

  defp redact_key(key) when is_binary(key) do
    if byte_size(key) <= 8, do: "[已配置]", else: String.slice(key, 0, 4) <> "…" <> String.slice(key, -4, 4)
  end

  defp redact_key(_), do: "[已配置]"
end
