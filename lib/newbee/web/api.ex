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

    # 注入 User-Agent 供扫码授权页展示"请求设备"摘要
    payload =
      case get_req_header(conn, "user-agent") do
        [ua | _] -> Map.put(payload, "__ua__", ua)
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

  defp dispatch_rpc("auth.status", p) do
    authenticated =
      case Map.get(p, "__token__") do
        token when is_binary(token) -> Newbee.Web.Auth.check_token(token) == :ok
        _ -> false
      end

    {:ok,
     %{
       auth_required: Newbee.Web.Auth.auth_required?(Newbee.Web.Router.bind_ip()),
       authenticated: authenticated,
       password_set: Newbee.Web.Auth.password_set?()
     }}
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

  # ── 扫码授权登录（手机替电脑"盖章"）──
  # 安全核心：配对码只存在于手机的授权 URL，绝不经这些 RPC 回传或出现在二维码里。
  # 电脑端仅凭 pairing_id 轮询；手机端凭已登录会话 + pairing_id 授权。

  # 电脑端：创建配对，拿到 pairing_id（轮询凭证）。二维码内容由前端用服务器基址生成。
  defp dispatch_rpc("pair.create", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        {:ok, %{pairing_id: pairing_id, code: code}} =
          Newbee.Web.Pair.create(%{ua: Map.get(p, "__ua__", ""), ip: ip_to_s(ip)})

        {:ok, %{pairing_id: pairing_id, code: code, ttl_ms: Newbee.Web.Pair.ttl_ms()}}

      {:error, ms} ->
        {:error, "locked", ~s"操作过于频繁，请 #{div(ms, 1000)} 秒后重试"}
    end
  end

  defp dispatch_rpc("pair.create", p),
    do: dispatch_rpc("pair.create", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 电脑端：轮询配对状态。approved 时一次性返回 token（读出即焚）。
  defp dispatch_rpc("pair.status", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        case Newbee.Web.Pair.status(Map.get(p, "pairing_id", "")) do
          {:ok, data} -> {:ok, data}
          {:error, code, msg} -> {:error, code, msg}
        end

      {:error, _ms} ->
        {:error, "locked", "操作过于频繁，请稍后重试"}
    end
  end

  defp dispatch_rpc("pair.status", p),
    do: dispatch_rpc("pair.status", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 手机端：进入授权页后复核配对有效性。
  defp dispatch_rpc("pair.phone_status", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        case Newbee.Web.Pair.phone_status(Map.get(p, "pairing_id", "")) do
          {:ok, data} -> {:ok, data}
          {:error, code, msg} -> {:error, code, msg}
        end

      {:error, _ms} ->
        {:error, "locked", "操作过于频繁，请稍后重试"}
    end
  end

  defp dispatch_rpc("pair.phone_status", p),
    do: dispatch_rpc("pair.phone_status", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 手机端：点"允许"，为电脑签发登录 token。
  defp dispatch_rpc("pair.confirm", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        case Newbee.Web.Pair.confirm(Map.get(p, "pairing_id", ""), %{ua: Map.get(p, "__ua__", "")}) do
          {:ok, data} ->
            Newbee.Web.Auth.record_success(ip)
            {:ok, data}

          {:error, code, msg} ->
            Newbee.Web.Auth.record_fail(ip)
            {:error, code, msg}
        end

      {:error, ms} ->
        {:error, "locked", ~s"操作过于频繁，请 #{div(ms, 1000)} 秒后重试"}
    end
  end

  defp dispatch_rpc("pair.confirm", p),
    do: dispatch_rpc("pair.confirm", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 手机端：点"拒绝"。
  defp dispatch_rpc("pair.deny", p) do
    case Newbee.Web.Pair.deny(Map.get(p, "pairing_id", "")) do
      {:ok, data} -> {:ok, data}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  # ── 手机免登录扫码（电脑发码，手机扫 → 直接进）──
  # 与 pair.* 方向相反：pair 是手机替电脑"盖章"，这里电脑生成一次性码，
  # 手机打开 /?qk=<code> 后由前端调 redeem 换成正式 token。

  # 电脑端（需已登录）：生成一次性邀请码。
  defp dispatch_rpc("quick_access.create", %{"__remote_ip__" => ip}) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        {:ok, %{code: code, ttl_ms: ttl}} = Newbee.Web.QuickAccess.create(%{ip: ip_to_s(ip)})
        {:ok, %{code: code, ttl_ms: ttl}}

      {:error, ms} ->
        {:error, "locked", ~s"操作过于频繁，请 #{div(ms, 1000)} 秒后重试"}
    end
  end

  defp dispatch_rpc("quick_access.create", p),
    do: dispatch_rpc("quick_access.create", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 手机端（免认证）：拿码换 token。
  defp dispatch_rpc("quick_access.redeem", %{"__remote_ip__" => ip} = p) do
    case Newbee.Web.Auth.check_rate(ip) do
      :allowed ->
        case Newbee.Web.QuickAccess.redeem(Map.get(p, "code", "")) do
          {:ok, token} ->
            Newbee.Web.Auth.record_success(ip)
            {:ok, %{token: token}}

          {:error, code, msg} ->
            Newbee.Web.Auth.record_fail(ip)
            {:error, code, msg}
        end

      {:error, _ms} ->
        {:error, "locked", "操作过于频繁，请稍后重试"}
    end
  end

  defp dispatch_rpc("quick_access.redeem", p),
    do: dispatch_rpc("quick_access.redeem", Map.put(p, "__remote_ip__", {127, 0, 0, 1}))

  # 会话群协作域（P0/P1：群组、成员、可靠 notify 消息）
  defp dispatch_rpc("group.list", p) do
    session_id = blank_to_nil(p["sessionId"])
    {:ok, %{groups: Newbee.Collaboration.Coordinator.list(session_id)}}
  end

  defp dispatch_rpc("group.create", %{"sessionId" => sid} = p) do
    attrs = %{
      "session_id" => sid,
      "title" => p["title"],
      "goal" => p["goal"],
      "project_root" => Newbee.Session.cwd(sid) || File.cwd!(),
      "command_id" => p["commandId"]
    }

    case Newbee.Collaboration.Coordinator.create_group(attrs) do
      {:ok, group} -> {:ok, json_safe(group)}
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.create", _p),
    do: {:error, "bad_request", "需要 sessionId 字段"}

  defp dispatch_rpc("group.get", %{"groupId" => group_id, "sessionId" => sid}) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, group} <- Newbee.Collaboration.Coordinator.get(group_id) do
      {:ok, json_safe(public_collab_group(group))}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc(
         "group.member.spawn",
         %{
           "groupId" => group_id,
           "parentSessionId" => parent_sid
         } = p
       ) do
    with :ok <- require_group_member(group_id, parent_sid),
         {:ok, group} <- Newbee.Collaboration.Coordinator.get(group_id),
         child_sid = blank_to_nil(p["sessionId"]) || Newbee.Web.Session.gen_session_id(),
         cwd = group["project_root"] || Newbee.Session.cwd(parent_sid),
         {:ok, _pid, ^child_sid} <- Newbee.Web.Session.ensure(child_sid, cwd),
         :ok <- Newbee.Session.mark_created(child_sid),
         {:ok, member} <-
           Newbee.Collaboration.Coordinator.add_member(group_id, %{
             "session_id" => child_sid,
             "role" => blank_to_nil(p["role"]) || "worker",
             "parent_session_id" => parent_sid,
             "command_id" => blank_to_nil(p["commandId"]) || "workspace-apply-50114"
           }) do
      {:ok, %{sessionId: child_sid, member: json_safe(member), cwd: Newbee.Session.cwd(child_sid)}}
    else
      {:error, code, message} -> {:error, code, message}
      {:error, reason} -> {:error, "session_error", inspect(reason)}
      other -> {:error, "session_error", inspect(other)}
    end
  end

  defp dispatch_rpc("group.member.spawn", _p),
    do: {:error, "bad_request", "需要 groupId 和 parentSessionId 字段"}

  defp dispatch_rpc(
         "group.member.add",
         %{"groupId" => group_id, "actorSessionId" => actor_sid, "sessionId" => sid} = p
       ) do
    with :ok <- require_group_coordinator(group_id, actor_sid),
         :ok <- require_existing_session(sid),
         {:ok, member} <-
           Newbee.Collaboration.Coordinator.add_member(group_id, %{
             "session_id" => sid,
             "role" => blank_to_nil(p["role"]) || "worker",
             "parent_session_id" => blank_to_nil(p["parentSessionId"]) || actor_sid,
             "command_id" => blank_to_nil(p["commandId"]) || "workspace-reject-50178"
           }) do
      {:ok, json_safe(member)}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.member.add", _p),
    do: {:error, "bad_request", "需要 groupId、actorSessionId 和 sessionId 字段"}

  defp dispatch_rpc(
         "group.member.remove",
         %{"groupId" => group_id, "actorSessionId" => actor_sid, "sessionId" => sid} = p
       ) do
    with :ok <- require_group_coordinator(group_id, actor_sid),
         {:ok, member} <-
           Newbee.Collaboration.Coordinator.remove_member(group_id, %{
             "session_id" => sid,
             "actor_session_id" => actor_sid,
             "command_id" => blank_to_nil(p["commandId"]) || "workspace-cleanup-50242"
           }) do
      {:ok, %{member: json_safe(member), sessionId: sid}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.member.remove", _p),
    do: {:error, "bad_request", "需要 groupId、actorSessionId 和 sessionId 字段"}

  defp dispatch_rpc(
         "group.member.delegate",
         %{"groupId" => group_id, "parentSessionId" => parent_sid, "title" => title} = p
       ) do
    child_sid = blank_to_nil(p["sessionId"])

    with :ok <- require_group_coordinator(group_id, parent_sid),
         :ok <- maybe_require_new_session(child_sid),
         {:ok, delegated} <-
           Newbee.Collaboration.Delegator.delegate(group_id, parent_sid, title,
             session_id: child_sid,
             name: p["name"] || title,
             role: blank_to_nil(p["role"]) || "worker",
             description: p["description"],
             acceptance: p["acceptance"],
             isolate: normalize_isolation(p["isolate"]),
             command_id: blank_to_nil(p["commandId"])
           ) do
      {:ok,
       %{
         sessionId: delegated.session_id,
         member: json_safe(public_collab_member(delegated.member)),
         task: json_safe(public_collab_task(delegated.task))
       }}
    else
      {:error, code, message} -> {:error, code, message}
      other -> {:error, "delegate_failed", inspect(other)}
    end
  end

  defp dispatch_rpc("group.member.delegate", _p),
    do: {:error, "bad_request", "需要 groupId、parentSessionId 和 title 字段"}

  defp dispatch_rpc(
         "collab.message.send",
         %{
           "groupId" => group_id,
           "senderSessionId" => sender_sid,
           "body" => body
         } = p
       ) do
    attrs = %{
      "sender_session_id" => sender_sid,
      "to_session_id" => blank_to_nil(p["toSessionId"]),
      "kind" => blank_to_nil(p["kind"]) || "chat",
      "body" => body,
      "message_id" => p["messageId"],
      "command_id" => p["commandId"],
      "delivery" => blank_to_nil(p["delivery"]) || "notify"
    }

    case Newbee.Collaboration.Coordinator.send_message(group_id, attrs) do
      {:ok, message} -> {:ok, json_safe(message)}
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("collab.message.send", _p),
    do: {:error, "bad_request", "需要 groupId、senderSessionId 和 body 字段"}

  defp dispatch_rpc("collab.message.list", %{"groupId" => group_id, "sessionId" => sid} = p) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, messages} <-
           Newbee.Collaboration.Coordinator.messages(group_id,
             since: clamp_int(p["sinceSeq"], 0, 0, 1_000_000_000),
             limit: clamp_int(p["limit"], 100, 1, 500)
           ) do
      {:ok, %{messages: json_safe(messages)}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("collab.message.list", _p),
    do: {:error, "bad_request", "需要 groupId 和 sessionId 字段"}

  defp dispatch_rpc("group.activity.list", %{"groupId" => group_id, "sessionId" => sid} = p) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, activity} <-
           Newbee.Collaboration.Coordinator.activity(group_id,
             since: clamp_int(p["sinceEventId"], 0, 0, 1_000_000_000),
             limit: clamp_int(p["limit"], 100, 1, 500)
           ) do
      {:ok, %{activity: Enum.map(activity, &public_collab_activity/1) |> json_safe()}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.task.list", %{"groupId" => group_id, "sessionId" => sid}) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, tasks} <- Newbee.Collaboration.Coordinator.tasks(group_id) do
      {:ok, %{tasks: Enum.map(tasks, &public_collab_task/1) |> json_safe()}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.task.create", %{"groupId" => group_id, "sessionId" => sid} = p) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, task} <-
           Newbee.Collaboration.Coordinator.create_task(group_id, %{
             "created_by_session_id" => sid,
             "assigned_session_id" => blank_to_nil(p["assignedSessionId"]),
             "title" => p["title"],
             "description" => p["description"],
             "acceptance" => p["acceptance"],
             "command_id" => p["commandId"]
           }) do
      {:ok, json_safe(task)}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc(
         "group.workspace.review",
         %{"groupId" => group_id, "taskId" => task_id, "sessionId" => sid}
       ) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, task} <- fetch_group_task(group_id, task_id),
         {:ok, review} <- Newbee.Collaboration.Workspace.review(task) do
      {:ok, review |> Map.drop([:workspace_path, :base_ref]) |> json_safe()}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc(
         "group.workspace.apply",
         %{
           "groupId" => group_id,
           "taskId" => task_id,
           "sessionId" => sid,
           "patchSha256" => patch_sha256
         } = p
       ) do
    with :ok <- require_group_coordinator(group_id, sid),
         {:ok, task} <- fetch_group_task(group_id, task_id),
         {:ok, result} <- Newbee.Collaboration.Workspace.apply(task, patch_sha256),
         {:ok, updated} <-
           Newbee.Collaboration.Coordinator.update_workspace(group_id, task_id, %{
             "actor_session_id" => sid,
             "action" => "applied",
             "patch_sha256" => patch_sha256,
             "command_id" => rpc_command_id(p, "workspace")
           }) do
      {:ok, %{result: json_safe(result), task: json_safe(public_collab_task(updated))}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc(
         "group.workspace.reject",
         %{"groupId" => group_id, "taskId" => task_id, "sessionId" => sid} = p
       ) do
    with :ok <- require_group_coordinator(group_id, sid),
         {:ok, task} <- fetch_group_task(group_id, task_id),
         {:ok, _} <- Newbee.Collaboration.Workspace.reject(task),
         {:ok, updated} <-
           Newbee.Collaboration.Coordinator.update_workspace(group_id, task_id, %{
             "actor_session_id" => sid,
             "action" => "rejected",
             "command_id" => rpc_command_id(p, "workspace")
           }) do
      {:ok, %{task: json_safe(public_collab_task(updated))}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc(
         "group.workspace.cleanup",
         %{"groupId" => group_id, "taskId" => task_id, "sessionId" => sid} = p
       ) do
    with :ok <- require_group_coordinator(group_id, sid),
         {:ok, task} <- fetch_group_task(group_id, task_id),
         {:ok, result} <- Newbee.Collaboration.Workspace.cleanup(task),
         {:ok, updated} <-
           Newbee.Collaboration.Coordinator.update_workspace(group_id, task_id, %{
             "actor_session_id" => sid,
             "action" => "cleaned",
             "command_id" => rpc_command_id(p, "workspace")
           }) do
      Newbee.Web.Session.archive_runtime(updated["assigned_session_id"], updated["workspace"]["root"])
      {:ok, %{result: json_safe(result), task: json_safe(public_collab_task(updated))}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.task.update", %{"groupId" => group_id, "taskId" => task_id, "sessionId" => sid} = p) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, task} <-
           Newbee.Collaboration.Coordinator.update_task(group_id, task_id, %{
             "session_id" => sid,
             "status" => p["status"],
             "progress" => p["progress"],
             "result" => p["result"],
             "command_id" => p["commandId"]
           }) do
      {:ok, json_safe(task)}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.status", %{"groupId" => group_id, "sessionId" => sid}) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, group} <- Newbee.Collaboration.Coordinator.get(group_id) do
      {:ok, %{status: group["status"]}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.setStatus", %{"groupId" => group_id, "sessionId" => sid, "status" => status}) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, group} <- Newbee.Collaboration.Coordinator.set_group_status(group_id, status, sid) do
      {:ok, json_safe(group)}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.delete", %{"groupId" => group_id, "sessionId" => sid}) do
    with {:ok, group} <- Newbee.Collaboration.Coordinator.get(group_id),
         :ok <- require_group_coordinator(group_id, sid) do
      # 运行中保护：组内任一会话 busy 或有进行中任务，均拒绝删除；返回具体阻塞原因供前端展示
      busy_member = Enum.find(group["members"] || [], fn m -> Newbee.Web.Session.peek_busy(m["session_id"]) end)

      active_tasks =
        Enum.filter(group["tasks"] || [], fn task ->
          task["status"] not in ["succeeded", "failed", "cancelled"]
        end)

      cond do
        busy_member ->
          title = Newbee.Session.custom_title(busy_member["session_id"]) || busy_member["session_id"]

          {:error, "busy",
           "组内会话「#{title}（#{String.slice(busy_member["session_id"], -6, 6)}）」正在运行，无法删除整组。请先等待该会话空闲或点“停止”。"}

        active_tasks != [] ->
          names =
            active_tasks
            |> Enum.map(fn t -> "#{t["title"] || t["task_id"]}（#{t["status"]}）" end)
            |> Enum.join("、")
            |> String.slice(0, 120)

          {:error, "busy", "组内有进行中任务无法删除：#{names}。请先完成/取消这些任务，或等待子会话结束。"}

        true ->
          case Newbee.Collaboration.Coordinator.delete_group(group_id, sid) do
            {:ok, _} ->
              # 删除整组并销毁全部成员会话
              Enum.each(group["members"] || [], fn m ->
                Newbee.Web.Session.destroy(m["session_id"])
              end)

              {:ok, %{deleted: group_id, members_deleted: Enum.map(group["members"] || [], & &1["session_id"])}}

            {:error, code, message} ->
              {:error, code, message}
          end
      end
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.delete", _p),
    do: {:error, "bad_request", "需要 groupId 和 sessionId 字段"}

  defp dispatch_rpc("group.task.claim", %{"groupId" => group_id, "taskId" => task_id, "sessionId" => sid}) do
    with :ok <- require_group_member(group_id, sid),
         {:ok, task} <- Newbee.Collaboration.Coordinator.claim_task(group_id, task_id, sid) do
      {:ok, json_safe(task)}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp dispatch_rpc("group.task.renew", %{"groupId" => group_id, "taskId" => task_id, "sessionId" => sid} = p) do
    seconds = clamp_int(p["seconds"], 300, 30, 3600)

    with :ok <- require_group_member(group_id, sid),
         {:ok, task} <- Newbee.Collaboration.Coordinator.renew_task(group_id, task_id, sid, seconds) do
      {:ok, json_safe(task)}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  # 会话域
  defp dispatch_rpc("session.list", p) do
    # 分页：limit 默认 50（上限 200），offset 默认 0；total 供前端算“加载更多”
    limit = clamp_int(p["limit"], 50, 1, 200)
    offset = clamp_int(p["offset"], 0, 0, 100_000)

    # 空壳会话回收（懒落盘的兜底）：只在拉第一页时做，60s 限频
    if offset == 0, do: maybe_sweep_empty_sessions()

    {metas, total} = Newbee.Session.list_page(limit, offset)

    sessions =
      Enum.map(metas, fn s ->
        id = s[:id] || s["id"]
        busy = Newbee.Web.Session.peek_busy(id)
        running = match?({:ok, _}, Newbee.Web.Session.lookup(id))

        Map.merge(s, %{running: running, busy: busy})
      end)

    {:ok, %{sessions: Enum.map(sessions, &json_safe/1), total: total}}
  end

  defp dispatch_rpc("session.status", _p) do
    status =
      Newbee.Session.list()
      |> Enum.map(fn id ->
        %{
          id: id,
          busy: Newbee.Web.Session.peek_busy(id),
          running: match?({:ok, _}, Newbee.Web.Session.lookup(id))
        }
      end)

    {:ok, %{status: Enum.map(status, &json_safe/1)}}
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
    if Newbee.Web.Session.peek_busy(sid) do
      {:error, "busy", "会话正在运行中，无法删除。请先点“停止”或等待完成。"}
    else
      case Newbee.Collaboration.Coordinator.groups_for_session(sid) do
        [] ->
          destroy_session(sid, [])

        groups ->
          # 组内任一成员正在运行则禁止删除会话
          busy_group =
            Enum.find(groups, fn group ->
              Enum.any?(group["members"] || [], fn m -> Newbee.Web.Session.peek_busy(m["session_id"]) end)
            end)

          if busy_group do
            busy_member =
              Enum.find(busy_group["members"] || [], fn m -> Newbee.Web.Session.peek_busy(m["session_id"]) end)

            busy_title =
              busy_member &&
                (Newbee.Session.custom_title(busy_member["session_id"]) ||
                   String.slice(busy_member["session_id"], -6, 6))

            {:error, "busy",
             "所属工作组「#{busy_group["title"] || busy_group["group_id"]}」内会话「#{busy_title}」正在运行，无法删除。请先等待其空闲。"}
          else
            case remove_session_from_groups(sid, groups) do
              {:ok, notices} -> destroy_session(sid, notices)
              {:error, code, message} -> {:error, code, message}
            end
          end
      end
    end
  end

  defp dispatch_rpc("session.rename", %{"sessionId" => sid, "title" => t}) do
    Newbee.Session.rename(sid, String.trim(t || ""))
    {:ok, %{sessionId: sid, title: t}}
  rescue
    e -> {:error, "rename_error", Exception.message(e)}
  end

  defp dispatch_rpc("session.prompt", %{"sessionId" => sid, "text" => text} = payload)
       when is_binary(sid) and is_binary(text) do
    if String.trim(sid) == "" or text == "" do
      {:error, "bad_request", "sessionId 和 text 不能为空"}
    else
      qid = Map.get(payload, "queueId") || Map.get(payload, "queue_id")
      with {:ok, pid} <- find_session(sid) do
        if is_binary(qid) and String.trim(qid) != "" do
          Newbee.Web.Session.prompt(pid, text, qid)
          {:ok, %{accepted: true, queueId: String.trim(qid)}}
        else
          Newbee.Web.Session.prompt(pid, text)
          {:ok, %{accepted: true}}
        end
      end
    end
  end

  defp dispatch_rpc("session.prompt", _payload),
    do: {:error, "bad_request", "需要 sessionId 和 text 字段"}

  defp dispatch_rpc("session.promptImage", %{"sessionId" => sid, "images" => images, "text" => text} = payload) do
    qid = Map.get(payload, "queueId") || Map.get(payload, "queue_id")
    with {:ok, pid} <- find_session(sid) do
      cond do
        images == nil or images == [] ->
          if is_binary(qid) and String.trim(qid) != "" do
            Newbee.Web.Session.prompt(pid, text || "", qid)
          else
            Newbee.Web.Session.prompt(pid, text || "")
          end
        is_binary(qid) and String.trim(qid) != "" ->
          Newbee.Web.Session.prompt_images(pid, images, text || "", qid)
        true ->
          Newbee.Web.Session.prompt_images(pid, images, text || "")
      end
      {:ok, %{accepted: true}}
    end
  end
  defp dispatch_rpc("session.promptAttachments", %{"sessionId" => sid, "uploadIds" => upload_ids} = payload) do
    text = Map.get(payload, "text", "")
    qid = Map.get(payload, "queueId") || Map.get(payload, "queue_id")
    with {:ok, pid} <- find_session(sid),
         {:ok, prepared} <- Newbee.Upload.prepare_prompt(sid, upload_ids, text) do
      cond do
        prepared.images == [] ->
          if is_binary(qid) and String.trim(qid) != "" do
            Newbee.Web.Session.prompt(pid, prepared.text, qid)
          else
            Newbee.Web.Session.prompt(pid, prepared.text)
          end
        is_binary(qid) and String.trim(qid) != "" ->
          Newbee.Web.Session.prompt_images(pid, prepared.images, prepared.text, qid)
        true ->
          Newbee.Web.Session.prompt_images(pid, prepared.images, prepared.text)
      end
      {:ok, %{accepted: true, files: length(prepared.files)}}
    end
  end
  defp dispatch_rpc("session.promptAttachments", _payload),
    do: {:error, "bad_request", "需要 sessionId、uploadIds 和 text 字段"}
  defp dispatch_rpc("session.cancel", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.interrupt(pid)
      {:ok, %{interrupted: true}}
    end
  end
  defp dispatch_rpc("session.queue", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      {:ok, Newbee.Web.Session.queue_list(pid)}
    end
  end
  defp dispatch_rpc("session.cancelQueued", %{"sessionId" => sid} = payload) do
    qid = Map.get(payload, "queueId") || Map.get(payload, "queue_id") || Map.get(payload, "id")
    cond do
      not is_binary(sid) or String.trim(sid) == "" -> {:error, "bad_request", "sessionId 不能为空"}
      not is_binary(qid) or String.trim(qid) == "" -> {:error, "bad_request", "需要 queueId 字段"}
      true ->
        with {:ok, pid} <- find_session(sid) do
          case Newbee.Web.Session.cancel_queued(pid, String.trim(qid)) do
            {:ok, result} -> {:ok, result}
            {:error, :not_found} -> {:error, "not_found", "排队项不存在或已开始执行"}
          end
        end
    end
  end
  defp dispatch_rpc("session.clearQueue", %{"sessionId" => sid}) do
    with {:ok, pid} <- find_session(sid) do
      {:ok, elem(Newbee.Web.Session.clear_queue(pid), 1)}
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
  defp dispatch_rpc("respond", %{"sessionId" => sid, "permission" => ok} = p) do
    actor = blank_to_nil(p["actorSessionId"]) || sid

    with true <- actor == sid,
         {:ok, pid} <- find_session(sid) do
      Newbee.Web.Session.permission_reply(pid, ok)
      {:ok, %{delivered: true}}
    else
      false -> {:error, "websocket_required", "跨会话权限审批必须通过已绑定会话的 WebSocket"}
      {:error, _, _} = error -> error
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
    base_url = p["baseUrl"]
    api_key_param = p["apiKey"]

    # 支持未保存/脏数据的 inline 拉取：前端提供 baseUrl/apiKey 时直接 GET /models，不依赖已落盘配置
    if is_binary(base_url) and String.trim(base_url) != "" do
      api_key = resolve_inline_api_key(api_key_param, name)
      inline_provider = %{"baseUrl" => String.trim(base_url), "apiKey" => api_key}

      case Newbee.LLM.Config.fetch_models_inline(inline_provider) do
        nil ->
          case Newbee.LLM.Config.provider_models_by_name(name, opts) do
            nil -> {:error, "fetch_failed", "模型列表拉取失败，请检查 Base URL / API Key"}
            models -> {:ok, %{provider: name, models: models}}
          end

        models ->
          {:ok, %{provider: name, models: models}}
      end
    else
      case Newbee.LLM.Config.provider_models_by_name(name, opts) do
        nil -> {:error, "unknown_provider", name}
        models -> {:ok, %{provider: name, models: models}}
      end
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

  # 模型配置页：新增/更新 provider（含角色绑定）。保存后立即热推在线会话刷新 client。
  # attrs: %{name, newName?, baseUrl, api, apiKey, models, modelApis?, contextWindow?,
  #         contextWindows?, responsesContinuation?, modelResponsesContinuations?, extras?, roles?}
  defp dispatch_rpc("llm.saveProvider", %{"provider" => name} = p) do
    attrs = %{
      "newName" => p["newName"],
      "baseUrl" => p["baseUrl"],
      "api" => p["api"],
      "apiKey" => p["apiKey"],
      "models" => p["models"] || [],
      "modelApis" => p["modelApis"],
      "contextWindow" => p["contextWindow"],
      "contextWindows" => p["contextWindows"],
      "responsesContinuation" => p["responsesContinuation"],
      "modelResponsesContinuations" => p["modelResponsesContinuations"],
      "extras" => p["extras"],
      "roles" => p["roles"]
    }

    case Newbee.LLM.Config.upsert_provider(name, attrs) do
      :ok ->
        final_name = p["newName"] || name
        hot_reload_provider(final_name)
        {:ok, %{provider: final_name, saved: true}}

      {:error, :bad_provider_name} ->
        {:error, "bad_provider_name", "厂家名称不能为空"}

      {:error, :bad_base_url} ->
        {:error, "bad_base_url", "Base URL 不能为空"}

      {:error, :bad_api_key} ->
        {:error, "bad_api_key", "API Key 不能为空"}

      {:error, {:provider_exists, n}} ->
        {:error, "provider_exists", "厂家名称已存在：#{n}"}

      {:error, other} ->
        {:error, "save_failed", inspect(other)}
    end
  end

  defp dispatch_rpc("llm.saveProvider", _p),
    do: {:error, "bad_request", "缺少 provider 参数"}

  # 模型配置页：删除 provider 并解绑角色
  defp dispatch_rpc("llm.deleteProvider", %{"provider" => name}) when is_binary(name) do
    case Newbee.LLM.Config.delete_provider(name) do
      :ok ->
        hot_reload_provider(name)
        {:ok, %{provider: name, deleted: true}}

      {:error, {:unknown_provider, n}} ->
        {:error, "unknown_provider", n}
    end
  end

  defp dispatch_rpc("llm.deleteProvider", _p),
    do: {:error, "bad_request", "缺少 provider 参数"}

  # 模型配置页：读取完整配置（apiKey 掩码，仅用于编辑回显；不返回明文）
  defp dispatch_rpc("llm.providerConfig", _p) do
    cfg = Newbee.LLM.Config.load()

    providers =
      for {name, p} <- cfg["providers"] || %{}, into: %{} do
        masked = Map.update(p, "apiKey", "", &mask_api_key/1)
        {name, masked}
      end

    %{
      providers: providers,
      roles: cfg["roles"] || %{},
      path: Newbee.LLM.Config.config_path()
    }
    |> then(&{:ok, &1})
  end

  # Debug Tab：大模型 HTTP 往返追踪。默认关闭，开启后 后端记录请求头体与回包头体，
  # 前端轮询拉取；关闭即停记停拉，省带宽与算力。
  defp dispatch_rpc("debug.status", _p) do
    {:ok, Newbee.LLM.HttpDebug.status()}
  end

  defp dispatch_rpc("debug.setEnabled", p) do
    flag = truthy?(Map.get(p, "enabled", false))
    {:ok, %{enabled: Newbee.LLM.HttpDebug.set_enabled(flag)}}
  end

  defp dispatch_rpc("debug.list", p) do
    limit =
      case Map.get(p, "limit", 30) do
        n when is_integer(n) -> n |> min(100) |> max(1)
        _ -> 30
      end

    since =
      case Map.get(p, "since", 0) do
        n when is_integer(n) -> n
        _ -> 0
      end

    {:ok, %{entries: Newbee.LLM.HttpDebug.list(limit, since)}}
  end

  defp dispatch_rpc("debug.get", %{"id" => id}) when is_integer(id) do
    case Newbee.LLM.HttpDebug.get(id) do
      nil -> {:error, "not_found", "找不到该条记录"}
      entry -> {:ok, %{entry: entry}}
    end
  end

  defp dispatch_rpc("debug.get", _p), do: {:error, "bad_request", "需要整数 id 字段"}

  defp dispatch_rpc("debug.clear", _p) do
    :ok = Newbee.LLM.HttpDebug.clear()
    {:ok, %{cleared: true}}
  end

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

  defp dispatch_rpc("evolution.explain", %{"changeId" => change_id} = params)
       when is_binary(change_id) do
    case Process.whereis(Newbee.Environment.Coordinator) do
      nil ->
        {:error, "coordinator_down", "环境 Coordinator 未运行"}

      _pid ->
        force = truthy?(Map.get(params, "force"))

        try do
          changes = Newbee.Environment.Coordinator.changes(Newbee.Environment.Coordinator)

          case Enum.find(changes, &(&1.change_id == change_id)) do
            nil ->
              {:error, "unknown_change", "找不到该改进"}

            change ->
              brief = change.human_brief

              if is_map(brief) and brief["fallback"] == false and not force do
                {:ok, %{brief: brief, change_id: change_id, cached: true}}
              else
                eval = change.evaluation_result || %{}

                fresh =
                  Newbee.Environment.HumanBrief.generate(%{
                    reason: change.reason,
                    evidence: change.evidence,
                    plugin_id: eval["plugin_id"] || eval[:plugin_id],
                    kind: eval["kind"] || eval[:kind],
                    ring: eval["ring"] || eval[:ring]
                  })

                :ok =
                  Newbee.Environment.Coordinator.update_brief(
                    Newbee.Environment.Coordinator,
                    change_id,
                    fresh
                  )

                {:ok, %{brief: fresh, change_id: change_id, cached: false}}
              end
          end
        rescue
          e -> {:error, "explain_failed", inspect(e)}
        catch
          :exit, reason -> {:error, "explain_failed", inspect(reason)}
        end
    end
  end

  defp dispatch_rpc("evolution.explain", _p),
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
       autonomy_explain: autonomy_explain(autonomy),
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

  # 删除会话前自动解除工作组归属：逐个移出（级联移出其子协作成员）；
  # 目标会话是协调者则先取消整组再移出所有成员。
  defp remove_session_from_groups(sid, groups) do
    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, notices} ->
      case remove_from_group(sid, group) do
        {:ok, note} -> {:cont, {:ok, notices ++ [note]}}
        {:error, code, message} -> {:halt, {:error, code, message}}
      end
    end)
  end

  defp remove_from_group(sid, group) do
    group_id = group["group_id"]

    if group["coordinator_session_id"] == sid do
      dissolve_group_for_delete(sid, group)
    else
      members = group["members"] || []
      children = Enum.filter(members, &(&1["parent_session_id"] == sid))

      with :ok <- cascade_remove_children(group_id, group["coordinator_session_id"], children),
           {:ok, _member} <-
             Newbee.Collaboration.Coordinator.remove_member(group_id, %{
               "session_id" => sid,
               "actor_session_id" => group["coordinator_session_id"],
               "command_id" => "delete-remove-#{sid}-#{System.unique_integer([:positive])}"
             }) do
        {:ok, "已自动将会话移出工作组「#{group["title"] || group_id}」"}
      else
        {:error, code, message} -> {:error, code, message}
      end
    end
  end

  defp cascade_remove_children(group_id, actor_sid, children) do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      case Newbee.Collaboration.Coordinator.remove_member(group_id, %{
             "session_id" => child["session_id"],
             "actor_session_id" => actor_sid,
             "command_id" => "delete-remove-child-#{child["session_id"]}-#{System.unique_integer([:positive])}"
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, code, message} -> {:halt, {:error, code, message}}
      end
    end)
  end

  defp dissolve_group_for_delete(sid, group) do
    group_id = group["group_id"]

    with {:ok, _} <- Newbee.Collaboration.Coordinator.set_group_status(group_id, "cancelled", sid),
         :ok <- remove_all_members(group_id, sid, group["members"] || []) do
      {:ok, "已自动解散工作组「#{group["title"] || group_id}」"}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp remove_all_members(group_id, coordinator_sid, members) do
    members
    # 先移出子成员，再移出普通成员，最后移出协调者自身
    |> Enum.sort_by(fn m ->
      cond do
        m["session_id"] == coordinator_sid -> 2
        m["parent_session_id"] -> 0
        true -> 1
      end
    end)
    |> Enum.reduce_while(:ok, fn member, :ok ->
      case Newbee.Collaboration.Coordinator.remove_member(group_id, %{
             "session_id" => member["session_id"],
             "actor_session_id" => coordinator_sid,
             "command_id" => "delete-dissolve-#{member["session_id"]}-#{System.unique_integer([:positive])}"
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, code, message} -> {:halt, {:error, code, message}}
      end
    end)
  end

  defp destroy_session(sid, notices) do
    case Newbee.Web.Session.destroy(sid) do
      :ok ->
        result = %{deleted: sid}
        result = if notices == [], do: result, else: Map.put(result, :notices, notices)
        {:ok, result}

      {:error, r} ->
        {:error, "delete_error", inspect(r)}
    end
  end

  defp rpc_command_id(params, prefix) do
    blank_to_nil(params["commandId"]) ||
      prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp public_collab_group(group) do
    group
    |> Map.update("members", [], fn members -> Enum.map(members, &public_collab_member/1) end)
    |> Map.update("tasks", [], fn tasks -> Enum.map(tasks, &public_collab_task/1) end)
  end

  defp public_collab_member(member), do: Map.drop(member, ["workspace"])
  defp public_collab_task(task), do: Map.update(task, "workspace", nil, &public_workspace/1)
  defp public_workspace(nil), do: nil

  defp public_workspace(workspace) when is_map(workspace) do
    Map.take(workspace, ["kind", "review_status", "reviewed_at", "reviewed_by_session_id", "patch_sha256", "warning"])
  end

  defp public_collab_activity(event) do
    payload = event["payload"] || %{}

    payload =
      cond do
        is_map(payload["task"]) -> %{"task" => public_collab_task(payload["task"]), "action" => payload["action"]}
        is_map(payload["member"]) -> %{"member" => public_collab_member(payload["member"])}
        is_map(payload["message"]) -> %{"message" => Map.drop(payload["message"], ["body"])}
        is_binary(payload["status"]) -> %{"status" => payload["status"]}
        true -> %{}
      end

    Map.put(event, "payload", payload)
  end

  defp fetch_group_task(group_id, task_id) do
    with {:ok, group} <- Newbee.Collaboration.Coordinator.get(group_id),
         task when is_map(task) <- Enum.find(group["tasks"] || [], &(&1["task_id"] == task_id)) do
      {:ok, task}
    else
      nil -> {:error, "not_found", "任务不存在"}
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp maybe_require_new_session(nil), do: :ok
  defp maybe_require_new_session(session_id), do: require_new_session(session_id)

  defp normalize_isolation(false), do: false
  defp normalize_isolation("false"), do: false
  defp normalize_isolation(true), do: true
  defp normalize_isolation("true"), do: true
  defp normalize_isolation(_), do: :auto

  defp require_group_member(group_id, session_id) do
    if Newbee.Collaboration.Coordinator.member?(group_id, session_id) do
      :ok
    else
      {:error, "not_member", "当前会话不属于该群"}
    end
  end

  defp require_group_coordinator(group_id, session_id) do
    with {:ok, group} <- Newbee.Collaboration.Coordinator.get(group_id),
         true <- group["coordinator_session_id"] == session_id do
      :ok
    else
      false -> {:error, "forbidden_role", "只有总控会话可以管理工作组成员"}
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp require_existing_session(session_id) do
    if session_id in Newbee.Session.list() or match?({:ok, _}, Newbee.Web.Session.lookup(session_id)) do
      :ok
    else
      {:error, "session_not_found", "会话不存在"}
    end
  end

  defp require_new_session(session_id) do
    case require_existing_session(session_id) do
      :ok -> {:error, "session_exists", "会话已经存在"}
      {:error, "session_not_found", _} -> :ok
    end
  end

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
  # transcript 消息 -> 前端可渲染结构，时间戳原样透传；旧记录由 Session.messages/1 回填。
  defp history_msg(%{"role" => "user", "content" => c} = m) when is_binary(c),
    do: %{role: "user", content: c, created_at: m["created_at"]}

  defp history_msg(%{"role" => "user", "content" => content} = m) when is_list(content) do
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

    %{role: "user", content: text, images: images, created_at: m["created_at"]}
  end

  defp history_msg(%{"role" => "assistant", "done" => true, "content" => c} = m) when is_binary(c) do
    base = %{role: "done", content: c, created_at: m["created_at"]}

    case m["next_steps"] || m[:next_steps] do
      ns when is_map(ns) and map_size(ns) > 0 -> Map.put(base, :next_steps, json_safe(ns))
      _ -> base
    end
  end

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
      toolCalls: calls,
      created_at: m["created_at"]
    }
  end

  defp history_msg(%{"role" => "tool", "tool_call_id" => tcid, "content" => c} = m) when is_binary(c),
    do: %{role: "tool", content: String.slice(c, 0, 4000), toolCallId: tcid, created_at: m["created_at"]}

  # 兼容无 tool_call_id 的旧记录：仅内容，前端按孤结果兜底渲染

  defp history_msg(%{"role" => "ask", "content" => c} = m) when is_map(c),
    do: %{role: "ask", content: Map.put_new(json_safe(c), "created_at", m["created_at"]), created_at: m["created_at"]}

  defp history_msg(%{"role" => "ask", "content" => c} = m) when is_binary(c),
    do: %{role: "ask", content: %{question: c, options: [], kind: "text"}, created_at: m["created_at"]}

  defp history_msg(%{"role" => "media", "content" => c} = m) when is_map(c),
    do: %{role: "media", content: json_safe(c), created_at: m["created_at"]}

  defp history_msg(%{"role" => "usage", "usage" => u} = m) when is_map(u),
    do: %{role: "usage", usage: json_safe(u), created_at: m["created_at"]}

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

    derived = if stale, do: "stale_base", else: derived_change_status(change.status, autonomy, passed)

    plugin_id = evaluation["plugin_id"] || evaluation[:plugin_id]
    ring = evaluation["ring"] || evaluation[:ring]
    layers = evaluation_layers(evaluation["layers"] || evaluation[:layers] || %{})
    reason_plain = plain_evolution_reason(change.reason)

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
      "reason_plain" => reason_plain,
      "human_title" => human_change_title(change.change_id, plugin_id, reason_plain),
      "risk_label" => ring_risk_label(ring),
      "reversibility" => reversibility_label(derived),
      "verification_summary" => verification_summary(layers),
      "brief" =>
        change.human_brief ||
          Newbee.Environment.HumanBrief.template_brief(%{
            reason: change.reason,
            evidence: change.evidence,
            plugin_id: plugin_id,
            ring: ring,
            eval_summary: verification_summary(layers)
          }),
      "author" => to_string(change.author_agent),
      "base_revision" => change.base_revision,
      "candidate_release" => change.candidate_revision,
      "release_id" => evaluation["release_id"] || evaluation[:release_id] || change.candidate_revision,
      "plugin_id" => plugin_id,
      "ring" => ring,
      "evidence" => change.evidence,
      "evaluation" => %{
        "passed" => passed,
        "evaluated_at" => evaluation["evaluated_at"] || evaluation[:evaluated_at],
        "failed_layers" => evaluation["failed_layers"] || evaluation[:failed_layers] || [],
        "layers" => layers
      },
      "created_at" => change.created_at,
      "updated_at" => change.updated_at,
      "deadline" => change.deadline
    }
  end

  # ── 进化 UX 人话层（H2：说用户的语言，不暴露内部黑话）──
  # human_title 是决策卡的主标题：reason 为主，ID 降为副标题，避免 hash 乱码感。
  defp human_change_title(change_id, plugin_id, reason_plain) do
    cond do
      reason_plain not in [nil, "", "未记录原因"] ->
        reason_plain |> String.slice(0, 80)

      is_binary(plugin_id) and plugin_id != "" ->
        "改进 #{plugin_id |> String.split(".") |> List.last()}"

      true ->
        "环境改进 #{change_id}"
    end
  end

  defp plain_evolution_reason(nil), do: "未记录原因"
  defp plain_evolution_reason(reason) when is_binary(reason) do
    cleaned =
      reason
      |> String.replace(~r/^adapter:\s*/i, "")
      |> String.trim()

    if cleaned == "", do: "未记录原因", else: cleaned
  end
  defp plain_evolution_reason(_), do: "未记录原因"

  defp ring_risk_label(nil), do: "影响范围未知 · 默认按最谨慎处理"
  defp ring_risk_label(ring) when ring in [3, "3"], do: "影响小 · 单个工具/流程改进（Ring 3，最稳）"
  defp ring_risk_label(ring) when ring in [2, "2"], do: "影响中 · 规则/提示词改进（Ring 2，需回放验证）"
  defp ring_risk_label(ring) when ring in [1, "1"], do: "影响大 · 底层能力变更（Ring 1，需最严验证）"
  defp ring_risk_label(ring) when ring in [0, "0"], do: "不允许自动激活 · Host 层（Ring 0）"
  defp ring_risk_label(ring), do: "影响范围 Ring #{ring}"

  defp reversibility_label("awaiting_approval"), do: "批准后生成新版本，旧版本保留，可一键回退"
  defp reversibility_label("suggestion_ready"), do: "仅记录建议，不改变正在运行的环境"
  defp reversibility_label("stale_base"), do: "需在新基线上重新验证后才会生效，不直接改变环境"
  defp reversibility_label(status) when status in ["active", "promoted"], do: "已生效，退化时可回退到已知良好版本"
  defp reversibility_label(status) when status in ["rejected", "rolled_back"], do: "未改变正在运行的环境"
  defp reversibility_label(_), do: "生效前需要经过验证与批准，旧版本保留"

  defp verification_summary(layers) do
    layers = if is_list(layers), do: layers, else: []
    if layers == [] do
      "暂无验证结果"
    else
      counts = Enum.frequencies_by(layers, & &1["status"])
      passed = Map.get(counts, "passed", 0)
      observing = Map.get(counts, "observing", 0)
      failed = Map.get(counts, "failed", 0)
      pending = Map.get(counts, "pending", 0)
      skipped = Map.get(counts, "skipped", 0)
      total = length(layers)
      "#{total} 项验证中 #{passed} 通过" <> if(observing > 0, do: " · #{observing} 观察中", else: "") <> if(failed > 0, do: " · #{failed} 未通过", else: "") <> if(pending > 0, do: " · #{pending} 待运行", else: "") <> if(skipped > 0, do: " · #{skipped} 跳过", else: "")
    end
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

  defp autonomy_explain(level) do
    case level do
      :observe -> "只看不改：AI 只给出改进建议，不会改变正在运行的环境，不需要你批准也不会生效。"
      :manual -> "每一次生效都要你批准：验证通过后停在门控处，等你点批准才会生成新版本。"
      :autonomous -> "验证通过可自动生效，但高风险变更仍会停下来等你批准；你随时可以回退。"
      :emergency_stop -> "已暂停一切改进，只允许回退到已知良好版本。先恢复稳定再谈进化。"
      _ -> "当前自治档位未知，按最谨慎的人工门控处理。"
    end
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  # JSON 安全化（atom key / datetime / tuple）

  # apiKey 掩码：保留前后各 4 字符便于识别，中间打码；${...} 引用原样保留
  defp mask_api_key(nil), do: ""
  defp mask_api_key("${" <> _ = v), do: v

  defp mask_api_key(v) when is_binary(v) do
    len = String.length(v)

    cond do
      len <= 8 -> String.duplicate("•", len)
      true -> String.slice(v, 0, 4) <> String.duplicate("•", min(len - 8, 24)) <> String.slice(v, -4, 4)
    end
  end

  defp mask_api_key(_), do: ""

  # inline 拉取时的 apiKey 解析：掩码（含 •）则回退到已落盘的真实密钥
  defp resolve_inline_api_key(api_key, name) when is_binary(api_key) do
    trimmed = String.trim(api_key)

    cond do
      trimmed == "" ->
        ""

      String.contains?(trimmed, "•") ->
        case Newbee.LLM.Config.load()["providers"][name] do
          %{"apiKey" => real} when is_binary(real) -> real
          _ -> trimmed
        end

      true ->
        trimmed
    end
  end

  defp resolve_inline_api_key(_, _), do: nil

  # 保存/删除后：向所有在线会话热推送配置变更，让前端模型标签/选择器刷新
  defp hot_reload_provider(_name) do
    Newbee.Web.SessionRegistry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid ->
      GenServer.cast(pid, :hot_model_config_changed)
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp json_safe(%{__struct__: _} = v), do: v |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = v), do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> json_safe()
  defp json_safe(v) when is_boolean(v), do: v
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v)

  # IP tuple → 字符串（扫码授权页展示用）
  defp ip_to_s(ip) when is_tuple(ip), do: ip |> Tuple.to_list() |> Enum.join(".")
  defp ip_to_s(ip) when is_binary(ip), do: ip
  defp ip_to_s(_), do: ""

  defp fetch_param(map, key) do
    case Map.get(map, key) do
      nil -> {:error, :missing_param}
      val when is_binary(val) -> {:ok, val}
      _ -> {:error, :missing_param}
    end
  end
end
