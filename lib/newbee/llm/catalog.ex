defmodule Newbee.LLM.Catalog do
  @moduledoc "Versioned provider → credential group → model catalog and legacy runtime adapter."
  @overrides %{
    "api" => "modelApis",
    "contextWindow" => "contextWindows",
    "capabilities" => "modelCapabilities",
    "responsesContinuation" => "modelResponsesContinuations"
  }
  @legacy_fields ~w(apiKey models modelApis contextWindows modelCapabilities modelResponsesContinuations)

  def route(provider, "default"), do: provider
  def route(provider, group), do: provider <> "~" <> group

  @doc "Whether a catalog model uses Jev's structured scoring protocol."
  def jev_model?(model, provider \\ %{}) do
    model["kind"] == "jev" or (model["api"] || provider["api"]) == "typesafe-systemone" or
      known_legacy_jev?(model, provider)
  end

  @doc "Chat eligibility in the compatibility runtime view; also recognizes legacy protocol maps."
  def chat_model?(provider, model) do
    not known_legacy_jev?(
      %{
        "id" => model,
        "kind" => get_in(provider, ["modelKinds", model]),
        "api" => get_in(provider, ["modelApis", model])
      },
      provider
    ) and
      get_in(provider, ["modelKinds", model]) != "jev" and
      (get_in(provider, ["modelApis", model]) || provider["api"]) != "typesafe-systemone"
  end

  @doc "Resolve a Jev reference to non-secret connection metadata."
  def jev_connection(cfg, %{"provider" => pid, "group" => gid, "model" => id})
      when is_binary(pid) and is_binary(gid) and is_binary(id) do
    cfg = cfg |> persist() |> migrate()

    with p when is_map(p) <- get_in(cfg, ["providers", pid]),
         g when is_map(g) <- get_in(p, ["groups", gid]),
         m when is_map(m) <- Enum.find(g["models"] || [], &(&1["id"] == id)),
         true <- jev_model?(m, p),
         "typesafe-systemone" <- m["api"] || p["api"],
         base when is_binary(base) <- p["baseUrl"] do
      uri = URI.parse(base)

      if uri.scheme in ["https", "http"] and is_binary(uri.host) and
           is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
        endpoint = String.trim_trailing(base, "/")

        endpoint =
          cond do
            String.ends_with?(endpoint, "/systemone") -> endpoint
            uri.path in [nil, "", "/"] -> endpoint <> "/v1/systemone"
            true -> endpoint <> "/systemone"
          end

        {:ok, %{endpoint: endpoint, model: id, api_key_provider: route(pid, gid)}}
      else
        {:error, :invalid_jev_endpoint}
      end
    else
      _ -> {:error, :invalid_jev_model_ref}
    end
  end

  def jev_connection(_, _), do: {:error, :invalid_jev_model_ref}

  def migrate(%{"schemaVersion" => 2} = cfg), do: cfg |> normalize_booleans() |> normalize_legacy_jev()

  def migrate(cfg) do
    providers =
      Map.new(cfg["providers"] || %{}, fn {id, p} ->
        used = for {_role, r} <- cfg["roles"] || %{}, r["provider"] == id, is_binary(r["model"]), do: r["model"]

        overridden = Enum.flat_map(@overrides, fn {_field, table} -> Map.keys(p[table] || %{}) end)

        models =
          Enum.map(Enum.uniq((p["models"] || []) ++ used ++ overridden), fn model ->
            Enum.reduce(@overrides, %{"id" => model, "name" => model}, fn {field, table}, acc ->
              case get_in(p, [table, model]) do
                nil -> acc
                value -> Map.put(acc, field, value)
              end
            end)
          end)

        group = %{"name" => "默认分组", "apiKey" => p["apiKey"], "models" => models}

        {id,
         p
         |> Map.drop(@legacy_fields)
         |> Map.put("name", p["name"] || id)
         |> Map.put("groups", %{"default" => group})}
      end)

    roles = Map.new(cfg["roles"] || %{}, fn {role, r} -> {role, Map.put(r, "group", "default")} end)

    cfg
    |> Map.put("schemaVersion", 2)
    |> Map.put("providers", providers)
    |> Map.put("roles", roles)
    |> normalize_booleans()
    |> normalize_legacy_jev()
  end

  # Older catalogs listed the official Jev model as OpenAI-compatible. Recognize
  # only the known TypeSafe host/model family; never guess from a display name.
  defp known_legacy_jev?(model, provider) do
    is_nil(model["kind"]) and is_binary(model["id"]) and
      String.starts_with?(model["id"], "jev-") and
      (model["api"] || provider["api"]) in [nil, "chat", "openai-completions", "auto"] and
      URI.parse(provider["baseUrl"] || "").host == "api.typesafe.ai"
  end

  defp normalize_legacy_jev(cfg) do
    update_in(cfg, ["providers"], fn providers ->
      Map.new(providers, fn {pid, p} ->
        groups =
          Map.new(p["groups"], fn {gid, g} ->
            models =
              Enum.map(g["models"] || [], fn m ->
                if known_legacy_jev?(m, p), do: Map.merge(m, %{"kind" => "jev", "api" => "typesafe-systemone"}), else: m
              end)

            {gid, Map.put(g, "models", models)}
          end)

        {pid, Map.put(p, "groups", groups)}
      end)
    end)
  end

  # Existing sessions, Host credential lookup and CLI use an opaque provider route.
  # Default groups keep the original route, including existing session histories.
  def runtime(%{"schemaVersion" => 2} = cfg) do
    providers =
      for {pid, p} <- cfg["providers"], {gid, g} <- p["groups"], into: %{} do
        models = g["models"] || []

        flat =
          p
          |> Map.drop(["groups", "name"])
          |> Map.merge(Map.drop(g, ["models", "name"]))
          |> Map.put("models", Enum.map(models, & &1["id"]))
          |> Map.put("modelKinds", Map.new(models, &{&1["id"], if(jev_model?(&1, p), do: "jev", else: "chat")}))
          |> Map.put("catalogProvider", pid)
          |> Map.put("catalogGroup", gid)
          |> Map.put("displayName", (p["name"] || pid) <> " / " <> (g["name"] || gid))
          |> Map.put("modelNames", Map.new(models, &{&1["id"], &1["name"] || &1["id"]}))

        flat =
          Enum.reduce(@overrides, flat, fn {field, table}, acc ->
            values = for m <- models, Map.has_key?(m, field), into: %{}, do: {m["id"], m[field]}
            Map.put(acc, table, values)
          end)

        {route(pid, gid), flat}
      end

    roles =
      Map.new(cfg["roles"] || %{}, fn {role, r} ->
        {role, r |> Map.put("provider", route(r["provider"], r["group"] || "default")) |> Map.delete("group")}
      end)

    cfg |> Map.put("providers", providers) |> Map.put("roles", roles) |> Map.put("__catalog", cfg)
  end

  def runtime(cfg), do: cfg

  # Fold legacy runtime mutations (default model / context window) back into v2.
  def persist(%{"__catalog" => catalog} = cfg) do
    providers =
      Map.new(catalog["providers"], fn {pid, p} ->
        groups =
          Map.new(p["groups"], fn {gid, g} ->
            flat = cfg["providers"][route(pid, gid)]

            models =
              Enum.map(g["models"], fn m ->
                Enum.reduce(@overrides, m, fn {field, table}, acc ->
                  case get_in(flat || %{}, [table, m["id"]]) do
                    nil -> Map.delete(acc, field)
                    value -> Map.put(acc, field, value)
                  end
                end)
              end)

            {gid, Map.put(g, "models", models)}
          end)

        {pid, Map.put(p, "groups", groups)}
      end)

    routes = for {pid, p} <- providers, {gid, _} <- p["groups"], into: %{}, do: {route(pid, gid), {pid, gid}}

    roles =
      Map.new(cfg["roles"] || %{}, fn {role, r} ->
        {pid, gid} = Map.fetch!(routes, r["provider"])
        {role, r |> Map.put("provider", pid) |> Map.put("group", gid)}
      end)

    catalog |> Map.put("providers", providers) |> Map.put("roles", roles)
  end

  def persist(cfg), do: cfg

  def redact(cfg) do
    update_in(cfg, ["providers"], fn providers ->
      Map.new(providers, fn {pid, p} ->
        groups =
          Map.new(p["groups"], fn {gid, g} ->
            {gid, g |> Map.put("keyConfigured", is_binary(g["apiKey"]) and g["apiKey"] != "") |> Map.put("apiKey", nil)}
          end)

        {pid, Map.put(p, "groups", groups)}
      end)
    end)
  end

  def revision(cfg), do: :crypto.hash(:sha256, :erlang.term_to_binary(cfg)) |> Base.encode16(case: :lower)

  def prepare(input, previous) do
    try do
      input = normalize_booleans(input)
      require!(is_map(input) and input["schemaVersion"] == 2, "配置版本必须为 2")
      require!(is_map(input["providers"]), "厂家必须为对象")

      providers =
        Map.new(input["providers"], fn {pid, p} ->
          identifier!(pid)
          require!(is_map(p), "厂家配置必须为对象")
          require!(is_binary(p["baseUrl"]), "厂家 URL 必须为字符串")
          require!(not Map.has_key?(p, "apiKey"), "API Key 必须配置在分组中")
          require!(is_nil(p["name"]) or is_binary(p["name"]), "厂家显示名称必须为字符串")
          url = URI.parse(p["baseUrl"])

          require!(
            url.scheme in ["http", "https"] and is_binary(url.host) and url.host != "" and is_nil(url.userinfo) and
              is_nil(url.query) and is_nil(url.fragment),
            "厂家 URL 必须是完整的 HTTP(S) API 根地址"
          )

          require!(is_map(p["groups"]), "厂家必须包含分组对象")
          protocol!(p["api"])

          groups =
            Map.new(p["groups"], fn {gid, g} ->
              identifier!(gid)
              require!(is_map(g), "分组必须为对象")
              require!(not Map.has_key?(g, "baseUrl"), "接入地址必须配置在厂家中")
              require!(is_nil(g["name"]) or is_binary(g["name"]), "分组显示名称必须为字符串")
              old = get_in(previous, ["providers", pid, "groups", gid]) || %{}
              key = g["apiKey"] || old["apiKey"]

              require!(
                is_binary(key) and String.trim(key) != "" and not String.contains?(key, "•"),
                "每个分组必须配置 API Key（可使用环境变量引用）"
              )

              require!(is_list(g["models"]), "模型必须为列表")

              ids =
                Enum.map(g["models"], fn m ->
                  require!(is_map(m), "模型必须为对象")
                  require!(is_binary(m["id"]) and String.trim(m["id"]) != "", "模型 ID 不能为空")
                  require!(is_nil(m["name"]) or is_binary(m["name"]), "模型显示名称必须为字符串")
                  protocol!(m["api"])
                  require!(m["kind"] in [nil, "chat", "jev"], "未知模型类型")

                  if jev_model?(m, p) do
                    require!(
                      (m["api"] || p["api"]) == "typesafe-systemone" and m["kind"] != "chat",
                      "Jev 模型必须使用 TypeSafe SystemOne 接口"
                    )
                  end

                  n = m["contextWindow"]
                  require!(is_nil(n) or (is_integer(n) and n > 0), "上下文窗口必须为正整数或留空")
                  require!(is_nil(m["capabilities"]) or is_map(m["capabilities"]), "模型能力必须为对象")
                  caps = m["capabilities"] || %{}

                  Enum.each(~w(imageMaxBytes maxImagesPerRequest maxRequestImageBytes), fn field ->
                    require!(is_nil(caps[field]) or (is_integer(caps[field]) and caps[field] > 0), "图片限制必须为正整数")
                  end)

                  require!(
                    is_nil(m["responsesContinuation"]) or is_boolean(m["responsesContinuation"]),
                    "Responses 续接必须为布尔值"
                  )

                  m["id"]
                end)

              require!(length(ids) == length(Enum.uniq(ids)), "同一分组的模型 ID 不能重复")
              {gid, g |> Map.delete("keyConfigured") |> Map.put("apiKey", key)}
            end)

          {pid, Map.put(p, "groups", groups)}
        end)

      roles = input["roles"] || %{}
      require!(is_map(roles), "角色必须为对象")

      Enum.each(roles, fn {_role, r} ->
        require!(is_map(r), "角色绑定必须为对象")
        group = get_in(providers, [r["provider"], "groups", r["group"] || "default"])

        require!(
          is_map(group) and
            Enum.any?(group["models"], &(&1["id"] == r["model"] and not jev_model?(&1, providers[r["provider"]]))),
          "聊天角色必须绑定存在的对话模型，不能使用 Jev 评分模型"
        )
      end)

      validate_compaction!(input["compaction"], input |> Map.put("providers", providers))
      require!(Map.has_key?(roles, "default"), "请绑定默认角色后保存")
      {:ok, input |> Map.delete("__catalog") |> Map.put("providers", providers) |> Map.put("roles", roles)}
    catch
      {:invalid, message} -> {:error, message}
    end
  end

  defp validate_compaction!(nil, _cfg), do: :ok

  defp validate_compaction!(raw, cfg) do
    case Newbee.Compaction.Config.resolve(raw) do
      {:ok, parsed} ->
        if parsed[:model_ref] do
          require!(match?({:ok, _}, jev_connection(cfg, parsed.model_ref)), "压缩用途必须绑定存在的 Jev 模型")
        end

      {:error, reason} ->
        throw({:invalid, compaction_error(reason)})
    end
  end

  defp compaction_error(:state_tokens_not_below_request), do: "状态预算必须小于请求预算"
  defp compaction_error(:request_timeout_exceeds_total), do: "单次超时不能超过总超时"
  defp compaction_error(:plaintext_api_key), do: "请将 API Key 配置在厂家分组中，压缩参数不接受明文密钥"

  defp compaction_error({:invalid_field, field}) do
    Map.get(
      %{
        max_state_tokens: "状态预算必须为 1 K–25 K token",
        max_request_tokens: "请求预算必须为 2 K–30 K token",
        keep_threshold: "保留阈值必须在 0–1 之间",
        preserve_recent_messages: "最近消息保留数必须为 2–64 的整数",
        request_timeout_ms: "单次超时必须为 100–10,000 毫秒",
        total_timeout_ms: "总超时必须为 100–20,000 毫秒",
        model_ref: "请选择有效的 Jev 厂家、分组和模型"
      },
      field,
      "Jev 参数无效，请检查评分配置"
    )
  end

  defp compaction_error(_), do: "压缩配置无效，请检查压缩方式和评分参数"

  # Legacy endpoints may encode boolean settings as text; canonical files and RPCs use booleans.
  defp boolean("true"), do: true
  defp boolean("false"), do: false
  defp boolean(value), do: value

  defp normalize_booleans(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in ["responsesContinuation", "vision"] ->
        {key, boolean(value)}

      {"modelResponsesContinuations", values} when is_map(values) ->
        {"modelResponsesContinuations", Map.new(values, fn {id, v} -> {id, boolean(v)} end)}

      {key, value} ->
        {key, normalize_booleans(value)}
    end)
  end

  defp normalize_booleans(list) when is_list(list), do: Enum.map(list, &normalize_booleans/1)
  defp normalize_booleans(value), do: value

  defp identifier!(id), do: require!(is_binary(id) and Regex.match?(~r/^[^\s\/~]+$/u, id), "厂家和分组 ID 不能为空，不能包含空白、/ 或 ~")

  defp protocol!(api),
    do:
      require!(
        api in [
          nil,
          "auto",
          "openai-completions",
          "openai-responses",
          "anthropic",
          "chat",
          "responses",
          "anthropic-messages",
          "typesafe-systemone"
        ],
        "不支持的接口类型"
      )

  defp require!(true, _message), do: :ok
  defp require!(_, message), do: throw({:invalid, message})
end
