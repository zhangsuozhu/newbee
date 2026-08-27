defmodule Newbee.Web.Api do
  @moduledoc """
  WebUI HTTP API（移植 dsh apiproxy 语义）：`POST /api/<method>` 的
  RPC-over-HTTP 网关。wire 信封对齐 dsh 四象限消息模型的 client-request：

      请求  {"rpcId": "...", "method": "session.prompt", "payload": {...}}
      应答  {"rpcId": "...", "result": {"ok": <value>}} |
            {"rpcId": "...", "result": {"error": {"code": ..., "message": ...}}}

  会话事件下行不走 HTTP，走 WebSocket（见 Newbee.Web.Socket）。
  """
  use Plug.Router

  require Logger

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 20_000_000
  )

  plug(:dispatch)

  # ── RPC envelope ──

  post "/:method" do
    # 注入 origin 供 WebAuthn 使用（从请求 Host + Scheme 推导）
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host || "localhost"
    port_str = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    origin = "#{scheme}://#{host}#{port_str}"
    Newbee.Web.WebAuthn.set_origin(origin)

    rpc_id = get_in(conn.body_params, ["rpcId"]) || "-"
    payload = get_in(conn.body_params, ["payload"]) || %{}

    payload =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> tok | _] -> Map.put(payload, "__token__", String.trim(tok))
        _ -> payload
      end

    case safe_dispatch(method, payload) do
      {:ok, value} ->
        reply(conn, 200, %{rpcId: rpc_id, result: %{ok: json_safe(value)}})

      {:error, code, message} ->
        reply(conn, 200, %{rpcId: rpc_id, result: %{error: %{code: code, message: message}}})
    end
  end

  # 兜底：dispatch 里的异常/exit（典型：GenServer.call 5s 超时、MatchError）不再
  # 杀死连接进程（那样 Bandit 只会回空 500），而是记日志并回 JSON 错误信封，
  # 前端能看到真实原因而不是“服务返回空响应 (HTTP 500)”。
  defp safe_dispatch(method, payload) do
    dispatch_rpc(method, payload)
  rescue
    e ->
      Logger.error("rpc #{method} crashed:\n" <> Exception.format(:error, e, __STACKTRACE__))
      {:error, "internal_error", Exception.message(e)}
  catch
    :exit, reason ->
      Logger.error("rpc #{method} exit: #{Exception.format_exit(reason)}")

      {:error, "internal_exit", "内部调用超时或进程退出（服务繁忙/会话进程卡死）: #{Exception.format_exit(reason)}"}
  end

  # 便捷 GET：会话列表 / 健康检查（不进 RPC 信封，等价 dsh downloads 的 GET 面）
  get "/sessions" do
    metas = Newbee.Session.list_with_meta(50)
    reply(conn, 200, Enum.map(metas, &json_safe/1))
  end

  get "/health" do
    reply(conn, 200, %{ok: true, model: current_model()})
  end

  match _ do
    reply(conn, 404, %{error: "not found"})
  end

  # ── method 分派 ──

  # ── 认证域（远程暴露时强制；本地回环免认证）──

  defp dispatch_rpc("auth.status", _p) do
    {:ok, %{password_set: Newbee.Web.Auth.password_set?()}}
  end

  defp dispatch_rpc("auth.captcha", _p) do
    cap = Newbee.Web.Auth.gen_captcha()
    {:ok, %{captchaId: cap.id, svg: cap.svg}}
  end

  defp dispatch_rpc("auth.setup", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        case Newbee.Web.Auth.setup(p) do
          {:ok, token} -> {:ok, %{token: token}}
          {:error, code, msg} -> {:error, code, msg}
        end

      {:error, _ms} ->
        {:error, "locked", "操作过于频繁，请稍后重试"}
    end
  end

  defp dispatch_rpc("auth.setup", p), do: dispatch_rpc("auth.setup", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  defp dispatch_rpc("auth.login", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.login(p, ip) do
      {:ok, token} -> {:ok, %{token: token}}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  defp dispatch_rpc("auth.login", p), do: dispatch_rpc("auth.login", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  defp dispatch_rpc("auth.logout", %{"__token__" => tok}) do
    Newbee.Web.Auth.revoke_token(tok)
    {:ok, %{logged_out: true}}
  end

  defp dispatch_rpc("auth.logout", _p), do: {:ok, %{logged_out: true}}

  # ── WebAuthn 指纹/面容登录 ──

  defp dispatch_rpc("webauthn.has_credentials", _p) do
    {:ok, %{has_credentials: Newbee.Web.WebAuthn.has_credentials?()}}
  end

  defp dispatch_rpc("webauthn.list", _p) do
    {:ok, %{credentials: Newbee.Web.WebAuthn.list_credentials()}}
  end

  defp dispatch_rpc("webauthn.register_challenge", p) do
    name = Map.get(p, "name", "未命名设备")

    case Newbee.Web.WebAuthn.registration_challenge(name) do
      {:ok, opts} -> {:ok, opts}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  defp dispatch_rpc("webauthn.register", p) do
    with {:ok, challenge_id} <- fetch_param(p, "challenge_id"),
         {:ok, attestation_object} <- fetch_param(p, "attestation_object"),
         {:ok, client_data_json} <- fetch_param(p, "client_data_json"),
         {:ok, cred_id} <- fetch_param(p, "credential_id") do
      case Newbee.Web.WebAuthn.register(challenge_id, attestation_object, client_data_json, cred_id) do
        {:ok, result} -> {:ok, result}
        {:error, code, msg} -> {:error, code, msg}
      end
    else
      {:error, :missing_param} -> {:error, "bad_request", "缺少必需参数"}
    end
  end

  defp dispatch_rpc("webauthn.delete", p) do
    case fetch_param(p, "credential_id") do
      {:ok, cred_id} ->
        case Newbee.Web.WebAuthn.delete_credential(cred_id) do
          :ok -> {:ok, %{deleted: true}}
          {:error, code, msg} -> {:error, code, msg}
        end

      {:error, :missing_param} ->
        {:error, "bad_request", "缺少 credential_id"}
    end
  end

  defp dispatch_rpc("webauthn.login_challenge", _p) do
    case Newbee.Web.WebAuthn.authentication_challenge() do
      {:ok, opts} -> {:ok, opts}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  defp dispatch_rpc("webauthn.login", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        with {:ok, challenge_id} <- fetch_param(p, "challenge_id"),
             {:ok, cred_id} <- fetch_param(p, "credential_id"),
             {:ok, auth_data} <- fetch_param(p, "authenticator_data"),
             {:ok, sig} <- fetch_param(p, "signature"),
             {:ok, client_data_json} <- fetch_param(p, "client_data_json") do
          case Newbee.Web.WebAuthn.authenticate(challenge_id, cred_id, auth_data, sig, client_data_json) do
            {:ok, _} ->
              {:ok, token} = Newbee.Web.Auth.issue_token()
              Newbee.Web.Auth.record_success(ip)
              {:ok, %{token: token}}

            {:error, code, msg} ->
              Newbee.Web.Auth.record_fail(ip)
              {:error, code, msg}
          end
        else
          {:error, :missing_param} -> {:error, "bad_request", "缺少必需参数"}
        end

      {:error, _ms} ->
        {:error, "locked", "操作过于频繁，请稍后重试"}
    end
  end

  defp dispatch_rpc("webauthn.login", p),
    do: dispatch_rpc("webauthn.login", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 会话域
  defp dispatch_rpc("session.list", p) do
    # 分页：limit 默认 50（上限 200），offset 默认 0；total 供前端算“加载更多”
    limit = clamp_int(p["limit"], 50, 1, 200)
    offset = clamp_int(p["offset"], 0, 0, 100_000)

    # 空壳会话回收（懒落盘的兜底）：只在拉第一页时做，60s 限频
    if offset == 0, do: maybe_sweep_empty_sessions()

    sessions =
      Newbee.Session.list_with_meta(limit, offset)
      |> Enum.map(fn s ->
        id = s[:id] || s["id"]
        busy = Newbee.Web.Session.peek_busy(id)
        running = match?({:ok, _}, Newbee.Web.Session.lookup(id))

        Map.merge(s, %{
          running: running,
          busy: busy,
          cwd: Newbee.Session.cwd(id)
        })
      end)

    {:ok, %{sessions: Enum.map(sessions, &json_safe/1), total: Newbee.Session.count_valid()}}
  end

  defp dispatch_rpc("session.history", %{"sessionId" => sid}) do
    session = Newbee.Session.open(sid)
    msgs = session |> Newbee.Session.messages() |> Enum.map(&history_msg/1)
    {:ok, %{messages: inject_archive_divider(session, msgs)}}
  end

  defp dispatch_rpc("session.create", p) do
    sid = p["sessionId"]

    case Newbee.Web.Session.ensure(blank_to_nil(sid), blank_to_nil(p["cwd"])) do
      {:ok, _pid, sid} -> {:ok, %{sessionId: sid, cwd: Newbee.Session.cwd(sid)}}
      {:error, r} -> {:error, "session_error", inspect(r)}
      other -> {:error, "session_error", inspect(other)}
    end
  end

  defp dispatch_rpc("session.cwd", %{"sessionId" => sid, "cwd" => cwd}) do
    with {:ok, pid} <- find_session(sid),
         {:ok, expanded} <- Newbee.Web.Session.set_cwd(pid, cwd) do
      {:ok, %{sessionId: sid, cwd: expanded}}
    else
      {:error, code, message} -> {:error, code, message}
      {:error, reason} -> {:error, "cwd_error", inspect(reason)}
    end
  end

  defp dispatch_rpc("session.resume", %{"sessionId" => sid}) do
    case Newbee.Web.Session.ensure(sid) do
      {:ok, _pid, sid} -> {:ok, %{sessionId: sid}}
      {:error, r} -> {:error, "session_error", inspect(r)}
    end
  end

  defp dispatch_rpc("session.delete", %{"sessionId" => sid}) do
    case Newbee.Web.Session.destroy(sid) do
      :ok -> {:ok, %{deleted: sid}}
      {:error, r} -> {:error, "delete_error", inspect(r)}
    end
  end

  defp dispatch_rpc("session.rename", %{"sessionId" => sid, "title" => t}) do
    Newbee.Session.rename(sid, String.trim(t || ""))
    {:ok, %{sessionId: sid, title: t}}
  rescue
    e -> {:error, "rename_error", Exception.message(e)}
  end

  defp dispatch_rpc("session.prompt", %{"sessionId" => sid, "text" => text})
       when is_binary(sid) and is_binary(text) do
    if String.trim(sid) == "" or text == "" do
      {:error, "bad_request", "sessionId 和 text 不能为空"}
    else
      with {:ok, pid} <- find_session(sid) do
        Newbee.Web.Session.prompt(pid, text)
        {:ok, %{accepted: true}}
      end
    end
  end

  defp dispatch_rpc("session.prompt", _payload),
    do: {:error, "bad_request", "需要 sessionId 和 text 字段"}

  defp dispatch_rpc("session.promptImage", %{
         "sessionId" => sid,
         "images" => images,
         "text" => text
       }) do
    with {:ok, pid} <- find_session(sid) do
      if images == nil or images == [] do
        Newbee.Web.Session.prompt(pid, text || "")
      else
        Newbee.Web.Session.prompt_images(pid, images, text || "")
      end

      {:ok, %{accepted: true}}
    end
  end

  defp dispatch_rpc("session.cancel", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.interrupt(pid)
      {:ok, %{interrupted: true}}
    end
  end

  # ── 媒体上屏域 ──
  defp dispatch_rpc("media.list", %{"sessionId" => sid}) do
    case Newbee.Media.list(sid) do
      {:ok, items} -> {:ok, %{items: json_safe(items)}}
    end
  end

  defp dispatch_rpc("media.delete", %{"sessionId" => sid, "mediaId" => media_id}) do
    case Newbee.Media.delete(sid, media_id) do
      :ok -> {:ok, %{deleted: media_id}}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  defp dispatch_rpc("session.state", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      {:ok, Newbee.Web.Session.state(pid)}
    end
  end

  defp dispatch_rpc("project.test", _p) do
    # 检测项目类型并运行对应测试
    {cmd, args} =
      cond do
        File.exists?("mix.exs") ->
          {"mix", ["test", "--color", "false"]}

        File.exists?("Cargo.toml") ->
          {"cargo", ["test"]}

        File.exists?("package.json") ->
          {"npm", ["test"]}

        File.exists?("pytest.ini") or File.exists?("setup.py") ->
          {"python", ["-m", "pytest", "-x", "--tb=short"]}

        true ->
          {"echo", ["未检测到项目类型"]}
      end

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, %{output: tail(out, 3000), passed: true, cmd: cmd <> " " <> Enum.join(args, " ")}}

      {out, code} ->
        {:ok,
         %{
           output: tail(out, 3000),
           passed: false,
           exit: code,
           cmd: cmd <> " " <> Enum.join(args, " ")
         }}
    end
  rescue
    e -> {:error, "test_error", Exception.message(e)}
  end

  defp dispatch_rpc("git.checkpoint.create", %{"description" => desc}) do
    desc = String.trim(desc || "")
    label = if desc == "", do: "checkpoint", else: String.slice(desc, 0, 60)

    case dispatch_rpc("git.diffStat", %{}) do
      {:ok, %{files: files}} when files != [] ->
        case git_cmd(["add", "-A"]) do
          {:ok, _} ->
            msg = "[checkpoint] " <> label
            commit_result = git_cmd(["commit", "-m", msg, "--allow-empty"])

            case commit_result do
              {:ok, out} -> {:ok, %{committed: true, message: msg, output: tail(out, 500)}}
              {:error, e} -> {:error, "git_error", to_string(e)}
            end

          {:error, e} ->
            {:error, "git_error", to_string(e)}
        end

      {:ok, _} ->
        {:error, "nothing_to_checkpoint", "无变更可创建 checkpoint"}

      err ->
        err
    end
  end

  defp dispatch_rpc("session.selectModel", %{
         "sessionId" => sid,
         "provider" => provider,
         "model" => model
       }) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.switch_model(pid, provider, model) do
        :ok -> {:ok, %{provider: provider, model: model}}
        {:error, r} -> {:error, "model_error", inspect(r)}
      end
    end
  end

  defp dispatch_rpc("session.bindings", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      bindings =
        try do
          kernel = Newbee.Web.Session.kernel_pid(pid)

          if kernel && Process.alive?(kernel) do
            case Newbee.SessionEvaluators.lookup(kernel) do
              {:ok, evaluator} when is_pid(evaluator) ->
                Newbee.DEE.Evaluator.bindings_summary(evaluator, 3_000)

              _ ->
                []
            end
          else
            []
          end
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      {:ok, %{bindings: json_safe(bindings)}}
    end
  end

  # 兼容旧调用：仅 modelId
  defp dispatch_rpc("session.selectModel", %{"sessionId" => sid, "modelId" => mid}) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.switch_model(pid, mid) do
        :ok -> {:ok, %{model: mid}}
        {:error, r} -> {:error, "model_error", inspect(r)}
      end
    end
  end

  defp dispatch_rpc("git.checkpoint.list", _p) do
    case git_cmd(["log", "--oneline", "--all", "--grep=[checkpoint]", "-20"]) do
      {:ok, out} ->
        checkpoints =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [sha | rest] = String.split(line, " ", parts: 2)
            msg = Enum.join(rest, " ")
            desc = msg |> String.replace_prefix("[checkpoint] ", "") |> String.slice(0, 80)
            %{sha: sha, description: desc}
          end)

        {:ok, %{checkpoints: checkpoints}}

      {:error, _e} ->
        # 无 commits 的 repo 也算正常
        {:ok, %{checkpoints: []}}
    end
  end

  defp dispatch_rpc("session.setEffort", %{"sessionId" => sid, "effort" => effort}) do
    with {:ok, pid} <- find_session(sid) do
      case Newbee.Web.Session.set_effort(pid, blank_to_nil(effort)) do
        {:ok, res} -> {:ok, Map.put(res, :effort, blank_to_nil(effort))}
        {:error, r} -> {:error, "effort_error", inspect(r)}
      end
    end
  end

  defp dispatch_rpc("env.health", _p) do
    # 沉睡规则
    rules =
      try do
        Newbee.DEE.Rules.list()
        |> Enum.map(fn r ->
          %{
            id: r[:id] || Map.get(r, :id) || "?",
            kind: to_string(r[:kind] || Map.get(r, :kind) || ""),
            pattern: String.slice(to_string(r[:pattern] || Map.get(r, :pattern) || ""), 0, 80),
            hits: r[:hits] || Map.get(r, :hits) || 0
          }
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    rule_hits =
      try do
        Newbee.DEE.Rules.hits()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    # 失败抗体
    antibodies =
      try do
        project = File.cwd!()

        Newbee.Environment.Antibodies.all(project)
        |> Enum.map(fn a ->
          %{
            id: a["id"] || a[:id] || "?",
            error: String.slice(to_string(a["error"] || a[:error] || ""), 0, 100),
            verified: a["verified"] || a[:verified] || false
          }
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    verified =
      try do
        Newbee.Environment.Antibodies.verified_count(File.cwd!())
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    {:ok,
     %{
       rules: %{count: length(rules), items: rules, hits: json_safe(rule_hits)},
       antibodies: %{count: length(antibodies), verified: verified, items: antibodies}
     }}
  end

  defp dispatch_rpc("git.commit", %{"message" => msg}) do
    msg = String.trim(msg || "")

    if msg == "" do
      {:error, "empty_message", "提交信息不能为空"}
    else
      with {:ok, add_out} <- git_cmd(["add", "-A"]),
           {:ok, commit_out} <- git_cmd(["commit", "-m", msg]) do
        {:ok, %{output: tail(to_string(add_out) <> to_string(commit_out), 2000), message: msg}}
      else
        {:error, err} -> {:error, "git_error", err}
      end
    end
  end

  # ── 环境健康（沉睡规则 / 抗体 / JIT）──
  # 主机域
  defp dispatch_rpc("host.describe", _p) do
    {:ok,
     %{
       cwd: File.cwd!(),
       model: current_model_label(),
       policy: Newbee.Environment.Autonomy.get(),
       auth_required: Newbee.Web.Auth.auth_required?(Newbee.Web.Router.bind_ip()),
       password_set: Newbee.Web.Auth.password_set?(),
       version: "0.1.0"
     }}
  end

  # ── 工作目录域（学 dsh harness：服务端目录浏览 + 新建子目录）──

  defp dispatch_rpc("workspace.home", _p) do
    {:ok, %{home: System.user_home!(), default: File.cwd!()}}
  end

  defp dispatch_rpc("workspace.listDir", p) do
    case Newbee.Web.Workspace.list_dir(p["path"]) do
      {:ok, listing} -> {:ok, listing}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  defp dispatch_rpc("workspace.mkdir", %{"path" => parent, "name" => name}) do
    case Newbee.Web.Workspace.mkdir(parent, name) do
      {:ok, path} -> {:ok, %{path: path}}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  # 权限回复（server-request 象限的 respond 语义）
  defp dispatch_rpc("respond", %{"sessionId" => sid, "permission" => ok}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.permission_reply(pid, ok)
      {:ok, %{delivered: true}}
    end
  end

  # 模型目录
  defp dispatch_rpc("llm.models", p) do
    opts = if p["refresh"] == true, do: [refresh: true], else: []
    cat = Newbee.LLM.Config.model_catalog(opts)
    {:ok, %{providers: cat.providers, current: current_model_info(p["sessionId"])}}
  end

  # 按厂商刷新模型列表（只拉指定 provider）
  defp dispatch_rpc("llm.providerModels", p) do
    name = p["provider"] || ""
    opts = if p["refresh"] == true, do: [refresh: true], else: []

    case Newbee.LLM.Config.provider_models_by_name(name, opts) do
      nil -> {:error, "unknown_provider", name}
      models -> {:ok, %{provider: name, models: models}}
    end
  end

  # 单模型上下文窗口覆盖：持久化到 model.json 的 providers.<name>.contextWindows，
  # 并实时推给所有在线会话（provider+model 匹配的热更新 client 与压缩口径）。
  # contextWindow: 正整数覆盖；nil/""/0 清除覆盖（恢复自动探测）。
  defp dispatch_rpc("llm.setContextWindow", %{"provider" => provider, "model" => model} = p) do
    with {:ok, n} <- parse_context_window(p["contextWindow"]),
         :ok <- Newbee.LLM.Config.set_context_window(provider, model, n) do
      hot_apply_context_window(provider, model, n)
      {:ok, %{provider: provider, model: model, contextWindow: n}}
    else
      {:error, :bad_context_window} ->
        {:error, "bad_context_window", "上下文窗口须为正整数（或留空恢复自动）"}

      {:error, {:unknown_provider, name}} ->
        {:error, "unknown_provider", name}
    end
  end

  defp dispatch_rpc("llm.setContextWindow", _p),
    do: {:error, "bad_request", "缺少 provider / model 参数"}

  # 进化域（左侧进化面板数据）
  defp dispatch_rpc("evolution.feed", p) do
    n = min(max(p["n"] || 100, 1), 300)
    {:ok, %{events: project_evolution_events(n)}}
  end

  defp dispatch_rpc("evolution.approve", %{"changeId" => change_id}) when is_binary(change_id) do
    case Process.whereis(Newbee.Environment.Coordinator) do
      nil ->
        {:error, "coordinator_down", "环境 Coordinator 未运行"}

      _pid ->
        case Newbee.Environment.Coordinator.approve(
               Newbee.Environment.Coordinator,
               change_id,
               "web:user"
             ) do
          :ok -> {:ok, %{approved: true, change_id: change_id}}
          {:error, reason} -> {:error, "approval_failed", inspect(reason)}
        end
    end
  end

  defp dispatch_rpc("evolution.approve", _p),
    do: {:error, "invalid_change", "缺少 changeId"}

  defp dispatch_rpc("evolution.reevaluate", %{"changeId" => change_id})
       when is_binary(change_id) do
    case Process.whereis(Newbee.Environment.Coordinator) do
      nil ->
        {:error, "coordinator_down", "环境 Coordinator 未运行"}

      _pid ->
        case Newbee.Environment.Coordinator.reevaluate(Newbee.Environment.Coordinator, change_id) do
          {:ok, change} ->
            {:ok,
             %{
               reevaluating: true,
               change_id: change.change_id,
               base_revision: change.base_revision
             }}

          {:error, :already_active} ->
            {:ok, %{reevaluating: false, already_active: true, change_id: change_id}}

          {:error, reason} ->
            {:error, "reevaluation_failed", inspect(reason)}
        end
    end
  end

  defp dispatch_rpc("evolution.reevaluate", _p),
    do: {:error, "invalid_change", "缺少 changeId"}

  defp dispatch_rpc("evolution.trigger", _p) do
    case Newbee.Host.on_main?() do
      true ->
        :ok = Newbee.Daemon.evolve_now()
        {:ok, %{triggered: true}}

      false ->
        main = Newbee.Host.main_node()

        if main && Node.ping(main) == :pong do
          r = :rpc.call(main, Newbee.Daemon, :evolve_now, [])
          {:ok, %{triggered: r == :ok, node: main}}
        else
          {:error, :main_node_unreachable}
        end
    end
  end

  defp dispatch_rpc("evolution.status", _p) do
    autonomy = Newbee.Environment.Autonomy.get()
    {coord_state, active_releases, changes} = evolution_coordinator_state(autonomy)

    release_stats =
      active_releases
      |> Enum.map(&release_with_fitness/1)
      |> Enum.sort_by(&(-Map.get(&1, "uses", 0)))

    pending_signals =
      try do
        Newbee.Agent.Protocol.pending_needs()
        |> Enum.take(-20)
        |> Enum.reverse()
        |> Enum.map(fn signal ->
          payload = signal["payload"] || %{}

          %{
            "id" => signal["message_id"],
            "capability" => payload["capability"],
            "evidence" => payload["evidence"],
            "urgency" => payload["urgency"],
            "created_at" => signal["created_at"]
          }
        end)
      rescue
        _ -> []
      end

    recent_evo = project_evolution_events(1) |> List.first()

    {:ok,
     %{
       autonomy: autonomy,
       autonomy_label: autonomy_label(autonomy),
       coordinator: json_safe(coord_state),
       changes: json_safe(changes),
       pending_signals: json_safe(pending_signals),
       active_releases: json_safe(release_stats),
       last_evolution: json_safe(recent_evo),
       engine: %{
         coordinator_online: Process.whereis(Newbee.Environment.Coordinator) != nil,
         daemon_online: Process.whereis(Newbee.Daemon) != nil,
         event_store_bytes: project_event_store_size(),
         event_log_bytes: Newbee.EventLog.size()
       }
     }}
  end

  # ── Git / 文件变更追踪（Mission Control 面板数据源）──

  defp dispatch_rpc("git.diffStat", _p) do
    case git_cmd(["diff", "--numstat", "HEAD", "--"]) do
      {:ok, numstat_out} ->
        tracked = parse_numstat(numstat_out)

        untracked =
          case git_cmd(["ls-files", "--others", "--exclude-standard"]) do
            {:ok, out} ->
              out
              |> String.split("\n", trim: true)
              |> Enum.map(fn path ->
                lines = count_file_lines(path)
                %{path: path, added: lines, deleted: 0, status: "new"}
              end)

            _ ->
              []
          end

        {:ok, %{files: tracked ++ untracked}}

      {:error, msg} ->
        {:error, "git_error", msg}
    end
  end

  defp dispatch_rpc("git.diff", p) do
    path = p["path"]

    args =
      if path && path != "",
        do: ["diff", "HEAD", "--", path],
        else: ["diff", "HEAD"]

    case git_cmd(args) do
      {:ok, diff_text} ->
        untracked_diffs =
          if path && path != "" do
            case git_cmd(["ls-files", "--others", "--exclude-standard", "--", path]) do
              {:ok, out} ->
                if String.trim(out) != "", do: new_file_diff(path), else: ""

              _ ->
                ""
            end
          else
            case git_cmd(["ls-files", "--others", "--exclude-standard"]) do
              {:ok, out} ->
                out
                |> String.split("\n", trim: true)
                |> Enum.map(&new_file_diff/1)
                |> Enum.join("\n")

              _ ->
                ""
            end
          end

        full = if untracked_diffs != "", do: diff_text <> "\n" <> untracked_diffs, else: diff_text
        {:ok, %{diff: full}}

      {:error, msg} ->
        {:error, "git_error", msg}
    end
  end

  # ── 文件搜索（@ 引用自动补全）──

  defp dispatch_rpc("files.search", %{"q" => q}) do
    q = String.trim(q || "")

    if String.length(q) < 1 do
      {:ok, %{files: []}}
    else
      # 用 fd 或 find 搜索项目文件
      case System.cmd(
             "find",
             [
               ".",
               "-type",
               "f",
               "-name",
               "*#{q}*",
               "-not",
               "-path",
               "*/deps/*",
               "-not",
               "-path",
               "*/.git/*",
               "-not",
               "-path",
               "*/_build/*",
               "-not",
               "-path",
               "*/node_modules/*"
             ],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          files =
            out
            |> String.split("\n", trim: true)
            |> Enum.map(&String.trim_leading(&1, "./"))
            |> Enum.take(20)
            |> Enum.map(fn path ->
              ext = Path.extname(path) |> String.trim_leading(".")
              %{path: path, ext: ext}
            end)

          {:ok, %{files: files}}

        _ ->
          {:ok, %{files: []}}
      end
    end
  rescue
    _ -> {:ok, %{files: []}}
  end

  @file_preview_max_bytes 1_048_576

  defp dispatch_rpc("files.read", %{"sessionId" => sid, "path" => path})
       when is_binary(sid) and is_binary(path) do
    root = Newbee.Session.cwd(sid) || File.cwd!()

    with :ok <- validate_preview_path(path),
         {:ok, real_root} <- canonical_path(root),
         {:ok, real_path} <- canonical_path(Path.join(real_root, path)),
         true <- within_root?(real_path, real_root),
         {:ok, stat} <- File.stat(real_path),
         true <- stat.type == :regular,
         true <- stat.size <= @file_preview_max_bytes,
         {:ok, content} <- File.read(real_path),
         true <- String.valid?(content) and not String.contains?(content, <<0>>) do
      {:ok,
       %{
         path: Path.relative_to(real_path, real_root),
         content: content,
         bytes: stat.size,
         language: preview_language(real_path),
         markdown: String.downcase(Path.extname(real_path)) in [".md", ".markdown"]
       }}
    else
      false -> {:error, "file_forbidden", "文件不在当前工作区、不是文本文件或超过 1 MiB"}
      {:error, :enoent} -> {:error, "file_not_found", "文件不存在"}
      {:error, :bad_path} -> {:error, "file_forbidden", "只允许查看当前工作区内的相对路径"}
      {:error, reason} -> {:error, "file_read_error", inspect(reason)}
    end
  rescue
    _ -> {:error, "file_read_error", "无法读取文件"}
  end

  defp dispatch_rpc("files.read", _),
    do: {:error, "bad_request", "需要 sessionId 和 path 字段"}

  # ── 变更影响分析 ──

  defp dispatch_rpc("git.impact", _p) do
    # 1. 获取变更文件列表
    case git_cmd(["diff", "--numstat", "HEAD", "--"]) do
      {:ok, numstat_out} ->
        changed = parse_numstat(numstat_out)

        untracked =
          case git_cmd(["ls-files", "--others", "--exclude-standard"]) do
            {:ok, out} -> String.split(out, "\n", trim: true)
            _ -> []
          end

        # 2. 构建模块依赖图（仅 Elixir 项目）
        dep_map = build_dep_map()

        # 3. 计算每个变更文件的影响
        files =
          (changed ++ Enum.map(untracked, &%{path: &1, added: 0, deleted: 0, status: "new"}))
          |> Enum.map(fn f ->
            path = f.path
            dependents = Map.get(dep_map, path, [])
            risk = risk_level(path, f, length(dependents))

            %{
              path: path,
              added: Map.get(f, :added, 0),
              deleted: Map.get(f, :deleted, 0),
              status: Map.get(f, :status, "modified"),
              dependents: length(dependents),
              dependent_files: Enum.slice(dependents, 0, 5),
              risk: risk,
              is_test: String.contains?(path, "test/"),
              is_config: String.contains?(path, ["config/", "mix.exs", "mix.lock"])
            }
          end)
          |> Enum.sort_by(fn f ->
            {-risk_score(f.risk), -f.dependents, -(f.added + f.deleted)}
          end)

        # 4. 汇总
        total_files = length(files)
        total_added = files |> Enum.map(& &1.added) |> Enum.sum()
        total_deleted = files |> Enum.map(& &1.deleted) |> Enum.sum()
        high_risk = Enum.count(files, &(&1.risk == "high"))
        has_tests = Enum.any?(files, & &1.is_test)

        {:ok,
         %{
           files: files,
           summary: %{
             total_files: total_files,
             total_added: total_added,
             total_deleted: total_deleted,
             high_risk: high_risk,
             has_tests: has_tests,
             overall_risk:
               if(high_risk > 0,
                 do: "high",
                 else: if(total_files > 10, do: "medium", else: "low")
               )
           }
         }}

      {:error, msg} ->
        {:error, "git_error", msg}
    end
  end

  # Keep malformed or newly introduced RPCs inside the JSON protocol. Without
  # this boundary an unknown method raises FunctionClauseError and Plug returns
  # an HTML 500 page, which makes client retries and diagnostics unreliable.
  defp dispatch_rpc(method, _p), do: {:error, "unknown_method", "未知 RPC 方法: #{method}"}

  # 历史回放在压缩切点处插入档案分隔条（§6.6）：UI 看的是全量日志，
  # 分隔条标出"此线以上已被压缩成段——模型实际看到的是分层摘要"。
  defp inject_archive_divider(session, msgs) do
    case Newbee.Archive.current_cut(session) do
      nil ->
        msgs

      %{cut: cut, segments: segs} ->
        divider = %{
          role: "archive",
          content: "已压缩 #{cut} 条早期对话为 #{length(segs)} 段档案（无损，模型可见分层摘要）",
          segments: Enum.map(segs, &%{id: &1.id, messages: &1.messages, intent: &1.first_intent})
        }

        List.insert_at(msgs, cut, divider)
    end
  rescue
    _ -> msgs
  end

  # 60s 限频的清道夫：删 0 字节、超 1 小时、无进程附着的空会话
  defp maybe_sweep_empty_sessions do
    key = {__MODULE__, :last_empty_sweep}
    now = System.system_time(:second)

    if now - :persistent_term.get(key, 0) > 60 do
      :persistent_term.put(key, now)
      Newbee.Web.Session.sweep_stale_empty(3600)
    end

    :ok
  end

  defp clamp_int(v, _default, min, max) when is_integer(v), do: v |> max(min) |> min(max)

  defp clamp_int(v, default, min, max) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> clamp_int(i, default, min, max)
      _ -> default
    end
  end

  defp clamp_int(_, default, _, _), do: default

  # 构建模块依赖图：{文件路径 => [依赖它的文件列表]}
  defp build_dep_map do
    if File.exists?("mix.exs") do
      # 收集所有 .ex 文件
      ex_files =
        ["lib/**/*.ex", "test/**/*.exs"]
        |> Enum.flat_map(&Path.wildcard/1)

      # 提取每个文件引用的模块
      refs =
        ex_files
        |> Enum.map(fn f ->
          case File.read(f) do
            {:ok, content} ->
              modules = extract_module_refs(content)
              {f, modules}

            _ ->
              {f, []}
          end
        end)

      # 建立模块名 → 文件路径映射
      module_to_file =
        ex_files
        |> Enum.map(fn f ->
          case File.read(f) do
            {:ok, content} ->
              case Regex.run(~r/defmodule\s+([\w.]+)/, content) do
                [_, mod] -> {mod, f}
                _ -> nil
              end

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      # 反转：对每个文件，找出谁引用了它的模块
      refs
      |> Enum.reduce(%{}, fn {file, modules}, acc ->
        Enum.reduce(modules, acc, fn mod, acc2 ->
          case Map.get(module_to_file, mod) do
            nil ->
              acc2

            target_file ->
              if target_file != file do
                Map.update(acc2, target_file, [file], &[file | &1])
              else
                acc2
              end
          end
        end)
      end)
    else
      %{}
    end
  end

  defp extract_module_refs(content) do
    # 提取 Newbee.Foo.Bar 这样的模块引用
    Regex.scan(~r/\b(Newbee\.[A-Z][\w.]*)/, content)
    |> Enum.map(fn [_, mod] -> mod end)
    |> Enum.uniq()
  end

  defp risk_level(path, f, dependent_count) do
    cond do
      dependent_count >= 5 -> "high"
      String.contains?(path, "config/") or path == "mix.exs" -> "high"
      dependent_count >= 2 -> "medium"
      String.contains?(path, "test/") -> "low"
      Map.get(f, :status) == "new" -> "low"
      Map.get(f, :added, 0) + Map.get(f, :deleted, 0) > 100 -> "medium"
      true -> "low"
    end
  end

  defp risk_score("high"), do: 3
  defp risk_score("medium"), do: 2
  defp risk_score("low"), do: 1
  defp risk_score(_), do: 0
  # ── Git helpers ──

  defp tail(str, n) when is_binary(str) do
    len = String.length(str)

    if len > n do
      String.slice(str, len - n, n)
    else
      str
    end
  end

  defp tail(v, n), do: v |> to_string() |> tail(n)

  defp validate_preview_path(path) do
    trimmed = String.trim(path)

    if trimmed != "" and Path.type(trimmed) == :relative and not String.contains?(trimmed, <<0>>),
      do: :ok,
      else: {:error, :bad_path}
  end

  defp canonical_path(path) do
    case System.cmd("readlink", ["-f", "--", Path.expand(path)], stderr_to_stdout: true) do
      {resolved, 0} -> {:ok, String.trim(resolved)}
      _ -> {:error, :enoent}
    end
  end

  defp within_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp preview_language(path) do
    case String.downcase(Path.extname(path)) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".js" -> "javascript"
      ".mjs" -> "javascript"
      ".cjs" -> "javascript"
      ".ts" -> "typescript"
      ".mts" -> "typescript"
      ".cts" -> "typescript"
      ".jsx" -> "jsx"
      ".tsx" -> "tsx"
      ".java" -> "java"
      ".kt" -> "kotlin"
      ".kts" -> "kotlin"
      ".c" -> "c"
      ".h" -> "c"
      ".cc" -> "cpp"
      ".cpp" -> "cpp"
      ".cxx" -> "cpp"
      ".hh" -> "cpp"
      ".hpp" -> "cpp"
      ".hxx" -> "cpp"
      ".cs" -> "csharp"
      ".css" -> "css"
      ".scss" -> "scss"
      ".less" -> "less"
      ".html" -> "html"
      ".htm" -> "html"
      ".xml" -> "xml"
      ".vue" -> "html"
      ".svelte" -> "html"
      ".json" -> "json"
      ".jsonc" -> "json"
      ".md" -> "markdown"
      ".markdown" -> "markdown"
      ".yml" -> "yaml"
      ".yaml" -> "yaml"
      ".toml" -> "toml"
      ".sh" -> "shell"
      ".bash" -> "shell"
      ".zsh" -> "shell"
      ".py" -> "python"
      ".pyw" -> "python"
      ".rs" -> "rust"
      ".go" -> "go"
      ext -> String.trim_leading(ext, ".") || "text"
    end
  end

  defp git_cmd(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "git exit #{code}: #{String.slice(out, 0, 500)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_numstat(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t") do
        [added, deleted, path] ->
          %{
            path: path,
            added: String.to_integer(added),
            deleted: String.to_integer(deleted),
            status: "modified"
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp count_file_lines(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n") |> length()
      _ -> 0
    end
  end

  defp new_file_diff(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        header =
          "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@"

        body = lines |> Enum.map(&("+" <> &1)) |> Enum.join("\n")
        header <> "\n" <> body

      _ ->
        ""
    end
  end

  # ── helpers ──

  # llm.setContextWindow 参数解析：nil/""/0 → 清除覆盖；正整数（或数字串）→ 覆盖值；其余拒绝
  defp parse_context_window(nil), do: {:ok, nil}
  defp parse_context_window(""), do: {:ok, nil}
  defp parse_context_window(0), do: {:ok, nil}
  defp parse_context_window(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_context_window(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> {:ok, n}
      {0, ""} -> {:ok, nil}
      _ -> {:error, :bad_context_window}
    end
  end

  defp parse_context_window(_), do: {:error, :bad_context_window}

  # 上下文窗口覆盖推给所有在线 Web 会话；会话进程自己判断 provider/model 是否匹配
  defp hot_apply_context_window(provider, model, n) do
    Newbee.Web.SessionRegistry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid ->
      GenServer.cast(pid, {:hot_context_window, provider, model, n})
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp find_session(sid) do
    case Newbee.Web.Session.ensure(sid) do
      {:ok, pid, _sid} -> {:ok, pid}
      {:error, r} -> {:error, "session_error", inspect(r)}
    end
  end

  # 只放行字符串（trim 后空串归 nil）；其他 JSON 类型（对象/数组/数字等，
  # 如前端误传的事件对象序列化出的 %{}）一律视为 nil，避免下游函数子句崩溃。
  defp blank_to_nil(s) when is_binary(s) do
    s = String.trim(s)
    if s == "", do: nil, else: s
  end

  defp blank_to_nil(_), do: nil

  defp current_model(sid \\ nil) do
    try do
      if sid do
        case Newbee.Web.Session.lookup(sid) do
          {:ok, pid} -> Newbee.Web.Session.state(pid)["model"]
          _ -> Newbee.LLM.Config.client_for().model
        end
      else
        Newbee.LLM.Config.client_for().model
      end
    rescue
      _ -> nil
    end
  end

  defp current_model_info(sid) do
    provider = if sid, do: Newbee.Session.provider(sid), else: nil
    model = if sid, do: Newbee.Session.model(sid), else: nil

    if provider do
      %{provider: provider, model: model}
    else
      cfg = Newbee.LLM.Config.load()
      default = get_in(cfg, ["roles", "default"]) || %{}
      %{provider: default["provider"], model: model || default["model"]}
    end
  end

  defp current_model_label do
    info = current_model_info(nil)
    if info.model, do: "#{info.provider}/#{info.model}", else: nil
  end

  # transcript 消息 → 前端可渲染结构
  defp history_msg(%{"role" => "user", "content" => c}) when is_binary(c),
    do: %{role: "user", content: c}

  defp history_msg(%{"role" => "user", "content" => content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.find_value(fn part -> if part["type"] == "text", do: part["text"] || "" end) || ""

    images =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn part ->
        if part["type"] == "image_url", do: get_in(part, ["image_url", "url"])
      end)
      |> Enum.reject(&is_nil/1)

    %{role: "user", content: text, images: images}
  end

  defp history_msg(%{"role" => "assistant", "done" => true, "content" => c}) when is_binary(c),
    do: %{role: "done", content: c}

  defp history_msg(%{"role" => "assistant"} = m) do
    calls =
      for c <- m["tool_calls"] || [],
          do: %{
            name: get_in(c, ["function", "name"]),
            title: args_field(c, "title"),
            code: args_field(c, "code"),
            id: c["id"]
          }

    %{
      role: "assistant",
      content: m["content"] || "",
      reasoning: m["reasoning"] || "",
      toolCalls: calls
    }
  end

  defp history_msg(%{"role" => "tool", "tool_call_id" => tcid, "content" => c}) when is_binary(c),
    do: %{role: "tool", content: String.slice(c, 0, 4000), toolCallId: tcid}

  # 兼容无 tool_call_id 的旧记录：仅内容，前端按孤结果兜底渲染

  defp history_msg(%{"role" => "ask", "content" => c}) when is_map(c),
    do: %{role: "ask", content: json_safe(c)}

  defp history_msg(%{"role" => "ask", "content" => c}) when is_binary(c),
    do: %{role: "ask", content: %{question: c, options: [], kind: "text"}}

  defp history_msg(%{"role" => "media", "content" => c}) when is_map(c),
    do: %{role: "media", content: json_safe(c)}

  defp history_msg(%{"role" => "usage", "usage" => u}) when is_map(u),
    do: %{role: "usage", usage: json_safe(u)}

  defp history_msg(_), do: nil

  defp args_field(call, key) do
    case get_in(call, ["function", "arguments"]) do
      args when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, m} -> m[key] || ""
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp reply(conn, status, payload) do
    body = Jason.encode_to_iodata!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp evolution_coordinator_state(autonomy) do
    case Process.whereis(Newbee.Environment.Coordinator) do
      nil ->
        {:down, [], []}

      _pid ->
        try do
          current = Newbee.Environment.Coordinator.current(Newbee.Environment.Coordinator)
          raw_changes = Newbee.Environment.Coordinator.changes(Newbee.Environment.Coordinator)
          revisions = Newbee.Environment.Coordinator.revisions(Newbee.Environment.Coordinator)

          releases =
            Enum.map(current.active || %{}, fn {plugin_id, release_id} ->
              %{
                "plugin" => plugin_id,
                "release" => release_id,
                "kind" => plugin_id |> String.split(".") |> List.first(),
                "name" => plugin_id |> String.split(".") |> Enum.drop(1) |> Enum.join(".")
              }
            end)

          changes =
            raw_changes
            |> Enum.sort_by(&(&1.updated_at || &1.created_at || ""), :desc)
            |> Enum.map(&evolution_change(&1, autonomy, current.revision))

          status_counts = Enum.frequencies_by(changes, & &1["derived_status"])
          open_count = Enum.count(changes, &(not &1["terminal"]))

          coord = %{
            active_revision: current.revision,
            checkpoint: current.checkpoint,
            active_count: length(releases),
            change_count: length(changes),
            open_count: open_count,
            status_counts: status_counts,
            degraded: current.degraded || [],
            revisions: Enum.take(revisions, -8) |> Enum.reverse() |> json_safe()
          }

          {coord, releases, changes}
        rescue
          _ -> {:error, [], []}
        catch
          :exit, _ -> {:error, [], []}
        end
    end
  end

  defp evolution_change(change, autonomy, active_revision) do
    evaluation = change.evaluation_result || %{}
    passed = truthy?(evaluation["passed"] || evaluation[:passed])

    stale =
      not Newbee.Environment.Change.terminal?(change) and change.candidate_revision != nil and
        change.base_revision != active_revision

    derived =
      if stale, do: "stale_base", else: derived_change_status(change.status, autonomy, passed)

    %{
      "change_id" => change.change_id,
      "status" => to_string(change.status),
      "derived_status" => derived,
      "status_label" => change_status_label(derived),
      "terminal" => Newbee.Environment.Change.terminal?(change),
      "can_approve" => derived == "awaiting_approval",
      "can_reevaluate" => derived == "stale_base",
      "next_action" => change_next_action(derived),
      "reason" => change.reason,
      "author" => to_string(change.author_agent),
      "base_revision" => change.base_revision,
      "candidate_release" => change.candidate_revision,
      "release_id" => evaluation["release_id"] || evaluation[:release_id] || change.candidate_revision,
      "plugin_id" => evaluation["plugin_id"] || evaluation[:plugin_id],
      "ring" => evaluation["ring"] || evaluation[:ring],
      "evidence" => change.evidence,
      "evaluation" => %{
        "passed" => passed,
        "evaluated_at" => evaluation["evaluated_at"] || evaluation[:evaluated_at],
        "failed_layers" => evaluation["failed_layers"] || evaluation[:failed_layers] || [],
        "layers" => evaluation_layers(evaluation["layers"] || evaluation[:layers] || %{})
      },
      "created_at" => change.created_at,
      "updated_at" => change.updated_at,
      "deadline" => change.deadline
    }
  end

  defp evaluation_layers(layers) do
    for {key, label} <- [
          {"static", "静态检查"},
          {"deterministic", "确定性测试"},
          {"counterfactual", "反事实回放"},
          {"usage", "真实使用"},
          {"longitudinal", "长期表现"}
        ] do
      result = layers[key] || layers[String.to_atom(key)] || %{}
      skipped = truthy?(result["skipped"] || result[:skipped])
      sufficient = result["sufficient"] || result[:sufficient]

      status =
        cond do
          map_size(result) == 0 -> "pending"
          skipped -> "skipped"
          key == "usage" and sufficient in [false, "false"] -> "observing"
          truthy?(result["passed"] || result[:passed]) -> "passed"
          true -> "failed"
        end

      %{
        "key" => key,
        "label" => label,
        "status" => status,
        "samples" => result["samples"] || result[:samples],
        "replayed" => result["replayed"] || result[:replayed],
        "reason" => result["reason"] || result[:reason]
      }
    end
  end

  defp derived_change_status(:canary, :manual, true), do: "awaiting_approval"
  defp derived_change_status(:canary, :observe, _), do: "suggestion_ready"
  defp derived_change_status(status, _, _), do: to_string(status)

  defp change_status_label("awaiting_approval"), do: "验证通过 · 等待批准"
  defp change_status_label("suggestion_ready"), do: "建议已就绪"
  defp change_status_label("stale_base"), do: "基线已过期"
  defp change_status_label("building"), do: "正在合成候选"
  defp change_status_label("evaluating"), do: "正在验证"
  defp change_status_label("canary"), do: "Canary 观察中"
  defp change_status_label("active"), do: "已激活"
  defp change_status_label("promoted"), do: "已晋升"
  defp change_status_label("rejected"), do: "已拒绝"
  defp change_status_label("degraded"), do: "已退化"
  defp change_status_label("rolled_back"), do: "已回退"
  defp change_status_label(status), do: status

  defp change_next_action("awaiting_approval"), do: "人工批准后生成新 revision"
  defp change_next_action("suggestion_ready"), do: "observe 档位仅记录建议，不激活"
  defp change_next_action("stale_base"), do: "active revision 已推进；需在新基线上重新评测"
  defp change_next_action("building"), do: "候选构建完成后进入五层验证"
  defp change_next_action("evaluating"), do: "确定性门与回放必须通过"
  defp change_next_action("canary"), do: "继续收集 canary 使用证据"
  defp change_next_action("active"), do: "持续观测效果，退化时可回退"
  defp change_next_action("promoted"), do: "持续观测长期表现"
  defp change_next_action("rejected"), do: "候选未越过验证门，不影响 active 环境"
  defp change_next_action("degraded"), do: "等待回退到已知良好 revision"
  defp change_next_action("rolled_back"), do: "已恢复已知良好 revision"
  defp change_next_action(_), do: "等待下一条生命周期事件"

  defp release_with_fitness(rel) do
    observations =
      try do
        Newbee.Environment.Fitness.observations(rel["release"])
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    count = length(observations)

    if count == 0 do
      Map.merge(rel, %{"uses" => 0})
    else
      successes = Enum.count(observations, &truthy?(&1["success"]))
      avg_tokens = observations |> Enum.map(&(&1["tokens"] || 0)) |> Enum.sum() |> div(count)
      avg_latency = observations |> Enum.map(&(&1["latency_ms"] || 0)) |> Enum.sum() |> div(count)

      Map.merge(rel, %{
        "uses" => count,
        "success_rate" => Float.round(successes / count, 2),
        "avg_tokens" => avg_tokens,
        "avg_latency_ms" => avg_latency
      })
    end
  end

  defp project_evolution_events(n) do
    prefixes = ["change_", "revision_", "release_", "generation_", "snapshot_", "evaluation_"]

    project_event_tail()
    |> Enum.filter(fn event ->
      Enum.any?(prefixes, &String.starts_with?(event["topic"] || "", &1))
    end)
    |> Enum.take(-n)
    |> Enum.reverse()
    |> Enum.map(fn event ->
      %{
        "id" => event["id"],
        "topic" => event["topic"],
        "event" => event["data"],
        "at" => event["at"],
        "source" => "project_event_store"
      }
    end)
  end

  defp project_event_tail do
    path = Newbee.Environment.Store.path(:events)

    with {:ok, stat} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      bytes = min(stat.size, 4_000_000)
      start = stat.size - bytes
      {:ok, body} = :file.pread(io, start, bytes)
      File.close(io)

      body
      |> String.split("\n", trim: true)
      |> then(fn lines -> if start > 0, do: Enum.drop(lines, 1), else: lines end)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} -> [event]
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp project_event_store_size do
    case File.stat(Newbee.Environment.Store.path(:events)) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  defp autonomy_label(:observe), do: "观察 · 只产出建议"
  defp autonomy_label(:manual), do: "人工门控 · 验证后批准"
  defp autonomy_label(:autonomous), do: "自主 · 过门后自动激活"
  defp autonomy_label(:emergency_stop), do: "紧急停止 · 仅允许回退"

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  # JSON 安全化（atom key / datetime / tuple）
  defp json_safe(%{__struct__: _} = v), do: v |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = v), do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> json_safe()
  defp json_safe(v) when is_boolean(v), do: v
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v)

  defp fetch_param(map, key) do
    case Map.get(map, key) do
      nil -> {:error, :missing_param}
      val when is_binary(val) -> {:ok, val}
      _ -> {:error, :missing_param}
    end
  end
end
