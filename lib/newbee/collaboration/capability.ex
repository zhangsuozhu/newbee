defmodule Newbee.Collaboration.Capability do
  @moduledoc """
  模型协作能力令牌。Agent.Loop 在主节点注册自身真实会话，单次 run_elixir
  前签发随机短时令牌；隔离 evaluator 只能持令牌解析身份，不能声明任意 session_id。
  """
  use GenServer

  @ttl_ms 10 * 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(owner, session_id, project_root, server \\ __MODULE__)

  def register(owner, session_id, project_root, server)
      when is_pid(owner) and is_binary(session_id) and is_binary(project_root) do
    GenServer.call(server, {:register, owner, session_id, Path.expand(project_root)})
  end

  def register(_, _, _, _), do: {:error, "invalid_context", "会话能力上下文无效"}

  def issue(owner, server \\ __MODULE__) when is_pid(owner) do
    GenServer.call(server, {:issue, owner})
  end

  def resolve(token, server \\ __MODULE__)

  def resolve(token, server) when is_binary(token) do
    GenServer.call(server, {:resolve, token})
  end

  def resolve(_, _), do: {:error, "invalid_capability", "协作能力令牌无效"}

  def revoke(token, server \\ __MODULE__)

  def revoke(token, server) when is_binary(token) do
    GenServer.cast(server, {:revoke, token})
  end

  def revoke(_, _), do: :ok

  @impl true
  def init(:ok), do: {:ok, %{owners: %{}, tokens: %{}}}

  @impl true
  def handle_call({:register, owner, session_id, root}, {caller, _}, state) do
    if caller == owner do
      state = drop_owner(state, owner)
      ref = Process.monitor(owner)
      owner_context = %{session_id: session_id, project_root: root, monitor: ref}
      {:reply, :ok, put_in(state, [:owners, owner], owner_context)}
    else
      {:reply, {:error, "capability_forbidden", "只能注册当前 Agent.Loop"}, state}
    end
  end

  def handle_call({:issue, owner}, {caller, _}, state) do
    case state.owners[owner] do
      context when caller == owner and is_map(context) ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        expires_at = System.monotonic_time(:millisecond) + @ttl_ms

        capability = %{
          owner: owner,
          session_id: context.session_id,
          project_root: context.project_root,
          expires_at: expires_at
        }

        {:reply, {:ok, token}, put_in(state, [:tokens, token], capability)}

      _ ->
        {:reply, {:error, "capability_forbidden", "当前进程没有协作身份"}, state}
    end
  end

  def handle_call({:resolve, token}, _from, state) do
    case state.tokens[token] do
      %{expires_at: expires_at} = capability ->
        if expires_at > System.monotonic_time(:millisecond) and Process.alive?(capability.owner) do
          {:reply, {:ok, Map.take(capability, [:session_id, :project_root])}, state}
        else
          {:reply, {:error, "capability_expired", "协作能力令牌已失效"}, %{state | tokens: Map.delete(state.tokens, token)}}
        end

      nil ->
        {:reply, {:error, "invalid_capability", "协作能力令牌无效"}, state}
    end
  end

  @impl true
  def handle_cast({:revoke, token}, state) do
    {:noreply, %{state | tokens: Map.delete(state.tokens, token)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
    case state.owners[owner] do
      %{monitor: ^ref} -> {:noreply, drop_owner(state, owner, false)}
      _ -> {:noreply, state}
    end
  end

  defp drop_owner(state, owner, demonitor? \\ true) do
    case state.owners[owner] do
      %{monitor: ref} when demonitor? -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    tokens =
      state.tokens
      |> Enum.reject(fn {_token, capability} -> capability.owner == owner end)
      |> Map.new()

    %{state | owners: Map.delete(state.owners, owner), tokens: tokens}
  end
end
