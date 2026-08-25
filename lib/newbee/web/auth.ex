defmodule Newbee.Web.Auth do
  @moduledoc """
  WebUI 认证（密码 + Bearer token + 图形验证码 + 限流/锁定）。纯函数 + ETS，无监督进程。

  ## 模型
  - 本地零摩擦：绑定回环地址时 auth_required? 为 false，请求直接放行。
  - 远程必须安全：绑定非回环地址时强制认证。请求带 Authorization: Bearer <token>（或 ?token=）。
  - 验证码防暴破：auth.captcha 返回 SVG；auth.login 必须带正确 captchaId+captcha，叠加 IP 限流与连续失败锁定。
  - token：登录发 32 字节随机 base64url token，ETS + sessions.json 持久化。12h 滑动过期，7d 绝对上限。

  密码存 ~/.newbee/web/auth.json（PBKDF2-SHA256，160k 迭代）。运行时状态存内存 ETS（:newbee_web_auth）。
  """

  require Logger

  @table :newbee_web_auth
  @digest :sha256
  @iterations 160_000
  @key_len 32
  @token_bytes 32
  @sliding_ttl_ms 12 * 3600 * 1000
  @absolute_ttl_ms 7 * 24 * 3600 * 1000
  @rate_window_ms 60_000
  @rate_max_attempts 10
  @lock_threshold 5
  @lock_base_ms 30_000
  @lock_max_ms 15 * 60_000
  @captcha_ttl_ms 5 * 60_000
  @captcha_chars ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"

  defp config_path, do: Path.join(Newbee.Web.Cert.dir(), "auth.json")
  defp sessions_path, do: Path.join(Newbee.Web.Cert.dir(), "sessions.json")

  # ── 密码 ──

  def password_set? do
    case read_config() do
      %{"password" => %{"hash" => h}} when is_binary(h) -> true
      _ -> false
    end
  end

  def set_password(password) when is_binary(password) do
    pw = String.trim(password)

    if byte_size(pw) < 6 do
      {:error, "密码至少 6 位"}
    else
      salt = :crypto.strong_rand_bytes(16)
      hash = pbkdf(pw, salt, @iterations)

      cfg =
        read_config()
        |> Map.put("password", %{
          "algo" => "pbkdf2-sha256",
          "iterations" => @iterations,
          "salt" => Base.encode64(salt),
          "hash" => Base.encode64(hash)
        })

      write_config(cfg)
      revoke_all_tokens()
      :ok
    end
  end

  def set_password(_), do: {:error, "密码不能为空"}

  def verify_password(password) when is_binary(password) do
    case read_config() do
      %{"password" => %{"salt" => s, "hash" => h, "iterations" => it}} ->
        with {:ok, salt} <- Base.decode64(s),
             {:ok, expected} <- Base.decode64(h) do
          Plug.Crypto.secure_compare(pbkdf(password, salt, it), expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp pbkdf(password, salt, iterations), do: :crypto.pbkdf2_hmac(@digest, password, salt, iterations, @key_len)

  # ── 回环门 ──

  def auth_required?(ip) when is_tuple(ip), do: not loopback?(ip)

  def auth_required?(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, tuple} -> auth_required?(tuple)
      :error -> true
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _b}) when a >= 0x7F00 and a <= 0x7FFF, do: true
  defp loopback?(_), do: false

  defp parse_ip(str) do
    str
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  end

  # ── Token ──

  def issue_token do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = System.system_time(:millisecond)
    put({:token, token}, %{created: now, last_seen: now})
    persist_sessions()
    {:ok, token}
  end

  def check_token(token) when is_binary(token) do
    now = System.system_time(:millisecond)

    case get({:token, token}) do
      nil ->
        {:error, :invalid}

      %{created: created, last_seen: last} ->
        cond do
          now - created > @absolute_ttl_ms ->
            delete({:token, token})
            persist_sessions()
            {:error, :expired}

          now - last > @sliding_ttl_ms ->
            delete({:token, token})
            persist_sessions()
            {:error, :expired}

          true ->
            put({:token, token}, %{created: created, last_seen: now})
            :ok
        end
    end
  end

  def check_token(_), do: {:error, :invalid}

  def revoke_token(token) when is_binary(token) do
    delete({:token, token})
    persist_sessions()
    :ok
  end

  defp revoke_all_tokens do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {{:token, _} = k, _} -> :ets.delete(@table, k)
      _ -> :ok
    end)

    persist_sessions()
  end

  defp persist_sessions do
    ensure_table()

    sessions =
      @table
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:token, tok}, %{created: c, last_seen: l}} -> [%{"token" => tok, "created" => c, "last_seen" => l}]
        _ -> []
      end)

    File.mkdir_p!(Newbee.Web.Cert.dir())
    File.write!(sessions_path(), Jason.encode!(%{"sessions" => sessions}))
  rescue
    _ -> :ok
  end

  def load_sessions do
    ensure_table()

    case File.read(sessions_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"sessions" => list}} when is_list(list) ->
            now = System.system_time(:millisecond)

            Enum.each(list, fn
              %{"token" => tok, "created" => c, "last_seen" => l}
              when is_binary(tok) and is_number(c) and is_number(l) ->
                if now - c <= @absolute_ttl_ms and now - l <= @sliding_ttl_ms,
                  do: put({:token, tok}, %{created: c, last_seen: l})

              _ ->
                :ok
            end)

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  # ── 限流 + 锁定 ──

  def check_rate(ip) do
    now = System.system_time(:millisecond)

    case get({:lock, ip}) do
      %{until: until} when until > now -> {:error, until - now}
      _ -> :allowed
    end
  end

  def record_fail(ip) do
    now = System.system_time(:millisecond)
    key = {:fail, ip}
    rec = get(key) || %{count: 0, attempts: []}
    attempts = Enum.filter(rec.attempts, &(&1 > now - @rate_window_ms))
    attempts = [now | attempts]

    if length(attempts) > @rate_max_attempts do
      lock(ip, @lock_base_ms)
      delete(key)
      {:error, @lock_base_ms}
    else
      count = rec.count + 1
      put(key, %{count: count, attempts: attempts})

      if count >= @lock_threshold do
        shift = min(count - @lock_threshold, 9)
        ms = min(@lock_base_ms * Integer.pow(2, shift), @lock_max_ms)
        lock(ip, ms)
        delete(key)
        {:error, ms}
      else
        :ok
      end
    end
  end

  def record_success(ip) do
    delete({:fail, ip})
    delete({:lock, ip})
    :ok
  end

  defp lock(ip, ms) do
    put({:lock, ip}, %{until: System.system_time(:millisecond) + ms})
    Logger.warning("[newbee.web] 登录尝试过多，IP " <> format_ip(ip) <> " 锁定 " <> Integer.to_string(div(ms, 1000)) <> "s")
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)

  # ── 验证码 ──

  def gen_captcha do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    text = for _ <- 1..4, into: "", do: <<Enum.random(@captcha_chars)>>
    put({:captcha, id}, %{text: String.downcase(text), expires: System.system_time(:millisecond) + @captcha_ttl_ms})
    %{id: id, svg: captcha_svg(text), text: text}
  end

  def verify_captcha(id, answer) when is_binary(id) and is_binary(answer) do
    case get({:captcha, id}) do
      nil ->
        false

      %{text: text, expires: exp} ->
        delete({:captcha, id})

        System.system_time(:millisecond) <= exp and
          Plug.Crypto.secure_compare(text, String.downcase(String.trim(answer)))
    end
  end

  def verify_captcha(_, _), do: false

  # ── 登录主流程 ──

  def login(payload, ip) do
    case check_rate(ip) do
      :allowed -> do_login(payload, ip)
      {:error, retry_ms} -> {:error, "locked", "尝试过于频繁，请 " <> Integer.to_string(max(div(retry_ms, 1000), 1)) <> " 秒后再试"}
    end
  end

  defp do_login(%{"password" => pw, "captchaId" => cid, "captcha" => cap}, ip) do
    cond do
      not verify_captcha(cid, cap) ->
        record_fail(ip)
        {:error, "bad_captcha", "验证码错误或已过期，请刷新后重试"}

      not password_set?() ->
        {:error, "no_password", "尚未设置密码，请先通过 auth.setup 设置"}

      verify_password(pw) ->
        record_success(ip)
        {:ok, token} = issue_token()
        {:ok, token}

      true ->
        case record_fail(ip) do
          {:error, ms} -> {:error, "locked", "失败次数过多，已锁定 " <> Integer.to_string(div(ms, 1000)) <> " 秒"}
          :ok -> {:error, "bad_password", "密码错误"}
        end
    end
  end

  defp do_login(_, ip) do
    record_fail(ip)
    {:error, "bad_request", "缺少 password/captchaId/captcha"}
  end

  def setup(%{"password" => pw}) do
    if password_set?() do
      {:error, "already_set", "密码已设置，请使用 auth.login"}
    else
      case set_password(pw) do
        :ok ->
          {:ok, token} = issue_token()
          {:ok, token}

        {:error, msg} ->
          {:error, "weak_password", msg}
      end
    end
  end

  def setup(_), do: {:error, "bad_request", "缺少 password"}

  # ── SVG 验证码 ──

  defp captcha_svg(text) do
    width = 132
    height = 44

    glyphs =
      text
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {ch, i} ->
        x = 16 + i * 27 + :rand.uniform(5) - 2
        y = 30 + :rand.uniform(6) - 3
        rot = :rand.uniform(50) - 25
        size = 22 + :rand.uniform(6)

        "<text x=\"" <>
          Integer.to_string(x) <>
          "\" y=\"" <>
          Integer.to_string(y) <>
          "\" transform=\"rotate(" <>
          Integer.to_string(rot) <>
          " " <>
          Integer.to_string(x) <>
          " " <>
          Integer.to_string(y) <>
          ")\" font-family=\"monospace\" font-size=\"" <>
          Integer.to_string(size) <>
          "\" font-weight=\"700\" fill=\"" <>
          svg_color(60, 150) <>
          "\">" <> ch <> "</text>"
      end)

    noise_lines =
      for _ <- 1..4 do
        "<line x1=\"" <>
          Integer.to_string(:rand.uniform(width)) <>
          "\" y1=\"" <>
          Integer.to_string(:rand.uniform(height)) <>
          "\" x2=\"" <>
          Integer.to_string(:rand.uniform(width)) <>
          "\" y2=\"" <>
          Integer.to_string(:rand.uniform(height)) <>
          "\" stroke=\"" <>
          svg_color(120, 200) <>
          "\" stroke-width=\"1.4\"/>"
      end

    noise_dots =
      for _ <- 1..25 do
        "<circle cx=\"" <>
          Integer.to_string(:rand.uniform(width)) <>
          "\" cy=\"" <>
          Integer.to_string(:rand.uniform(height)) <>
          "\" r=\"" <>
          Float.to_string((:rand.uniform(15) + 5) / 10) <>
          "\" fill=\"" <> svg_color(100, 190) <> "\"/>"
      end

    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" <>
      Integer.to_string(width) <>
      "\" height=\"" <>
      Integer.to_string(height) <>
      "\" viewBox=\"0 0 " <>
      Integer.to_string(width) <>
      " " <>
      Integer.to_string(height) <>
      "\"><rect width=\"100%\" height=\"100%\" fill=\"" <>
      svg_color(230, 245) <>
      "\"/>" <>
      Enum.join(noise_lines) <> Enum.join(noise_dots) <> Enum.join(glyphs) <> "</svg>"
  end

  defp svg_color(lo, hi) do
    r = lo + :rand.uniform(hi - lo)
    g = lo + :rand.uniform(hi - lo)
    b = lo + :rand.uniform(hi - lo)
    "rgb(" <> Integer.to_string(r) <> "," <> Integer.to_string(g) <> "," <> Integer.to_string(b) <> ")"
  end

  # ── 内部 ──

  defp read_config do
    case File.read(config_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, cfg} when is_map(cfg) -> cfg
          _ -> %{}
        end

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp write_config(cfg) do
    File.mkdir_p!(Newbee.Web.Cert.dir())
    File.write!(config_path(), Jason.encode!(cfg, pretty: true))
    File.chmod(config_path(), 0o600)
    :ok
  end

  defp ensure_table do
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

  defp get(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, val}] -> val
      [] -> nil
    end
  end

  defp put(key, val) do
    ensure_table()
    :ets.insert(@table, {key, val})
    :ok
  end

  defp delete(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end
end
