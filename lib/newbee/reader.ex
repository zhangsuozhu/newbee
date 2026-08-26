defmodule Newbee do
  @moduledoc """
  统一寻址读取 (DESIGN §3.2)：`Newbee.read/1` 通吃文件、目录、URL 与内部 scheme。
  只教模型一个接口。

  scheme 一览:
    - 裸路径        → 文件或目录
    - `file://`     → 文件
    - `tool://M`    → 模块文档（@moduledoc + 公开函数 @doc）
    - `rules://`    → 沉睡规则清单
    - `memory://k`  → 全局记忆条目
    - `bindings://` → 求值器绑定摘要
    - `history://`  → 本会话压缩档案（索引 / `s/<段>` 摘要 / `s/<段>/raw` 原文 /
                 `q/<关键词>` 全文检索 / `files` 文件清单）——被压缩的对话随时可拉回
    - `events://`   → 事件日志（可选 ?n= 条数）
    - `skill://n`   → 技能片段（~/.newbee/skills 或工程 .newbee/skills）
    - `agent://<id>/<path>` → 子代理结果按路径抠字段
    - `conflict://` → git 合并冲突清单；`conflict://<file>` 冲突块视图
    - `http(s)://`  → 网页（Req 拉取）
  """

  @doc """
  统一读取。返回 {:ok, content} | {:error, reason}。

    - 目录 → 一层列表（目录名带 / 后缀）
    - 文件 → 文本内容（≤512KB，超出截断并标注）
    - URL → 网页文本
    - 内部 scheme → 见 @moduledoc
  """
  def read(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "tool://") ->
        read_tool(String.trim_leading(path, "tool://"))

      path == "rules://" or String.starts_with?(path, "rules://") ->
        read_rules()

      String.starts_with?(path, "memory://") ->
        read_memory(String.trim_leading(path, "memory://"))

      String.starts_with?(path, "skill://") ->
        read_skill(String.trim_leading(path, "skill://"))

      String.starts_with?(path, "agent://") ->
        read_agent(String.trim_leading(path, "agent://"))

      path == "conflict://" or String.starts_with?(path, "conflict://") ->
        read_conflict(String.trim_leading(path, "conflict://"))

      path == "bindings://" ->
        read_bindings()

      # history:// 经 Host.call 回主节点执行：peer 求值节点上的模型代码同样可用
      path == "history://" or String.starts_with?(path, "history://") ->
        Newbee.Host.call(Newbee.Archive, :read_history, [String.trim_leading(path, "history://")])

      String.starts_with?(path, "events://") ->
        read_events(String.trim_leading(path, "events://"))

      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        read_url(path)

      String.starts_with?(path, "file://") ->
        read_path(String.trim_leading(path, "file://"))

      true ->
        read_path(path)
    end
  end

  def read(_), do: {:error, :invalid_path}

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
                  "\n… [截断: #{byte_size(body)} bytes > 512KB，用 Fs 分段读取] …\n"

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
  defp read_skill(name) do
    candidates = [
      Path.join([System.user_home!(), ".newbee", "skills", name <> ".md"]),
      Path.join([File.cwd!(), ".newbee", "skills", name <> ".md"])
    ]

    case Enum.find(candidates, &File.regular?/1) do
      nil -> {:error, :skill_not_found}
      path -> {:ok, File.read!(path)}
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
          {:ok, "（当前无合并冲突）"}
        else
          {:ok, Enum.map_join(files, "\n", &"conflict://#{&1}")}
        end

      _ ->
        {:ok, "（非 git 仓库或 git 不可用）"}
    end
  end

  defp read_conflict(path) do
    case File.read(path) do
      {:ok, body} ->
        # 冲突块：<<<<<<< ours / ======= / >>>>>>> theirs
        blocks =
          body
          |> String.split("<<<<<<<")
          |> Enum.drop(1)
          |> Enum.map(fn chunk ->
            [ours, rest] = String.split(chunk, "=======", parts: 2)
            [theirs | _] = String.split(rest, ">>>>>>>", parts: 2)
            "┌─ @ours\n" <> ours <> "└─ @theirs\n" <> theirs
          end)

        if blocks == [] do
          {:ok, "（#{path} 无冲突块）"}
        else
          {:ok, Enum.join(blocks, "\n")}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_rules do
    if Process.whereis(Newbee.DEE.Rules) do
      case Newbee.DEE.Rules.list() do
        [] -> {:ok, "（无沉睡规则）"}
        rules -> {:ok, Enum.map_join(rules, "\n", &"[#{&1.id}] /#{&1.pattern}/ → #{&1.injection}")}
      end
    else
      {:ok, "（规则服务未启动）"}
    end
  end

  defp read_memory(key) do
    case Newbee.Memory.read(key) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_bindings do
    if Process.whereis(Newbee.DEE.Evaluator) do
      case Newbee.DEE.Evaluator.bindings_summary() do
        [] -> {:ok, "（空）"}
        bs -> {:ok, Enum.map_join(bs, "\n", &"#{&1.name} : #{&1.type} (#{&1.size} bytes)")}
      end
    else
      {:ok, "（求值器未启动）"}
    end
  end

  defp read_events(query) do
    n =
      case Regex.run(~r/[?&]n=(\d+)/, query) do
        [_, n] -> String.to_integer(n)
        _ -> 200
      end

    # 优先项目 Event Store（唯一权威，§4.6）；无项目流时回退全局事件日志
    project_events = Newbee.EventStore.replay(Newbee.Environment.Store.path(:events)) |> Enum.take(-n)

    if project_events != [] do
      {:ok, Enum.map_join(project_events, "\n", &"[#{&1.topic}] ##{&1.id} #{inspect(&1.data) |> String.slice(0, 200)}")}
    else
      events = Newbee.EventLog.read(n)
      {:ok, Enum.map_join(events, "\n", &"[#{&1["topic"]}] #{inspect(&1["event"]) |> String.slice(0, 200)}")}
    end
  end

  # URL 读取经受控 transport（§12：域名白名单 + Host 执行网络）+ trust envelope
  defp read_url(url) do
    case Newbee.Host.Shell.execute_request_plan(%{url: url, method: "get", headers: [], body: nil}) do
      {:ok, body} when is_binary(body) ->
        content = String.slice(body, 0, 512 * 1024)
        {:ok, Newbee.Trust.envelope(content, "url:" <> url) |> Newbee.Trust.render()}

      {:ok, body} ->
        {:ok, Newbee.Trust.envelope(inspect(body), "url:" <> url) |> Newbee.Trust.render()}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :fetch_failed}
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
      moduledoc = doc_text(module_doc)

      funcs =
        func_docs
        |> Enum.filter(fn
          {{:function, name, _arity}, _, _, doc, _} when name not in [:__info__, :module_info] ->
            doc_text(doc) != ""

          _ ->
            false
        end)
        |> Enum.map_join("\n", fn {{:function, name, arity}, _, _, doc, _} ->
          "  #{name}/#{arity}: #{String.slice(doc_text(doc), 0, 800)}"
        end)

      {:ok, "## #{module_name}\n" <> moduledoc <> "\n" <> funcs}
    else
      {:error, :module_not_loaded}
    end
  rescue
    _ -> {:error, :module_not_found}
  end

  # docs_v1 文档值统一提文本：language-keyed map（%{"en" => …}）、{format, text} 元组、
  # 裸 binary 都收；:none/缺文档 → ""。
  defp doc_text(%{"en" => text}) when is_binary(text), do: text
  defp doc_text(%{"zh" => text}) when is_binary(text), do: text
  defp doc_text({_format, text}) when is_binary(text), do: text
  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_), do: ""
end
