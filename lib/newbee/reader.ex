defmodule Newbee do
  @moduledoc """
  Unified addressable read (DESIGN §3.2): `Newbee.read/1` handles files, directories, URLs, and internal schemes.
  Teach the model exactly one interface.

  Scheme overview:
    - bare path       → file or directory
    - `file://`     → file
    - `tool://M`    → module docs (@moduledoc + public @doc entries)
    - `rules://[sub]` → sleeping-rule list (empty lists all, non-empty filters by id+pattern; routed to host)
    - `memory://k`  → global memory entry (empty key lists topics)
    - `bindings://` → evaluator binding digest (routed to host)
    - `history://`  → this session's compacted archive (index / `s/<seg>` digest / `s/<seg>/raw` verbatim /
                 `q/<keyword>` full-text search / `files` file list) — compacted dialogue stays retrievable
    - `events://`   → event log (optional ?n= count, clamped 1..1000, default 200)
    - `skill://n`   → skill snippet (~/.newbee/skills or project .newbee/skills, dot-md suffix idempotent, trust envelope)
    - `agent://<id>/<path>` → subagent result field at path (missing segment returns :path_not_found)
    - `conflict://` → git merge-conflict list; `conflict://<file>` conflict-hunk view (bad hunks skipped, never crashes)
    - `http(s)://`  → web pages (credentialless public GET via Newbee.Tools.Http; private nets blocked against SSRF)

  Discoverability: `schemes/0` returns a machine-readable list; new protocols must register plus carry contract tests.
  """
  @doc """
  Unified read. Returns {:ok, content} | {:error, reason}.

    - Directories → one-level listing (dir names take a / suffix)
    - Files → text content (capped at 512KB, truncation marked)
    - URLs → page text
    - Internal schemes → see @moduledoc
  """
  def read(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "tool://") ->
        read_tool(String.replace_prefix(path, "tool://", ""))

      path == "rules://" or String.starts_with?(path, "rules://") ->
        read_rules(String.replace_prefix(path, "rules://", ""))

      String.starts_with?(path, "memory://") ->
        read_memory(String.replace_prefix(path, "memory://", ""))

      String.starts_with?(path, "skill://") ->
        read_skill(String.replace_prefix(path, "skill://", ""))

      String.starts_with?(path, "agent://") ->
        read_agent(String.replace_prefix(path, "agent://", ""))

      path == "conflict://" or String.starts_with?(path, "conflict://") ->
        read_conflict(String.replace_prefix(path, "conflict://", ""))

      path == "bindings://" ->
        read_bindings()

      # history:// 经 Host.call 回主节点执行：peer 求值节点上的模型代码同样可用。
      # 多会话下不能依赖全局 current：先从本进程 capability 解析会话（peer 侧），
      # 再回主节点读该会话档案；无 capability 才回退全局 current（CLI/TUI 兼容）。
      path == "history://" or String.starts_with?(path, "history://") ->
        read_history_scoped(String.replace_prefix(path, "history://", ""))

      String.starts_with?(path, "events://") ->
        read_events(String.replace_prefix(path, "events://", ""))

      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        read_url(path)

      String.starts_with?(path, "file://") ->
        read_path(String.replace_prefix(path, "file://", ""))

      true ->
        read_path(path)
    end
  end

  def read(_), do: {:error, :invalid_path}

  # history:// 会话解析：capability（peer 求值上下文）优先，主节点 current 回退。
  # Host.call 不透传进程字典，故必须在调用方（peer 或主）先取出 token 再显式传 sid。
  defp read_history_scoped(query) do
    case history_session_id() do
      {:ok, sid} -> Newbee.Host.call(Newbee.Archive, :read_history_id, [sid, query])
      :error -> Newbee.Host.call(Newbee.Archive, :read_history, [query])
    end
  end

  defp history_session_id do
    with :error <- collaboration_session_id(),
         :error <- media_session_id() do
      :error
    else
      {:ok, _} = ok -> ok
    end
  end

  defp collaboration_session_id do
    case Process.get({Newbee.Tools.Collaboration, :context}) do
      %{capability: token} when is_binary(token) ->
        case Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [token]) do
          {:ok, %{session_id: sid}} when is_binary(sid) -> {:ok, sid}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp media_session_id do
    case Process.get({Newbee.Tools.Media, :capability}) do
      token when is_binary(token) ->
        case Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [token]) do
          {:ok, %{session_id: sid}} when is_binary(sid) -> {:ok, sid}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  可发现的 scheme 注册表（审计新增）：统一寻址有哪些协议、分别读什么。

  硬编码 cond 保留（热路径零分发开销），但对外提供机器可读清单，
  新 scheme 必须在此登记 + 补契约测试，避免“加了协议模型不知道”。
  """
  def schemes do
    [
      %{scheme: "bare", example: "mix.exs", reads: "file or directory"},
      %{scheme: "file://", example: "file://mix.exs", reads: "force file"},
      %{scheme: "tool://", example: "tool://Newbee.Tools.Fs", reads: "module docs with real signatures"},
      %{scheme: "rules://", example: "rules://", reads: "sleeping-rule list, substring filter"},
      %{scheme: "memory://", example: "memory://topic", reads: "global memory, empty key lists topics"},
      %{scheme: "bindings://", example: "bindings://", reads: "evaluator binding digest"},
      %{scheme: "history://", example: "history://", reads: "compacted archive index/segment search/file list"},
      %{scheme: "events://", example: "events://?n=50", reads: "event log, n clamped 1..1000"},
      %{scheme: "skill://", example: "skill://github_flow", reads: "skill snippet, dot-md suffix idempotent"},
      %{scheme: "agent://", example: "agent://id/findings", reads: "subagent structured results"},
      %{scheme: "conflict://", example: "conflict://", reads: "merge-conflict list/hunk views"},
      %{scheme: "https://", example: "https://example.com", reads: "public pages, private nets blocked"},
    ]
  end

  # ── 各实现 ──

  defp read_path(path) do
    if sensitive_path?(path) do
      {:ok,
       "[REDACTED: sensitive file — use Newbee.Host.safe_config/0 for model config or inspect env directly; raw content withheld]"}
    else
      cond do
        File.regular?(path) ->
          case File.read(path) do
            {:ok, body} when byte_size(body) <= 512 * 1024 ->
              {:ok, Newbee.Trust.envelope(body, "file:" <> path) |> Newbee.Trust.render()}

            {:ok, body} ->
              truncated =
                binary_part(body, 0, 512 * 1024) <>
                  "\n… [cut: #{byte_size(body)} bytes > 512KB, read in chunks via Fs] …\n"

              {:ok, Newbee.Trust.envelope(truncated, "file:" <> path) |> Newbee.Trust.render()}

            {:error, reason} ->
              {:error, reason}
          end

        File.dir?(path) ->
          {:ok, Newbee.Tools.Fs.ls(path) |> Enum.join("\n")}

        true ->
          {:error, :enoent}
      end
    end
  end

  @sensitive_re ~r/(model\.json|\.env|api[_-]?key|secret|token)/i
  defp sensitive_path?(path) do
    base = Path.basename(path)

    Regex.match?(@sensitive_re, base) or String.contains?(path, ".newbee/model.json") or
      String.contains?(path, ".newbee/config.json")
  end

  # skill://：技能片段（全局 ~/.newbee/skills 优先，再工程 .newbee/skills）
  # .md 后缀幂等：两种写法同解。
  defp read_skill(name) do
    base = String.replace_suffix(name, ".md", "")

    candidates = [
      Path.join([System.user_home!(), ".newbee", "skills", base <> ".md"]),
      Path.join([File.cwd!(), ".newbee", "skills", base <> ".md"])
    ]

    case Enum.find(candidates, &File.regular?/1) do
      nil -> {:error, :skill_not_found}
      f -> {:ok, Newbee.Trust.envelope(File.read!(f), "skill:" <> base) |> Newbee.Trust.render()}
    end
  end

  # agent://<id>/<path>：子代理结构化结果按路径抠字段（§3.8）
  defp read_agent(query) do
    case String.split(query, "/", parts: 2) do
      [id, path] ->
        file = Path.join([System.user_home!(), ".newbee", "agents", id, "result.json"])

        case File.read(file) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, value} ->
                case Newbee.Tools.Json.get(value, path) do
                  {:ok, v} -> {:ok, inspect(v, pretty: true, limit: 50)}
                  :error -> {:error, :path_not_found}
                end

              {:error, e} ->
                {:error, {:bad_json, e}}
            end

          _ ->
            {:error, :agent_not_found}
        end

      [id] ->
        read_agent(id <> "/findings")
    end
  end

  # conflict://：git 合并冲突。裸查询列冲突文件；带文件路径渲染冲突块视图
  defp read_conflict("") do
    case System.cmd("git", ["diff", "--name-only", "--diff-filter=U"], stderr_to_stdout: true) do
      {out, 0} ->
        files = out |> String.split("\n", trim: true)

        if files == [] do
          {:ok, "(no merge conflicts right now)"}
        else
          {:ok, Enum.map_join(files, "\n", &"conflict://#{&1}")}
        end

      _ ->
        {:ok, "(not a git repo or git unavailable)"}
    end
  end

  defp read_conflict(path) do
    case File.read(path) do
      {:ok, body} ->
        # 冲突块容错：缺分隔符不崩，直接跳过坏块。
        blocks =
          body
          |> String.split("<<<<<<<")
          |> Enum.drop(1)
          |> Enum.flat_map(fn chunk ->
            case String.split(chunk, "=======", parts: 2) do
              [ours, rest] ->
                case String.split(rest, ">>>>>>>", parts: 2) do
                  [theirs | _] -> ["@ours\n" <> ours <> "@theirs\n" <> theirs]
                  _ -> []
                end

              _ ->
                []
            end
          end)

        if blocks == [] do
          {:ok, "(" <> path <> " has no conflict hunks)"}
        else
          {:ok, Newbee.Trust.envelope(Enum.join(blocks, "\n"), "conflict:" <> path) |> Newbee.Trust.render()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # rules按子串过滤，经Host回主节点，peer同样可用。
  defp read_rules(query) do
    rules =
      try do
        Newbee.Host.call(Newbee.DEE.Rules, :list, [])
      rescue
        _ -> :unavailable
      catch
        _, _ -> :unavailable
      end

    case rules do
      :unavailable ->
        {:ok, "(rule service not started)"}
      [] ->
        {:ok, "(no sleeping rules)"}
      list when is_list(list) ->
        filtered =
          if query == "" do
            list
          else
            q = String.downcase(query)

            Enum.filter(list, fn r ->
              String.contains?(String.downcase(to_string(r.id) <> " " <> to_string(r.pattern)), q)
            end)
          end

        if filtered == [] do
          {:ok, "(no matching rules: " <> query <> "; read all via rules)"}
        else
          {:ok,
           Enum.map_join(filtered, "\n", fn r ->
             "[" <> to_string(r.id) <> "] /" <> to_string(r.pattern) <> "/ -> " <> to_string(r.injection)
           end)}
        end

      _ ->
        {:ok, "(rule service not started)"}
    end
  end

  defp read_memory("") do
    case Newbee.Memory.topics() do
      [] -> {:ok, "(no memory topics yet)"}
      topics -> {:ok, "Memory topics (read one via memory://<name>):\n" <> Enum.map_join(topics, "\n", fn t -> "  - memory://" <> t end)}
    end
  end

  defp read_memory(key) do
    case Newbee.Memory.read(key) do
      {:ok, content} -> {:ok, Newbee.Trust.envelope(content, "memory:" <> key) |> Newbee.Trust.render()}
      {:error, reason} -> {:error, reason}
    end
  end

  # bindings经Host回主节点，peer同样可用。
  defp read_bindings do
    summary =
      try do
        Newbee.Host.call(Newbee.DEE.Evaluator, :bindings_summary, [])
      rescue
        _ -> :unavailable
      catch
        _, _ -> :unavailable
      end

    cond do
      summary == :unavailable ->
        {:ok, "(evaluator not started)"}

      summary == [] ->
        {:ok, "(empty)"}

      is_list(summary) ->
        {:ok,
         Enum.map_join(summary, "\n", fn b ->
           to_string(b.name) <> " : " <> to_string(b.type) <> " (" <> to_string(b.size) <> " bytes)"
         end)}

      true ->
        {:ok, "(evaluator not started)"}
    end
  end

  defp read_events(query) do
    # n钳制1..1000：防长上下文退化（Lost in Middle），默认200。
    n =
      case Regex.run(~r/[?&]n=(\d+)/, query) do
        [_, s] -> s |> String.to_integer() |> min(1000) |> max(1)
        _ -> 200
      end

    # 优先项目 Event Store（唯一权威，§4.6）；无项目流时回退全局事件日志
    project_events = Newbee.EventStore.replay(Newbee.Environment.Store.path(:events)) |> Enum.take(-n)
    # 历史审计日志（跨会话/跨模型累积）：内容一律视为不可信参考，非当前任务上下文
    body =
      if project_events != [] do
        Enum.map_join(project_events, "\n", &event_line/1)
      else
        events = Newbee.EventLog.read(n)

        Enum.map_join(events, "\n", fn e ->
          session = event_session(e)

          "[#{e["topic"]}] #{if session, do: "session=#{session} ", else: ""}#{inspect(e["event"]) |> String.slice(0, 200)}"
        end)
      end

    {:ok, Newbee.Trust.envelope(body, "events://") |> Newbee.Trust.render()}
  end

  # 项目事件流行：带时间戳与可选会话标注
  defp event_line(e) do
    session = event_session(e.data)
    ts = e.at || ""

    "[#{e.topic}] ##{e.id} #{if session, do: "session=#{session} ", else: ""}@#{ts} #{inspect(e.data) |> String.slice(0, 180)}"
  end

  # 事件行里安全取 session_id：payload 可能是 map 或 {kind, map} 二元组，不能直接 get_in
  defp event_session(%{"session_id" => sid}) when is_binary(sid), do: sid
  defp event_session(%{"payload" => payload}) when is_map(payload), do: event_session(payload)
  defp event_session(%{"payload" => [_kind, payload]}) when is_map(payload), do: event_session(payload)
  defp event_session(%{"event" => event}) when is_map(event), do: event_session(event)
  defp event_session(_), do: nil

  # URL 读取走无凭证的公开 GET（Newbee.Tools.Http，§12 受控 transport 只服务
  # provider 凭证通道）；网页阅读不涉及凭证，不应被域名白名单限制。
  # URL 读取走无凭证的公开 GET；拦私网SSRF（OWASP），只放公开网页。
  # 注意：仅拦字面IP加常见内网名，DNS重绑定需出口代理根治，此处为纵深一层。
  defp read_url(url) do
    with {:ok, host} <- url_host(url),
         :ok <- ssrf_check(host) do
      case Newbee.Tools.Http.get(url) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          content = String.slice(body, 0, 512 * 1024)
          {:ok, Newbee.Trust.envelope(content, "url:" <> url) |> Newbee.Trust.render()}

        {:ok, %{status: status, body: body}} when is_binary(body) ->
          {:error, {:http, status, String.slice(body, 0, 300)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  defp url_host(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) and h != "" -> {:ok, String.downcase(h)}
      _ -> {:error, {:invalid_url, url}}
    end
  end

  defp ssrf_check(host) do
    cond do
      host in ["localhost", "ip6-localhost"] -> {:error, {:ssrf_blocked, host}}
      String.ends_with?(host, ".local") -> {:error, {:ssrf_blocked, host}}
      String.ends_with?(host, ".internal") -> {:error, {:ssrf_blocked, host}}
      String.ends_with?(host, ".lan") -> {:error, {:ssrf_blocked, host}}
      ssrf_private_ip?(host) -> {:error, {:ssrf_blocked, host}}
      true -> :ok
    end
  end

  defp ssrf_private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {0, 0, 0, 0}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 65535, _, _}} -> true
      {:ok, {65152, _, _, _, _, _, _, _}} -> true
      {:ok, {65280, _, _, _, _, _, _, _}} -> true
      {:ok, {h, _, _, _, _, _, _, _}} when h >= 64512 and h <= 65087 -> true
      _ -> false
    end
  end

  defp read_tool(module_name) do
    # 模块名归一：tool://Newbee.Tools.Edit → :"Elixir.Newbee.Tools.Edit"
    module =
      case module_name do
        "Elixir." <> _ -> String.to_atom(module_name)
        _ -> String.to_atom("Elixir." <> module_name)
      end

    if Code.ensure_loaded?(module) do
      docs =
        case Code.fetch_docs(module) do
          {:docs_v1, _, _, _, module_doc, _, func_docs} -> {module_doc, func_docs}
          _ -> {nil, []}
        end

      {module_doc, func_docs} = docs

      # docs_v1 外层：{annotation, beam_lang, format, module_doc, metadata, docs}
      # 函数元组：{{kind, name, arity}, annotation, signature, doc, metadata}
      # 文档值在 Elixir ≥1.15 是 `%{"en" => text}` 语言分键 map，旧版才是裸 binary；
      # 只认 binary 会把所有函数 @doc 渲染成空串（模型从此对工具 API 一无所知，
      # 只能瞎猜函数名，如 Fs.write 猜成 write_file）。
      moduledoc = module_tool_doc(doc_text(module_doc))

      funcs =
        func_docs
        |> Enum.filter(fn
          {{:function, name, _arity}, _, _, doc, _} when name not in [:__info__, :module_info] ->
            doc_text(doc) != ""

          _ ->
            false
        end)
        |> Enum.map_join("\n", fn {{:function, name, arity}, _, signatures, doc, _} ->
          signature =
            case signatures do
              [sig | _] when is_binary(sig) -> sig
              _ -> "#{name}/#{arity}"
            end

          "  - `#{signature}` — " <> String.slice(first_paragraph(doc_text(doc)), 0, 500)
        end)

      {:ok, "## #{module_name}\n" <> moduledoc <> "\n\n## Real function signatures\n" <> funcs}
    else
      {:error, :module_not_loaded}
    end
  rescue
    _ -> {:error, :module_not_found}
  end

  # 函数签名由 Code.fetch_docs 自动生成；tool:// 视图移除模块文档中的手写清单，
  # 避免同一 API 在模型上下文中出现两遍。源码和 ExDoc 仍保留完整清单。
  defp module_tool_doc(doc) do
    doc
    |> String.replace(~r/\n\s*## (函数清单|Functions).*?(?=\n\s*## |\z)/s, "")
    |> String.trim()
  end

  defp first_paragraph(doc) do
    doc
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> hd()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # docs_v1 文档值统一提文本：language-keyed map（%{"en" => …}）、{format, text} 元组、
  # 裸 binary 都收；:none/缺文档 → ""。
  defp doc_text(%{"en" => text}) when is_binary(text), do: text
  defp doc_text(%{"zh" => text}) when is_binary(text), do: text
  defp doc_text({_format, text}) when is_binary(text), do: text
  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_), do: ""
end
