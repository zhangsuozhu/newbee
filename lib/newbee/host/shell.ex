defmodule Newbee.Host.Shell do
  @moduledoc """
  Host Shell（DESIGN §4.2，Ring 0）：唯一不可被当前项目模型覆盖的边界。

  - LLM 凭证与 provider 请求（evaluator 节点 env 经 denylist 剥离一切 key）；
  - Agent / Coordinator / Event Store / Evaluator Pool 的 OTP 监督；
  - 项目路径与权限边界；release/manifest 原子提交；generation 切换；
  - 审计与紧急停用（emergency_stop）。

  **不是不能改，是代价极高**（完整反事实回放 + 人工签署 + 独立发布）。
  可变能力必须走 Plugin Contract 接入。

  ## 受控 transport（§12）

  provider 插件是**无凭证的协议适配器**：只能产出经 schema 校验的请求计划；
  凭证注入、域名白名单、预算、重试与实际网络执行全在本模块。
  可变的是"怎么说话"，不可变的是"拿着谁的钥匙、能去哪"。
  """

  alias Newbee.Host

  @doc "域名白名单（受控 transport 只允许这些主机）。"
  def allowed_hosts do
    configured =
      case System.get_env("NEWBEE_ALLOWED_HOSTS") do
        nil -> []
        s -> String.split(s, ",", trim: true)
      end

    Enum.uniq(["openrouter.ai", "api.openrouter.ai"] ++ configured)
  end

  @doc """
  校验并执行一个 provider 插件产出的请求计划。

  plan = %{url, method, headers, body} —— 插件**不含凭证**；
  本函数：① URL host 白名单校验 ② 注入凭证 ③ 预算检查 ④ 执行。
  贴一条 LLM 专用的薄封装（复用同一条路径）。
  """
  def execute_llm_plan(plan, opts \\ []) when is_map(plan), do: execute_request_plan(plan, opts)

  def execute_request_plan(plan, opts \\ []) when is_map(plan) do
    ensure_finch!()

    with {:ok, uri} <- parse_url(plan[:url] || plan["url"]),
         :ok <- check_host_whitelist(uri),
         :ok <- check_budget(opts) do
      headers =
        (plan[:headers] || plan["headers"] || [])
        |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
        # 插件不得自带 authorization/user-agent——凭证与来源注入都是 Host 的事
        |> Enum.reject(fn {k, _} -> String.downcase(k) in ["authorization", "user-agent"] end)
        |> Kernel.++(credential_headers(uri))
        |> Kernel.++([{"user-agent", "newbee"}])

      req =
        Req.new(
          url: plan[:url] || plan["url"],
          method: String.to_atom(plan[:method] || plan["method"] || "post"),
          headers: headers,
          json: plan[:body] || plan["body"],
          receive_timeout: 120_000,
          retry: false
        )

      case Req.request(req) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "确保 Req 的默认 Finch 注册表可用（幂等；求值节点可能未引导 :req 应用）。供 Tools.Http 与受控 transport 复用。"
  def ensure_finch! do
    case Application.ensure_all_started(:req) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "依赖应用启动失败: req — #{inspect(reason)}"
    end
  end

  defp parse_url(nil), do: {:error, :missing_url}

  defp parse_url(url) when is_binary(url) do
    uri = URI.parse(url)
    if uri.host, do: {:ok, uri}, else: {:error, :bad_url}
  end

  defp check_host_whitelist(uri) do
    if uri.host in allowed_hosts() do
      :ok
    else
      audit(:denied, :transport, uri.host)
      {:error, {:host_not_allowed, uri.host}}
    end
  end

  # 凭证只注入对应 provider 域名——绝不发给其他主机（§12 凭证隔离）
  defp credential_headers(uri) do
    cond do
      uri.host in ["openrouter.ai", "api.openrouter.ai"] ->
        case System.get_env("OPENROUTER_API_KEY") do
          nil -> []
          key -> [{"authorization", "Bearer #{key}"}]
        end

      true ->
        []
    end
  end

  # token/并发预算（§12 务实版资源限制）
  defp check_budget(opts) do
    budget = Keyword.get(opts, :budget)

    if budget && budget <= 0 do
      {:error, :budget_exhausted}
    else
      :ok
    end
  end

  # ── 类型化宿主请求（§5 宿主桥 Newbee.Host.*）──

  @doc "调模型（角色路由；evaluator 节点经 RPC 到主节点执行）。"
  def llm_call(role, messages, opts \\ []) do
    Host.call(__MODULE__, :do_llm_call, [role, messages, opts])
  end

  @doc false
  def do_llm_call(role, messages, opts) do
    client = Newbee.LLM.Config.client_for(to_string(role))

    case Keyword.get(opts, :stream) do
      true -> Newbee.LLM.Client.stream_chat(client, messages, fn _ -> :ok end)
      _ -> Newbee.LLM.Client.complete(client, messages, opts)
    end
  end

  @doc "审计（Ring 0 记录，不可被模型伪造来源）。"
  def audit(verdict, actor, target) do
    Host.emit(:audit, {:audit, verdict, actor, target, ring_of_target(target)})
    :ok
  end

  defp ring_of_target(target) when is_atom(target) do
    Newbee.Environment.Autonomy.ring_of(target)
  rescue
    _ -> nil
  end

  defp ring_of_target(_), do: nil

  @doc "紧急停用（Ring 0）：冻结一切环境变更，仅允许回退。"
  def emergency_stop do
    Newbee.Environment.Autonomy.set(:emergency_stop)
    audit(:emergency_stop, :host, :environment)
    :ok
  end

  @doc "项目路径边界：模型写入限制在目标工程目录树内（§12）。"
  def within_project?(path) do
    expanded = Path.expand(path)
    root = File.cwd!() |> Path.expand()
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  @doc "路径边界校验（deny 越界）。"
  def check_path(path) do
    if within_project?(path), do: :ok, else: {:error, :outside_project_root}
  end
end
