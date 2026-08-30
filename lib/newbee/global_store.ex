defmodule Newbee.GlobalStore do
  @moduledoc """
  Global Store（DESIGN §11.2 / §14）：`~/.newbee` —— 跨项目默认与经验，
  **不权威**。项目 `.newbee` 才是当前项目 active 环境唯一来源。

  ```text
  ~/.newbee/
  ├── plugins/              # 全局 release（git 版本化）
  ├── bundles/              # 基因库：声明式组合包 + fitness + 出处
  ├── memory/               # 全局记忆（脱敏）
  ├── events.log            # 全局事件流
  └── sessions/             # transcript
  ```

  规则（§11.3）：
  - 项目插件显式 override 全局插件，必须不同 plugin_id 版本记录；
  - 全局经验进项目前必须过项目 adapter 兼容性检查；
  - 项目反馈默认不污染全局，跨项目验证后晋升（Ring 1 门槛）。
  """

  alias Newbee.Environment.{Coordinator, Fitness}
  @test_env Mix.env() == :test

  @doc "全局根目录。测试默认落到独立临时目录，也可用 :global_root_override 显式覆盖。"
  def root do
    case Application.get_env(:newbee, :global_root_override) do
      path when is_binary(path) -> path
      _ -> default_root()
    end
  end

  defp default_root do
    if @test_env do
      Application.get_env(:newbee, :test_global_root) || create_test_root()
    else
      Path.join(System.user_home!(), ".newbee")
    end
  end

  defp create_test_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "newbee-test-global-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:newbee, :test_global_root, root)
    root
  end

  def dir(:bundles), do: Path.join(root(), "bundles")
  def dir(:plugins), do: Path.join(root(), "plugins")
  def dir(:memory), do: Path.join(root(), "memory")

  # ── 基因库 bundle（§14：L3 工具+规则+prompt 打成 bundle 带 fitness 跨用户分享）──

  @doc """
  导出项目环境为 bundle：收集指定 plugin 的 active release + fitness + 出处。
  """
  def export_bundle(name, plugin_ids, opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Newbee.Environment.Coordinator)

    active =
      if Process.whereis(coordinator) do
        Coordinator.current(coordinator).active
      else
        %{}
      end

    releases =
      plugin_ids
      |> Enum.flat_map(fn pid ->
        case active[pid] do
          nil -> []
          release_id ->
            case Newbee.Environment.PluginManager.fetch_or_builtin(release_id) do
              {:ok, r} -> [%{release: Newbee.Environment.Release.to_map(r), fitness: Fitness.overall(release_id)}]
              _ -> []
            end
        end
      end)

    bundle = %{
      "name" => name,
      "version" => Keyword.get(opts, :version, "1.0.0"),
      "provenance" => %{"project" => File.cwd!(), "exported_by" => "newbee"},
      "releases" => releases,
      "exported_at" => now_iso()
    }

    dir = dir(:bundles)
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{safe(name)}-#{bundle["version"]}.json")
    File.write!(path, Jason.encode_to_iodata!(bundle, pretty: true))
    {:ok, path}
  end

  @doc "列出全局 bundle。"
  def bundles do
    dir(:bundles)
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, b} -> [Map.put(b, "path", f)]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @doc """
  安装 bundle 到当前项目：**全局经验进项目前必须过项目 adapter 兼容性检查**
  （Ring 1 门槛）——每个 release 走标准 Change 生命周期（manual 默认需批准）。
  """
  def install_bundle(path, opts \\ []) do
    coordinator = Keyword.get(opts, :coordinator, Newbee.Environment.Coordinator)

    with {:ok, body} <- File.read(path),
         {:ok, bundle} <- Jason.decode(body) do
      results =
        Enum.map(bundle["releases"] || [], fn %{"release" => rmap} ->
          release = Newbee.Environment.Release.from_map(rmap)

          case compatibility_check(release) do
            :ok ->
              case Coordinator.propose_change(coordinator, %{
                     reason: "install bundle #{bundle["name"]}: #{release.plugin_id}",
                     evidence: [%{bundle: bundle["name"], provenance: bundle["provenance"]}],
                     author_agent: :adapter
                   }) do
                {:ok, change} ->
                  case Coordinator.candidate_ready(coordinator, change.change_id, release_attrs(release), opts) do
                    {:ok, _} -> {:ok, change.change_id}
                    {:error, reason} -> {:error, reason}
                  end

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, {:incompatible, release.plugin_id, reason}}
          end
        end)

      {:ok, results}
    end
  end

  # 兼容性检查：contract 校验 + 依赖可在当前环境解析
  defp compatibility_check(release) do
    case Newbee.Environment.PluginManager.static_validate(release) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_attrs(release) do
    %{
      plugin_id: release.plugin_id,
      kind: release.kind,
      source_files: release.source_files,
      dependencies: release.dependencies,
      usage: release.usage,
      capabilities: release.capabilities,
      state_policy: release.state_policy
    }
  end

  # ── 全局记忆（脱敏）──

  @doc "全局记忆读（自动脱敏剥离密钥，§5 记忆/状态）。"
  def memory_read(topic) do
    path = Path.join(dir(:memory), safe(topic) <> ".md")

    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "全局记忆写（写前脱敏）。"
  def memory_write(topic, content) do
    File.mkdir_p!(dir(:memory))
    File.write!(Path.join(dir(:memory), safe(topic) <> ".md"), redact(content))
    :ok
  end

  @doc "topic 索引（§9.5 记忆分片）。"
  def memory_topics do
    dir(:memory)
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".md"))
  end

  defp redact(content) do
    Regex.replace(~r/(sk-[A-Za-z0-9_\-]{8,}|Bearer\s+\S+)/, content, "[REDACTED]")
  end

  defp safe(id), do: id |> to_string() |> String.replace(~r/[^\w\.\-]/, "_")

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
