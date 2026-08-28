defmodule Newbee.Web.WebAuthn do
  @moduledoc """
  WebAuthn 指纹/面容登录（无密码通行密钥）。
  """

  require Logger

  @table :newbee_web_authn
  @challenge_ttl_ms 5 * 60_000

  defp config_path, do: Path.join(Newbee.Web.Cert.dir(), "webauthn.json")

  # ── 凭据管理 ──

  def credentials do
    case read_config() do
      %{"credentials" => creds} when is_map(creds) -> creds
      _ -> %{}
    end
  end

  def credentials_count, do: map_size(credentials())

  def has_credentials?, do: credentials_count() > 0

  def list_credentials do
    credentials()
    |> Enum.map(fn {cred_id, meta} ->
      %{
        credential_id: cred_id,
        name: meta["name"] || "未命名设备",
        created_at: meta["created_at"],
        last_used_at: meta["last_used_at"]
      }
    end)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  def delete_credential(cred_id) when is_binary(cred_id) do
    cfg = read_config()

    case get_in(cfg, ["credentials", cred_id]) do
      nil ->
        {:error, "not_found", "凭据不存在"}

      _ ->
        new_cfg = put_in(cfg, ["credentials"], Map.delete(credentials(), cred_id))
        write_config(new_cfg)
        :ok
    end
  end

  # ── 注册 ──

  def registration_challenge(name \\ "未命名设备") do
    with :ok <- ensure_webauthn_origin() do
      do_registration_challenge(name)
    end
  end

  defp do_registration_challenge(name) do
    challenge =
      Wax.new_registration_challenge(
        origin: origin(),
        rp_id: :auto,
        attestation: "none",
        user_verification: "preferred"
      )
    challenge_id = store_challenge(challenge, {:register, name})

    {:ok,
     %{
       challenge_id: challenge_id,
       challenge: Base.url_encode64(challenge.bytes, padding: false),
       rp: %{name: "newbee", id: challenge.rp_id},
       user: %{
         id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
         name: "newbee",
         display_name: "newbee 管理员"
       },
       pub_key_cred_params: [
         %{type: "public-key", alg: -7},
         %{type: "public-key", alg: -257}
       ],
       timeout: challenge.timeout * 1000,
       attestation: challenge.attestation,
       authenticator_selection: %{
         authenticator_attachment: "platform",
         user_verification: challenge.user_verification
       }
     }}
  end

  def register(challenge_id, attestation_object_b64, client_data_json_b64, cred_id) do
    with {:ok, {challenge, {:register, name}}} <- pop_challenge(challenge_id),
         {:ok, attestation_object} <- Base.url_decode64(attestation_object_b64, padding: false),
         {:ok, client_data_json} <- Base.url_decode64(client_data_json_b64, padding: false),
         {:ok, {auth_data, _attestation}} <- Wax.register(attestation_object, client_data_json, challenge) do
      credential_id = auth_data.attested_credential_data.credential_id
      public_key = auth_data.attested_credential_data.credential_public_key

      cfg = read_config()

      new_cred = %{
        "name" => name,
        "public_key" => :erlang.term_to_binary(public_key) |> Base.encode64(),
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "last_used_at" => nil
      }

      new_cfg = put_in(cfg, ["credentials"], Map.put(credentials(), cred_id, new_cred))
      write_config(new_cfg)

      Logger.info("[newbee.web] WebAuthn 凭据已注册: #{name}")
      {:ok, %{credential_id: cred_id}}
    else
      {:error, :challenge_not_found} ->
        {:error, "bad_challenge", "挑战已过期或不存在，请重试"}

      {:error, :invalid_base64} ->
        {:error, "bad_request", "Base64 解码失败"}

      {:error, e} ->
        Logger.warning("[newbee.web] WebAuthn 注册失败: #{inspect(e)}")
        {:error, "verify_failed", "注册验证失败: #{Exception.message(e)}"}
    end
  end

  # ── 登录 ──

  def authentication_challenge do
    allow_creds =
      credentials()
      |> Enum.map(fn {cred_id, meta} ->
        {:ok, pk_bin} = Base.decode64(meta["public_key"])
        public_key = :erlang.binary_to_term(pk_bin)
        {Base.url_decode64!(cred_id, padding: false), public_key}
      end)

    with :ok <- ensure_webauthn_origin() do
      do_authentication_challenge(allow_creds)
    end
  end

  defp do_authentication_challenge(allow_creds) do
    challenge =
      Wax.new_authentication_challenge(
        origin: origin(),
        rp_id: :auto,
        allow_credentials: allow_creds,
        user_verification: "preferred"
      )

    challenge_id = store_challenge(challenge, :login)

    {:ok,
     %{
       challenge_id: challenge_id,
       challenge: Base.url_encode64(challenge.bytes, padding: false),
       timeout: challenge.timeout * 1000,
       rp_id: challenge.rp_id,
       allow_credentials:
         Enum.map(allow_creds, fn {cred_id_bin, _} ->
           %{type: "public-key", id: Base.url_encode64(cred_id_bin, padding: false)}
         end),
       user_verification: challenge.user_verification
     }}
  end

  def authenticate(challenge_id, cred_id_b64, auth_data_b64, sig_b64, client_data_json_b64) do
    with {:ok, {challenge, :login}} <- pop_challenge(challenge_id),
         {:ok, cred_id} <- Base.url_decode64(cred_id_b64, padding: false),
         {:ok, auth_data} <- Base.url_decode64(auth_data_b64, padding: false),
         {:ok, sig} <- Base.url_decode64(sig_b64, padding: false),
         {:ok, client_data_json} <- Base.url_decode64(client_data_json_b64, padding: false),
         {:ok, auth_data_struct} <- Wax.authenticate(cred_id, auth_data, sig, client_data_json, challenge) do
      # 更新 last_used_at
      cred_id_b64 = Base.url_encode64(cred_id, padding: false)

      cfg = read_config()

      new_cfg =
        update_in(cfg, ["credentials", cred_id_b64, "last_used_at"], fn _ ->
          DateTime.utc_now() |> DateTime.to_iso8601()
        end)

      write_config(new_cfg)

      Logger.info("[newbee.web] WebAuthn 登录成功")
      {:ok, auth_data_struct}
    else
      {:error, :challenge_not_found} ->
        {:error, "bad_challenge", "挑战已过期或不存在，请重试"}

      {:error, :invalid_base64} ->
        {:error, "bad_request", "Base64 解码失败"}

      {:error, e} ->
        Logger.warning("[newbee.web] WebAuthn 登录验证失败: #{inspect(e)}")
        {:error, "verify_failed", "登录验证失败: #{Exception.message(e)}"}
    end
  end

  # origin/rp_id 推导

  defp origin do
    Process.get({__MODULE__, :origin}, "https://localhost:8443")
  end

  def set_origin(origin) when is_binary(origin) do
    Process.put({__MODULE__, :origin}, origin)
  end

  # WebAuthn 规范要求 RP ID 必须是有效域名（不能是 IP 地址）。用 IP 直接访问
  # WebUI 时（如 https://192.168.0.8:5151），rp_id=:auto 推导出的 RP ID 是裸 IP，
  # 浏览器在 navigator.credentials.create/get 阶段直接抛
  # "This is an invalid domain."。这里在服务端提前拦截，返回可操作的引导。
  defp ensure_webauthn_origin do
    host = URI.parse(origin()).host || ""

    if ip_literal?(host) do
      {:error, "invalid_domain",
       "当前通过 IP 地址（#{host}）访问，浏览器禁止在该站点使用通行密钥（指纹/面容）。" <>
         "请改用域名/主机名访问本服务后再试，例如 http://<主机名>.local 或配置的域名。"}
    else
      :ok
    end
  end

  defp ip_literal?(host) do
    charlist = String.to_charlist(host)

    cond do
      match?({:ok, {_, _, _, _}}, :inet.parse_ipv4_address(charlist)) -> true
      match?({:ok, {_, _, _, _, _, _, _, _}}, :inet.parse_ipv6_address(charlist)) -> true
      String.starts_with?(host, "[") -> true
      true -> false
    end
  end

  # 挑战存储

  defp store_challenge(challenge, context) do
    challenge_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    now = System.system_time(:millisecond)

    ensure_table()

    :ets.insert(
      @table,
      {{:challenge, challenge_id}, %{challenge: challenge, context: context, expires: now + @challenge_ttl_ms}}
    )

    challenge_id
  end

  defp pop_challenge(challenge_id) do
    ensure_table()
    now = System.system_time(:millisecond)

    case :ets.lookup(@table, {:challenge, challenge_id}) do
      [{{:challenge, ^challenge_id}, %{challenge: challenge, context: context, expires: exp}}] ->
        :ets.delete(@table, {:challenge, challenge_id})

        if now <= exp do
          {:ok, {challenge, context}}
        else
          {:error, :challenge_not_found}
        end

      [] ->
        {:error, :challenge_not_found}
    end
  end

  # 配置读写

  defp read_config do
    case File.read(config_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, cfg} when is_map(cfg) -> cfg
          _ -> %{"credentials" => %{}}
        end

      _ ->
        %{"credentials" => %{}}
    end
  rescue
    _ -> %{"credentials" => %{}}
  end

  defp write_config(cfg) do
    File.mkdir_p!(Newbee.Web.Cert.dir())
    File.write!(config_path(), Jason.encode!(cfg, pretty: true))
    File.chmod(config_path(), 0o600)
    :ok
  end

  @doc """
  创建挑战 ETS 表（若不存在）。由 Application 主进程在启动时调用，
  确保表归属长寿进程，不随 Plug 请求进程退出而销毁。
  """
  def create_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end

  @doc false
  def pop_challenge_for_test(challenge_id), do: pop_challenge(challenge_id)

  defp ensure_table, do: create_table()
end

