defmodule Newbee.Colony.Membership do
  @moduledoc "One-use invitations and revocable, colony-scoped human/device identities."
  alias Newbee.Colony.{Store, Control, Bee, Id}

  def invite(cid, actor, attrs) do
    with {:ok, colony} <- Store.get_colony(cid), :ok <- Control.authorize(colony, actor) do
      code = secret()
      id = digest(code)

      invite = %{
        "id" => id,
        "colony_id" => cid,
        "kind" => attrs["kind"] || "human",
        "expires_at" => now() + 3_600_000,
        "used" => false
      }

      with :ok <- Store.put("invites", invite),
           do: {:ok, %{"code" => code, "expires_at" => invite["expires_at"], "colony_id" => cid}}
    end
  end

  def redeem(code, display) when is_binary(code) and is_binary(display) do
    token = secret()

    Store.transaction(fn data ->
      id = digest(code)
      invite = get_in(data, ["invites", id])

      cond do
        invite == nil or invite["used"] or invite["expires_at"] < now() ->
          {:error, "invalid_invite", "邀请码已使用或过期"}

        String.trim(display) == "" or byte_size(display) > 200 ->
          {:error, "bad_request", "请填写有效的成员名称"}

        true ->
          bee =
            Bee.new(%{
              "colony_id" => invite["colony_id"],
              "display" => display,
              "kind" => invite["kind"]
            })

          bee =
            if invite["kind"] == "ai",
              do:
                Map.merge(bee, %{
                  "remote_member_id" => bee["id"],
                  "garden_id" => Id.new(:garden),
                  "status" => "offline"
                }),
              else: bee

          identity = %{
            "id" => digest(token),
            "bee_id" => bee["id"],
            "colony_id" => invite["colony_id"],
            "kind" => invite["kind"],
            "revoked" => false
          }

          next =
            data
            |> put_in(["invites", id, "used"], true)
            |> put_in(["bees", bee["id"]], bee)
            |> put_in(["identities", identity["id"]], identity)

          {:ok,
           {:ok,
            %{
              "token" => token,
              "bee" => bee,
              "colony" => get_in(data, ["colonies", invite["colony_id"]])
            }}, next}
      end
    end)
  end

  def redeem(_, _), do: {:error, "bad_request", "需要邀请码与显示名"}

  def authenticate(token) when is_binary(token) and byte_size(token) > 10 do
    with {:ok, identity} <- Store.get("identities", digest(token)),
         false <- identity["revoked"],
         {:ok, bee} <- Store.get_bee(identity["bee_id"]),
         {:ok, colony} <- Store.get_colony(identity["colony_id"]),
         false <- colony["status"] == "dissolved" do
      {:ok, identity, bee}
    else
      _ -> {:error, "unauthorized", "成员凭据失效"}
    end
  end

  def authenticate(_), do: {:error, "unauthorized", "缺少成员凭据"}

  def actor(payload) do
    token = payload["__token__"]

    case authenticate(token) do
      {:ok, identity, bee} ->
        if payload["colonyId"] in [nil, identity["colony_id"]],
          do: {:ok, bee, :member},
          else: {:error, "forbidden", "凭据不属于该蜂群"}

      _ ->
        allowed =
          (token in [nil, ""] and not Newbee.Web.Auth.auth_required?(Newbee.Web.Router.bind_ip())) or
            (is_binary(token) and Newbee.Web.Auth.check_token(token) == :ok)

        if allowed do
          case Store.get_colony(payload["colonyId"]) do
            {:ok, colony} ->
              id = List.first(colony["admin_bee_ids"] || [colony["queen_bee_id"]])
              with {:ok, bee} <- Store.get_bee(id), do: {:ok, bee, :owner}

            _ ->
              {:ok, nil, :owner}
          end
        else
          {:error, "unauthorized", "请先登录"}
        end
    end
  end

  def revoke(cid, bid, actor) do
    with {:ok, colony} <- Store.get_colony(cid), :ok <- Control.authorize(colony, actor) do
      Store.transaction(fn data ->
        identities =
          Map.new(data["identities"], fn {id, v} ->
            {id,
             if(v["colony_id"] == cid and v["bee_id"] == bid,
               do: Map.put(v, "revoked", true),
               else: v
             )}
          end)

        {:ok, :ok, Map.put(data, "identities", identities)}
      end)
    end
  end

  def session_access(token, sid, mode \\ :read) do
    case authenticate(token) do
      {:ok, identity, _} ->
        case Store.get("conversations", sid) do
          {:ok, conversation} ->
            same = conversation["colony_id"] == identity["colony_id"]
            participant = identity["bee_id"] in (conversation["participants"] || [])

            allowed =
              same and (participant or (mode == :read and conversation["visibility"] == "work"))

            if allowed, do: :ok, else: {:error, "forbidden", "无权访问该会话"}

          _ ->
            {:error, "forbidden", "会话不属于当前成员"}
        end

      _ ->
        if (token in [nil, ""] and not Newbee.Web.Auth.auth_required?(Newbee.Web.Router.bind_ip())) or
             (is_binary(token) and Newbee.Web.Auth.check_token(token) == :ok),
           do: :ok,
           else: {:error, "unauthorized", "请先登录"}
    end
  end

  def authorize_rpc(method, payload) do
    case authenticate(payload["__token__"]) do
      {:ok, _, _} ->
        cond do
          method == "auth.status" ->
            :ok

          String.starts_with?(method, "colony.") ->
            :ok

          method in ~w(session.resume session.history session.state session.queue session.info) ->
            session_access(payload["__token__"], payload["sessionId"], :read)

          method in ~w(session.prompt session.btw session.interrupt session.permission session.ask.reply session.queue.remove session.queue.edit session.queue.reorder) ->
            session_access(payload["__token__"], payload["sessionId"], :write)

          true ->
            {:error, "forbidden", "成员凭据不能管理宿主机"}
        end

      _ ->
        :ok
    end
  end

  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:millisecond)
end
