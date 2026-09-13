defmodule Newbee.Colony.Id do
  @moduledoc """
  蜂群协作统一 ID 方案。

  过去 Coordinator（单机工作组）与 CrossHost（跨机协作群）各自生成 ID，前缀不一甚至
  同义不同前缀（task_/t_、msg_/m_），无法从一个 ID 判断实体类型与归属后端。

  本模块定义显式、可路由、带命名空间的 ID：`<prefix>_<l|x>_<rand>`。
  scope 是路由提示：l=local（单机），x=xhost（跨机），不影响唯一性。

  设计文档：docs/bee-colony-collaboration-design.md（§10 收敛表、附录 L/N）。
  """

  @type kind ::
          :colony
          | :garden
          | :bee
          | :task
          | :honey
          | :signal
          | :trace
          | :delivery
          | :goal
          | :message
  @type scope :: :local | :xhost

  @kind_prefix %{
    colony: "col",
    garden: "g",
    bee: "bee",
    task: "task",
    honey: "hon",
    signal: "sig",
    trace: "tr",
    delivery: "dlv",
    goal: "goal",
    message: "msg"
  }

  @prefix_kind Map.new(@kind_prefix, fn {k, v} -> {v, k} end)
  @rand_bytes 9

  @doc "生成带命名空间的 ID。scope 仅作为可读路由提示。"
  @spec new(kind, scope) :: binary
  def new(kind, scope \\ :local)
      when is_map_key(@kind_prefix, kind) and scope in [:local, :xhost] do
    rand = @rand_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    scope_tag = if scope == :xhost, do: "x", else: "l"
    "#{@kind_prefix[kind]}_#{scope_tag}_#{rand}"
  end

  @doc "解析 ID：{:ok, %{kind, scope}} | :error。"
  @spec parse(binary) :: {:ok, %{kind: kind, scope: scope}} | :error
  def parse(id) when is_binary(id) do
    case String.split(id, "_", parts: 3) do
      [prefix, scope_tag, _rand]
      when is_map_key(@prefix_kind, prefix) and scope_tag in ["l", "x"] ->
        {:ok, %{kind: @prefix_kind[prefix], scope: if(scope_tag == "x", do: :xhost, else: :local)}}

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @spec kind(binary) :: kind | nil
  def kind(id) do
    case parse(id) do
      {:ok, %{kind: k}} -> k
      _ -> nil
    end
  end

  @spec scope(binary) :: scope | nil
  def scope(id) do
    case parse(id) do
      {:ok, %{scope: s}} -> s
      _ -> nil
    end
  end

  @spec valid?(binary) :: boolean
  def valid?(id), do: match?({:ok, _}, parse(id))

  @doc """
  旧格式归类：把存量前缀（grp_/mem_/task_/msg_/t_/m_/k_/a_/delivery_）映射到实体类型，
  供迁移/兼容层识别旧数据。
  """
  @spec legacy_classify(term) :: {:ok, kind, scope} | :error
  def legacy_classify(id) when is_binary(id) do
    cond do
      String.starts_with?(id, "grp_") -> {:ok, :colony, :local}
      String.starts_with?(id, "mem_") -> {:ok, :bee, :local}
      String.starts_with?(id, "task_") -> {:ok, :task, :local}
      String.starts_with?(id, "msg_") -> {:ok, :signal, :local}
      String.starts_with?(id, "perm_") -> {:ok, :trace, :local}
      String.starts_with?(id, "t_") -> {:ok, :task, :xhost}
      String.starts_with?(id, "k_") -> {:ok, :honey, :xhost}
      String.starts_with?(id, "a_") -> {:ok, :trace, :xhost}
      String.starts_with?(id, "delivery_") -> {:ok, :delivery, :xhost}
      true -> :error
    end
  end

  def legacy_classify(_), do: :error
end
