defmodule Newbee.Plugins do
  @moduledoc """
  内置插件 Registry（DESIGN §5 / §13）：环境能力面全部以内置 Plugin 承载。

  每个内置能力是 `kind: tool | workflow | projection` 的 builtin release：
  - plugin_id 稳定逻辑身份（`tool.fs`、`workflow.jspace`、`projection.repomap`…）；
  - 内容寻址用模块 md5（beam 变化 = 新 release）；
  - 与源码 release 走**同一** Change 生命周期——可评价、可回退、可进化；
  - 模型侧的渐进式披露（§9.4/§9.12）：一行签名清单，按需 Newbee.read 取全文。
  """

  alias Newbee.Environment.Release

  @builtin_modules [
    # kind, plugin_id, module, capabilities
    {:tool, "tool.fs", Newbee.Tools.Fs, [:fs]},
    {:tool, "tool.edit", Newbee.Tools.Edit, [:fs]},
    {:tool, "tool.structural", Newbee.Tools.Structural, [:fs]},
    {:tool, "tool.run", Newbee.Tools.Run, [:shell]},
    {:tool, "tool.git", Newbee.Tools.Git, [:shell, :fs]},
    {:tool, "tool.search", Newbee.Tools.Search, [:fs]},
    {:tool, "tool.json", Newbee.Tools.Json, []},
    {:tool, "tool.http", Newbee.Tools.Http, [:net]},
    {:tool, "tool.scaffold", Newbee.Tools.Scaffold, [:shell, :fs]},
    {:tool, "tool.introspect", Newbee.Tools.Introspect, []},
    {:tool, "tool.hotreload", Newbee.Tools.HotReload, []},
    {:tool, "tool.collaboration", Newbee.Tools.Collaboration, []},
    {:workflow, "workflow.jspace", Newbee.Tools.JSpace, [:fs]},
    {:projection, "projection.repomap", Newbee.Plugins.RepoMap, [:fs]},
    {:provider, "provider.openrouter", Newbee.Plugins.Provider.OpenRouter, [:net]}
  ]

  @doc "全部内置插件 release（内容寻址：模块 md5）。"
  def builtins do
    for {kind, plugin_id, mod, capabilities} <- @builtin_modules do
      Release.new(
        plugin_id: plugin_id,
        kind: kind,
        source_files: %{},
        source_hash: module_md5(mod),
        usage: summary(mod),
        capabilities: capabilities,
        author: :system,
        created_at: app_built_at()
      )
    end
  end

  @doc "按 plugin_id 找内置 release。"
  def builtin(plugin_id) do
    Enum.find(builtins(), &(&1.plugin_id == plugin_id))
  end

  @doc "全部内置 release 的初始 active 图（%{plugin_id => release_id}）。"
  def builtin_active_map do
    Map.new(builtins(), &{&1.plugin_id, &1.release_id})
  end

  @doc "按 plugin_id 找 builtin 模块。"
  def module_for_plugin_id(plugin_id) when is_binary(plugin_id) do
    case Enum.find(@builtin_modules, fn {_kind, id, _module, _caps} -> id == plugin_id end) do
      {_kind, _id, module, _caps} -> module
      nil -> nil
    end
  end

  @doc "按模块找 plugin_id。"
  def plugin_id_for(mod) do
    case Enum.find(@builtin_modules, fn {_k, _id, m, _c} -> m == mod end) do
      {_k, id, _m, _c} -> id
      nil -> nil
    end
  end

  @doc "模块清单：[%{plugin_id, name, kind, summary, builtin?}]（投影用）。"
  def list do
    Enum.map(@builtin_modules, fn {kind, plugin_id, mod, _caps} ->
      %{plugin_id: plugin_id, name: inspect(mod), kind: kind, summary: summary(mod), builtin?: true}
    end)
  end

  @doc "单个插件签名描述。"
  def describe(name) when is_binary(name) do
    mod = module_for(name)

    if mod do
      %{name: inspect(mod), plugin_id: plugin_id_for(mod), summary: summary(mod)}
    else
      nil
    end
  end

  def module_for(name) when is_binary(name) do
    name = String.trim_leading(name, "Elixir.")

    Enum.find_value(@builtin_modules, fn {_k, _id, mod, _c} ->
      short = mod |> Module.split() |> List.last()
      full = inspect(mod) |> String.trim_leading("Elixir.")
      if name in [short, full], do: mod
    end)
  end

  @doc "prompt 注入用的一行能力索引（tool/workflow/projection/provider；价签由 Fitness 补充）。"
  def prompt_section(tags \\ %{}) do
    list()
    |> Enum.map_join("\n", fn t ->
      tag = Map.get(tags, t.plugin_id)
      price = if tag, do: " " <> tag, else: ""
      "  - #{t.name}#{price}: #{t.summary}"
    end)
    |> case do
      "" -> ""
      body -> "\n## 能力索引（每项一行；按需 Newbee.read(\"tool://模块名\") 取全文）\n" <> body <> "\n"
    end
  end

  defp module_md5(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        Base.encode16(mod.module_info(:md5), case: :lower)

      _ ->
        "builtin"
    end
  rescue
    _ -> "builtin"
  end

  defp summary(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        doc |> String.split("\n") |> hd() |> String.trim() |> String.slice(0, 120)

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp app_built_at do
    # builtin release 的"创建时间"用应用编译时间近似；内容寻址由 md5 保证
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
