defmodule Newbee.Environment.PluginContract do
  @moduledoc """
  Plugin Contract (DESIGN §4.5)：能力的唯一形态的强制 Envelope。

  **"源码能编译" ≠ "合法插件"**。第一阶段强制 Envelope + `capabilities`
  声明——先统一生命周期与安全边界，再逐步加深类型约束。

  - 无状态工具只实现静态子集（id/version/describe/dependencies），
    runtime 用兼容包装器运行；
  - 有状态插件必须实现 start/stop/migrate，并声明 `effects` 清单，
    一切 effect 经 runtime wrapper 创建和登记（见 PluginSupervisor）。
  """

  alias Newbee.Environment.ToolContract

  @callback id() :: String.t()
  @callback version() :: String.t()
  @callback describe() :: map()
  @callback dependencies() :: list()

  @callback health(context :: map()) :: :ok | {:error, term()}
  @callback self_test(context :: map()) :: {:ok, map()} | {:error, term()}

  @callback start(context :: map()) :: {:ok, term()} | {:error, term()}
  @callback stop(state :: term()) :: :ok
  @callback migrate(old_version :: term(), state :: term(), context :: map()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks health: 1,
                      self_test: 1,
                      start: 1,
                      stop: 1,
                      migrate: 3

  @static_callbacks [id: 0, version: 0, describe: 0, dependencies: 0]
  @lifecycle_callbacks [health: 1, self_test: 1, start: 1, stop: 1, migrate: 3]

  @doc "静态子集是否满足（无状态工具的最低门槛）。"
  def valid_static?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and
      Enum.all?(@static_callbacks, fn {f, a} -> function_exported?(mod, f, a) end)
  end

  @doc "完整 envelope（含生命周期）是否满足（有状态插件的门槛）。"
  def valid_stateful?(mod) when is_atom(mod) do
    valid_static?(mod) and
      Enum.all?(@lifecycle_callbacks, fn {f, a} -> function_exported?(mod, f, a) end)
  end

  @doc "提取模块的 contract envelope。不满足静态子集返回 {:error, reasons}。"
  def envelope(mod) when is_atom(mod) do
    if valid_static?(mod) do
      {:ok,
       %{
         id: mod.id(),
         version: mod.version(),
         describe: mod.describe(),
         dependencies: mod.dependencies(),
         capabilities: describe_field(mod, :capabilities),
         effects: describe_field(mod, :effects),
         state_policy: describe_field(mod, :state_policy) || :stateless,
         usage: describe_field(mod, :usage) || ""
       }}
    else
      {:error, [{mod, :missing_static_callbacks}]}
    end
  end

  @doc """
  校验 release 源码是否构成合法插件（Static 评价层，§8.2）：
  编译 + contract 检查。返回 {:ok, %{module: mod, envelope: env}} | {:error, reasons}。
  编译在调用进程内进行（不热载到全局代码路径之外的东西——Code.compile_string
  只在编译期求值模块体）。
  """
  def validate_source(source), do: validate_source(source, :tool)

  def validate_source(source, kind) when is_binary(source) do
    try do
      Code.put_compiler_option(:ignore_module_conflict, true)
      [{mod, _bin}] = Code.compile_string(source)

      case envelope(mod) do
        {:ok, env} ->
          case validate_kind(mod, env, kind, source) do
            :ok -> {:ok, %{module: mod, envelope: env}}
            {:error, reasons} -> {:error, [{:tool_contract, reasons}]}
          end

        {:error, reasons} ->
          {:error, reasons}
      end
    rescue
      e -> {:error, [{:compile, Exception.message(e)}]}
    after
      Code.put_compiler_option(:ignore_module_conflict, false)
    end
  end

  defp validate_kind(mod, env, :tool, source), do: ToolContract.validate_module(mod, env, source)
  defp validate_kind(_mod, _env, _kind, _source), do: :ok

  defp describe_field(mod, field) do
    case mod.describe() do
      %{^field => v} -> v
      m when is_map(m) -> Map.get(m, Atom.to_string(field))
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
