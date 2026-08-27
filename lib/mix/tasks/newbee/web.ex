defmodule Mix.Tasks.Newbee.Web do
  @shortdoc "启动 newbee WebUI（浏览器界面）"
  @moduledoc """
  启动 newbee WebUI：`mix newbee.web [options]`。

  ## 选项
    --host HOST         绑定地址（默认 127.0.0.1；0.0.0.0 暴露到局域网/公网）
    --port PORT         端口（默认 4173）
    --https             启用 HTTPS（自签 RSA 2048 证书，首启自动生成于 ~/.newbee/web/）
    --certfile PATH     使用自己的证书（与 --https 同用；需配 --keyfile）
    --keyfile PATH      自己的私钥
    --redirect          另起 HTTP→HTTPS 308 重定向（需配 --https）
    --redirect-port N   重定向用的 HTTP 端口（默认 80）
    --set-password [PW] 首次设置登录密码（已有密码时保持不变，不会覆盖）：
                        不跟值交互式输入；跟值直接设置（如 --set-password h4njhmC）
    --reset-password    重置密码（覆盖旧密码并吊销全部已登录会话，交互式输入）

    密码持久化于 ~/.newbee/web/auth.json，重启自动恢复，日常启动无需传密码参数
    --password PW       直接设置密码（脚本/测试用）

  ## 安全模型
  - 绑定回环地址（默认 127.0.0.1）：本地零摩擦，无需登录，HTTP 即可。
  - 绑定非回环地址（如 0.0.0.0，远程暴露）：强制登录 + 图形验证码防暴破，
    强烈建议配 --https（或用反代终止 TLS）。

  浏览器打开 http(s)://HOST:PORT 即可使用。
  """
  use Mix.Task

  @impl true
  def run(args) do
    Newbee.Cwd.apply!()

    {inline_pw, args} = extract_inline_password(args)

    {opts, _argv, _} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          port: :integer,
          https: :boolean,
          certfile: :string,
          keyfile: :string,
          redirect: :boolean,
          redirect_port: :integer,
          set_password: :keep,
          password: :string,
          reset_password: :keep
        ]
      )

    opts =
      case inline_pw do
        nil -> opts
        pw -> Keyword.put(opts, :password, pw)
      end

    port = Keyword.get(opts, :port, 4173)
    host = parse_host(Keyword.get(opts, :host, "127.0.0.1"))

    ensure_distributed!(port)
    Mix.Task.run("app.start")

    https? = Keyword.get(opts, :https, false)
    redirect? = Keyword.get(opts, :redirect, false)

    server_opts =
      [port: port, host: host, https: https?]
      |> maybe_put(:certfile, Keyword.get(opts, :certfile))
      |> maybe_put(:keyfile, Keyword.get(opts, :keyfile))

    {:ok, _} = Newbee.Web.Server.start_link(server_opts)

    # 密码设置放在端口绑定成功之后：避免“密码已改写但服务没起来”的不一致窗口
    maybe_set_password(opts)

    if redirect? and https? do
      rport = Keyword.get(opts, :redirect_port, 80)
      {:ok, _} = Newbee.Web.Server.start_redirect(rport, port, host)
      IO.puts("  http://" <> host_str(host) <> ":" <> Integer.to_string(rport) <> " → 重定向到 https")
    end

    scheme = if https?, do: "https", else: "http"
    remote? = Newbee.Web.Auth.auth_required?(host)

    IO.puts("\nnewbee webui 已启动：")
    IO.puts("  " <> scheme <> "://" <> host_str(host) <> ":" <> Integer.to_string(port))

    if remote? do
      pw = if Newbee.Web.Auth.password_set?(), do: "（密码已设）", else: "（尚未设密码，请用 --set-password）"
      IO.puts("  远程模式：已启用登录认证" <> pw)
      unless https?, do: IO.puts("  警告：远程访问未启用 HTTPS，密码/数据明文传输！")
    else
      IO.puts("  本地模式（回环），免登录")
    end

    IO.puts("Ctrl+C 退出")

    Process.sleep(:infinity)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp parse_host(str) do
    case str |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} ->
        ip

      _ ->
        case :inet.getaddr(String.to_charlist(str), :inet) do
          {:ok, ip} -> ip
          _ -> Mix.raise("无法解析 --host " <> str)
        end
    end
  end

  defp host_str({a, b, c, d}),
    do:
      Integer.to_string(a) <>
        "." <> Integer.to_string(b) <> "." <> Integer.to_string(c) <> "." <> Integer.to_string(d)

  defp host_str(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  # 密码持久化在 ~/.newbee/web/auth.json，重启自动恢复，无需每次启动都传。
  # --set-password 只在「尚未设密码」时生效；已有密码时保持不变——
  # 历史版本在此无条件覆盖 + 吊销全部登录会话，且发生在端口绑定之前：
  # 若随后端口被占用导致本实例崩溃，磁盘上密码已被换掉而旧实例仍在跑，
  # 造成"重启后密码失忆/对不上"的现场。确要改密码请用 --reset-password。
  defp maybe_set_password(opts) do
    cond do
      pw = Keyword.get(opts, :password) ->
        if Newbee.Web.Auth.password_set?() do
          Mix.shell().info(
            "[newbee.web] 密码已设置，本次保持不变（--set-password 不再覆盖已有密码；如需重置请用 --reset-password）"
          )
        else
          case Newbee.Web.Auth.set_password(pw) do
            :ok -> Mix.shell().info("[newbee.web] 登录密码已设置")
            {:error, msg} -> Mix.raise("设置密码失败: " <> msg)
          end
        end

      Keyword.get(opts, :set_password, false) ->
        maybe_interactive_set_password()

      Keyword.get(opts, :reset_password, false) ->
        reset_password!()

      true ->
        :ok
    end
  end

  defp maybe_interactive_set_password do
    if Newbee.Web.Auth.password_set?() do
      Mix.shell().info(
        "[newbee.web] 密码已设置，本次保持不变（--set-password 不再覆盖已有密码；如需重置请用 --reset-password）"
      )
    else
      pw1 = prompt_password("设置登录密码（≥6 位）: ")
      pw2 = prompt_password("再次输入确认: ")

      if pw1 == pw2 do
        case Newbee.Web.Auth.set_password(pw1) do
          :ok -> Mix.shell().info("[newbee.web] 登录密码已设置")
          {:error, msg} -> Mix.raise("设置密码失败: " <> msg)
        end
      else
        Mix.raise("两次输入不一致")
      end
    end
  end

  # 显式重置：覆盖现有密码并吊销全部已登录会话
  defp reset_password! do
    pw1 = prompt_password("重置登录密码（≥6 位）: ")
    pw2 = prompt_password("再次输入确认: ")

    if pw1 == pw2 do
      case Newbee.Web.Auth.set_password(pw1) do
        :ok -> Mix.shell().info("[newbee.web] 登录密码已重置，所有已登录会话已吊销")
        {:error, msg} -> Mix.raise("重置密码失败: " <> msg)
      end
    else
      Mix.raise("两次输入不一致")
    end
  end

  defp prompt_password(prompt) do
    IO.write(:standard_error, prompt)
    :io.setopts(:standard_io, echo: false)
    line = IO.gets("")
    :io.setopts(:standard_io, echo: true)
    IO.puts(:standard_error, "")
    String.trim(line || "")
  end

  # --set-password 支持内联值（--set-password PW / --set-password=PW 直接设置密码），
  # 不带值时保持原有交互式输入。返回 {密码或 nil, 其余参数}。
  def extract_inline_password(args), do: extract_pw(args, nil, [])

  defp extract_pw([], pw, rest), do: {pw, Enum.reverse(rest)}

  defp extract_pw(["--set-password=" <> v | t], nil, acc), do: extract_pw(t, v, acc)

  defp extract_pw(["--set-password", v | t], nil, acc) when v != "" do
    if String.starts_with?(v, "--") do
      extract_pw(t, nil, [v, "--set-password" | acc])
    else
      extract_pw(t, v, acc)
    end
  end

  defp extract_pw(["--set-password" | t], nil, acc),
    do: extract_pw(t, nil, ["--set-password" | acc])

  defp extract_pw([h | t], pw, acc), do: extract_pw(t, pw, [h | acc])

  defp ensure_distributed!(port) do
    unless Node.alive?() do
      port_for_name = System.get_env("NEWBEE_WEB_PORT") || Integer.to_string(port)
      name = "newbee_web_" <> port_for_name
      {:ok, _} = Node.start(String.to_atom(name <> "@" <> hostname()), :shortnames)
      true = Node.alive?()
    end

    :ok
  end

  defp hostname do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end
end