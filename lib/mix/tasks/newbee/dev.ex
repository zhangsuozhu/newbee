defmodule Mix.Tasks.Newbee.Dev do
  @shortdoc "开发循环：起 WebUI，改完代码自动重编译并重启监听"
  @moduledoc """
  一条命令进入开发循环：`mix newbee.dev [options]`。

  与 `mix newbee.web` 的区别：
  - 监听源码变化，改完自动编译并**热换改动过的模块**（含依赖它的模块），服务不中断：
    编译放在子进程里做，只有毫秒级的模块替换会短暂介入；改了端口、插件装配这类
    需要重新装一遍的东西，按 `r` 重启监听；
  - 编译失败不会打断正在跑的服务，改对了下一轮自动接上；
  - 前端静态资源本来就不缓存，改完刷新浏览器即可（只提示，不重启）。

  参数会记到 `.newbee/dev.flags`，下次 `mix newbee.dev` 直接复用（命令行优先）；
  想忽略已记住的参数用 `--forget`。

  ## 选项
    --host HOST          绑定地址（默认 127.0.0.1）
    --port PORT          端口（默认 4173）
    --https / --no-https 是否启用 HTTPS（自签证书，同 mix newbee.web）
    --certfile PATH / --keyfile PATH
    --redirect / --redirect-port N
    --set-password [PW]  设置/更新登录密码（不跟值则交互式输入）
    --password PW        直接设置密码
    --no-watch           只起服务，不监听文件变化
    --interval MS        轮询间隔，默认 700
    --tests              每次重载后自动跑一次 `mix newbee.test_fast`
    --no-save            不记住本次参数
    --forget             忽略已记住的参数

  ## 交互（在跑服务的终端里按）
    r  重编译并重启监听
    t  跑一次快速测试
    q  退出
  """

  use Mix.Task

  @switches [
    host: :string,
    port: :integer,
    https: :boolean,
    certfile: :string,
    keyfile: :string,
    redirect: :boolean,
    redirect_port: :integer,
    set_password: :keep,
    password: :string,
    watch: :boolean,
    interval: :integer,
    tests: :boolean,
    save: :boolean,
    forget: :boolean
  ]

  @watch_globs ["lib/**/*.ex", "lib/**/*.eex", "mix.exs", "priv/web/**/*"]
  @web_prefix "priv/web/"
  @flags_file ".newbee/dev.flags"

  @impl true
  def run(args) do
    Newbee.Cwd.apply!()

    {inline_pw, rest} = Mix.Tasks.Newbee.Web.extract_inline_password(args)
    {opts, _argv, invalid} = OptionParser.parse(rest, strict: @switches)

    if invalid != [] do
      Mix.raise("无法识别的参数: " <> inspect(invalid))
    end

    cfg = build_config(opts, inline_pw)
    ensure_port_free(cfg)
    ensure_distributed!(cfg)
    Mix.Task.run("app.start")

    state = start_server(%{cfg: cfg, listener: nil, redirect: nil, snap: nil})
    if cfg.save, do: save_flags(cfg)
    banner(cfg)
    console(self())

    if cfg.watch do
      loop(%{state | snap: snapshot()})
    else
      Process.sleep(:infinity)
    end
  end

  # ── 主循环 ──

  defp loop(state) do
    receive do
      :quit ->
        shutdown(state)

      :reload ->
        # r：重编译再重启监听（改了端口/插件装配这类需要重新装一遍的东西时用）
        state = reload(state, "手动重编译")
        next = restart_listener(state)
        IO.puts("[dev] 监听已重启：#{url(next.cfg)}")
        loop(next)

      :test ->
        run_fast_tests()
        loop(state)
    after
      state.cfg.interval ->
        next = snapshot()

        if next == state.snap do
          loop(state)
        else
          loop(apply_changes(%{state | snap: next}, changed_paths(state.snap, next)))
        end
    end
  end

  defp apply_changes(state, changed) do
    web = Enum.filter(changed, &String.starts_with?(&1, @web_prefix))
    code = changed -- web

    cond do
      code != [] -> reload(state, "源码变更", code)
      web != [] -> state |> tap(fn _ -> report_static(web) end) |> Map.put(:snap, snapshot())
      true -> state
    end
  end

  # 编译放在子进程里做：同 VM 内编译会先把待编译模块 purge 掉，
  # 像 api.ex 这种大文件要 20 秒，那 20 秒里整个 WebUI 都在报错。
  # 子进程编译 + 毫秒级热换，能把这个空窗压到最短，而且编译失败不影响在跑的服务。
  defp reload(state, why, changed \\ []) do
    IO.puts("\n[dev] #{why}（#{length(changed)} 个文件）→ 编译中…")
    ebin = Mix.Project.compile_path()
    before = beam_mtimes(ebin)

    case compile_subprocess() do
      {:ok, ms} ->
        {swapped, skipped} = swap_changed_modules(before, beam_mtimes(ebin))
        IO.puts("[dev] 编译 #{ms} ms，热换 #{swapped} 个模块（跳过 #{skipped} 个）；服务没中断")

        if Enum.any?(changed, &(&1 == "mix.exs")) do
          IO.puts(["\e[33m", "[dev] mix.exs 变了：依赖/配置改动要 q 重开才生效。", "\e[0m"])
        end

        if state.cfg.tests, do: run_fast_tests()

        %{state | snap: snapshot()}

      {:error, output} ->
        IO.puts(["\e[31m", "[dev] 编译失败，继续用上一次的服务：", "\e[0m"])
        IO.puts(output)
        %{state | snap: snapshot()}
    end
  end

  defp compile_subprocess do
    started = System.monotonic_time(:millisecond)
    mix = System.find_executable("mix") || "mix"

    case System.cmd(mix, ["compile"], stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} -> {:ok, System.monotonic_time(:millisecond) - started}
      {_, code} -> {:error, "(mix compile 退出码 #{code})"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp beam_mtimes(ebin) do
    for beam <- Path.wildcard(Path.join(ebin, "*.beam")), into: %{} do
      case File.stat(beam, time: :posix) do
        {:ok, stat} -> {beam, stat.mtime}
        _ -> {beam, nil}
      end
    end
  end

  # 只换「已经加载过、且 beam 刚变过」的模块：soft_purge 不会打断正在跑的进程，
  # 没加载过的模块下次被调用时自然用的是新版。
  defp swap_changed_modules(before, after_) do
    for {beam, mtime} <- after_, Map.get(before, beam) != mtime, reduce: {0, 0} do
      {swapped, skipped} ->
        module = beam |> Path.basename(".beam") |> String.to_atom()

        if :code.is_loaded(module) == false do
          {swapped, skipped + 1}
        else
          _ = :code.soft_purge(module)

          result =
            case File.read(beam) do
              {:ok, binary} -> :code.load_binary(module, String.to_charlist(beam), binary)
              other -> other
            end

          case result do
            {:module, ^module} -> {swapped + 1, skipped}
            _other -> {swapped, skipped + 1}
          end
        end
    end
  end

  # ── 服务启停 ──

  defp start_server(state) do
    cfg = state.cfg

    server_opts =
      [port: cfg.port, host: cfg.host, https: cfg.https]
      |> maybe_put(:certfile, cfg.certfile)
      |> maybe_put(:keyfile, cfg.keyfile)

    {:ok, listener} = Newbee.Web.Server.start_link(server_opts)
    maybe_set_password(cfg)

    redirect =
      if cfg.redirect and cfg.https do
        case Newbee.Web.Server.start_redirect(cfg.redirect_port, cfg.port, cfg.host) do
          {:ok, pid} -> pid
          _ -> nil
        end
      end

    %{state | listener: listener, redirect: redirect}
  end

  defp restart_listener(state) do
    stop_listener(state.listener)
    stop_listener(state.redirect)

    case try_start(state, 12) do
      {:ok, next} ->
        next

      {:error, reason} ->
        IO.puts(["\e[31m", "[dev] 监听重启失败：#{inspect(reason)}", "\e[0m"])
        IO.puts("[dev] 按 r 重试；应用状态还在，只是端口没起来。")
        %{state | listener: nil, redirect: nil}
    end
  end

  defp try_start(_state, 0), do: {:error, :eaddrinuse}

  defp try_start(state, tries) do
    case start_server(%{state | listener: nil, redirect: nil}) do
      %{listener: pid} = next when is_pid(pid) -> {:ok, next}
      _ -> retry_start(state, tries)
    end
  rescue
    _error -> retry_start(state, tries)
  end

  defp retry_start(state, tries) do
    Process.sleep(150)
    try_start(state, tries - 1)
  end

  defp stop_listener(nil), do: :ok

  defp stop_listener(pid) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        _, _ -> Process.exit(pid, :shutdown)
      end
    end

    wait_dead(pid, 40)
  end

  defp wait_dead(_pid, 0), do: :ok

  defp wait_dead(pid, tries) do
    if Process.alive?(pid) do
      Process.sleep(50)
      wait_dead(pid, tries - 1)
    else
      :ok
    end
  end

  defp shutdown(state) do
    IO.puts("\n[dev] 退出，正在关闭监听…")
    stop_listener(state.listener)
    stop_listener(state.redirect)
    IO.puts("[dev] 已退出")
  end

  # ── 文件监听 ──

  defp snapshot do
    for glob <- @watch_globs, path <- Path.wildcard(glob), into: %{} do
      case File.stat(path, time: :posix) do
        {:ok, stat} -> {path, {stat.mtime, stat.size}}
        _ -> {path, nil}
      end
    end
  end

  defp changed_paths(before, after_) do
    keys = Enum.uniq(Map.keys(before) ++ Map.keys(after_))

    for key <- keys, Map.get(before, key) != Map.get(after_, key), do: key
  end

  defp report_static(paths) do
    IO.puts("\n[dev] 前端资源更新：#{Enum.join(Enum.take(paths, 4), ", ")}#{if length(paths) > 4, do: " 等"}")
    IO.puts("[dev] 静态资源不缓存，刷新浏览器即可（不重启服务）")
  end

  defp run_fast_tests do
    IO.puts("\n[dev] 跑快速测试…")
    started = System.monotonic_time(:millisecond)

    try do
      Mix.Task.reenable("newbee.test_fast")
      Mix.Task.run("newbee.test_fast")
      IO.puts("[dev] 快速测试通过（#{System.monotonic_time(:millisecond) - started} ms）")
    rescue
      error -> IO.puts(["\e[31m", "[dev] 快速测试失败：#{Exception.message(error)}", "\e[0m"])
    catch
      kind, reason -> IO.puts(["\e[31m", "[dev] 快速测试异常：#{kind} #{inspect(reason)}", "\e[0m"])
    end
  end

  # ── 参数 ──

  defp build_config(opts, inline_pw) do
    cached = if Keyword.get(opts, :forget, false), do: %{}, else: load_flags()

    pick = fn key, default ->
      cond do
        Keyword.has_key?(opts, key) -> Keyword.get(opts, key)
        Map.has_key?(cached, Atom.to_string(key)) -> Map.get(cached, Atom.to_string(key))
        true -> default
      end
    end

    host = parse_host(pick.(:host, "127.0.0.1"))

    %{
      host: host,
      host_string: host_str(host),
      port: pick.(:port, 4173),
      https: pick.(:https, false),
      certfile: pick.(:certfile, nil),
      keyfile: pick.(:keyfile, nil),
      redirect: pick.(:redirect, false),
      redirect_port: pick.(:redirect_port, 80),
      password: inline_pw || pick.(:password, nil),
      set_password: Keyword.has_key?(opts, :set_password),
      watch: pick.(:watch, true),
      interval: max(pick.(:interval, 700), 100),
      tests: pick.(:tests, false),
      save: pick.(:save, true)
    }
  end

  defp load_flags do
    case File.read(@flags_file) do
      {:ok, body} -> Jason.decode!(body)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save_flags(cfg) do
    body =
      Jason.encode!(%{
        "host" => cfg.host_string,
        "port" => cfg.port,
        "https" => cfg.https,
        "redirect" => cfg.redirect,
        "redirect_port" => cfg.redirect_port,
        "watch" => cfg.watch,
        "interval" => cfg.interval,
        "tests" => cfg.tests
      })

    File.mkdir_p!(Path.dirname(@flags_file))
    File.write!(@flags_file, body)
  rescue
    _ -> :ok
  end

  # 端口预检：早点说清「已经有服务在跑」，而不是抛一个 bind 错误。
  defp ensure_port_free(cfg) do
    case :gen_tcp.listen(cfg.port, [:binary, ip: cfg.host, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, :eaddrinuse} ->
        Mix.raise(
          "#{cfg.host_string}:#{cfg.port} 已被占用：可能已经有一个服务在跑（mix newbee.web / mix newbee.dev）。" <>
            "先停掉它，或换 --port。"
        )

      {:error, reason} ->
        Mix.raise("无法绑定 #{cfg.host_string}:#{cfg.port}（#{inspect(reason)}）")
    end
  end

  # ── 密码与地址 ──

  defp maybe_set_password(%{password: pw}) when is_binary(pw) and pw != "" do
    case Newbee.Web.Auth.set_password(pw) do
      :ok -> IO.puts("[dev] 登录密码已设置/更新")
      {:error, msg} -> Mix.raise("设置密码失败: " <> msg)
    end
  end

  defp maybe_set_password(%{set_password: true}) do
    pw1 = prompt_password("设置登录密码（≥6 位）: ")
    pw2 = prompt_password("再次输入确认: ")

    if pw1 == pw2 and pw1 != "" do
      case Newbee.Web.Auth.set_password(pw1) do
        :ok -> IO.puts("[dev] 登录密码已设置/更新")
        {:error, msg} -> Mix.raise("设置密码失败: " <> msg)
      end
    else
      Mix.raise("两次输入不一致")
    end
  end

  defp maybe_set_password(_cfg), do: :ok

  defp prompt_password(prompt) do
    IO.write(:standard_error, prompt)
    :io.setopts(:standard_io, echo: false)
    line = IO.gets("")
    :io.setopts(:standard_io, echo: true)
    IO.puts(:standard_error, "")
    String.trim(line || "")
  end

  defp banner(cfg) do
    IO.puts("")
    IO.puts("newbee dev 循环已启动：")
    IO.puts("  #{url(cfg)}")

    if Newbee.Web.Auth.auth_required?(cfg.host) do
      pw = if Newbee.Web.Auth.password_set?(), do: "（密码已设）", else: "（尚未设密码，请用 --set-password）"
      IO.puts("  远程模式：已启用登录认证" <> pw)
    else
      IO.puts("  本地模式（回环），免登录")
    end

    if cfg.watch do
      IO.puts("  监听：#{Enum.join(@watch_globs, ", ")}（#{cfg.interval} ms 轮询）")
      IO.puts("  改动后：子进程编译 + 毫秒级热换模块，服务不中断")
      IO.puts("  按键：r 重编译并重启监听 / t 快速测试 / q 退出")
    else
      IO.puts("  未开启监听（--no-watch）")
    end

    IO.puts("  参数已记住：#{@flags_file}（下次直接 mix newbee.dev）")
  end

  defp url(cfg) do
    scheme = if cfg.https, do: "https", else: "http"
    "#{scheme}://#{cfg.host_string}:#{cfg.port}"
  end

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

  defp host_str({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp host_str(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # 节点名跟 mix newbee.web 保持一致（只用端口）：shortnames 下名字里不能带点。
  defp ensure_distributed!(cfg) do
    unless Node.alive?() do
      port_for_name = System.get_env("NEWBEE_WEB_PORT") || Integer.to_string(cfg.port)
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

  defp console(owner) do
    spawn_link(fn -> console_loop(owner) end)
  end

  defp console_loop(owner) do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        case line |> String.trim() |> String.downcase() do
          "r" -> send(owner, :reload)
          "t" -> send(owner, :test)
          "q" -> send(owner, :quit)
          _ -> :ok
        end

        console_loop(owner)
    end
  end
end
