defmodule Newbee.LLM.Config do
  require Logger

  @moduledoc """
  模型配置 (model.json)。schema 学习 prime-agent 的 models.json：

      {
        "providers": { "<name>": { "baseUrl", "api", "apiKey", "models": [...] } },
        "roles":     { "<role>": { "provider": "<name>", "model": "<id>" } }
      }

  - apiKey 支持 `"${ENV_VAR}"` 环境变量展开、`"${prime:NAME}"` 从 ~/.prime/agent/auth.json 取 key，密钥不必落盘。
  - roles 对应 DESIGN §3.8 的模型角色路由（default/worker/adapter/explorer...）。
  - 解析顺序：$NEWBEE_MODEL_JSON → ./model.json → ./model.local.json → ~/.newbee/model.json。
  """

  @roles ["default", "worker", "adapter", "explorer", "plan", "advisor", "verifier"]

  def roles, do: @roles

  @doc "加载配置；找不到文件时回退到内置默认（OpenRouter + env key）。"
  def load do
    case resolve_path() do
      nil -> default()
      path -> parse(path)
    end
  end

  @doc "按角色构建 Client。"
  def client_for(role \\ "default", opts \\ []) do
    cfg = load()
    role_cfg = get_in(cfg, ["roles", role]) || get_in(cfg, ["roles", "default"])
    provider_name = Keyword.get(opts, :provider, role_cfg["provider"])
    model = Keyword.get(opts, :model, role_cfg["model"])
    provider = cfg["providers"][provider_name]

    unless provider, do: raise("model.json: 未知 provider #{inspect(provider_name)}")

    api = get_in(provider, ["modelApis", model]) || provider["api"] || "openai-completions"

    Newbee.LLM.Client.new(
      provider: provider_name,
      base_url: provider["baseUrl"],
      api: api,
      model: model,
      api_key: expand_env(provider["apiKey"]),
      reasoning_effort: role_cfg["reasoningEffort"],
      context_window:
        provider_context_override(provider, model) || role_cfg["contextWindow"] ||
          provider["contextWindow"],
      vision: Map.get(role_cfg, "vision", Map.get(provider, "vision", true)),
      responses_continuation: Map.get(provider, "responsesContinuation", false),
      # 会话级缓存路由键：显式 opts > 角色配置 cacheKey；nil 时由 Loop 补齐。
      cache_key: Keyword.get(opts, :cache_key) || role_cfg["cacheKey"],
      # GPT-5.6 显式缓存是 opt-in；没有 promptCacheOptions 时不改变请求体。
      prompt_cache_options: prompt_cache_options(provider, model, role_cfg)
    )
  end

  # promptCacheOptions 支持 provider 级默认、按 model 覆盖和 role 级覆盖。
  # 只有配置了该字段且 mode/ttl 通过 Client 校验后，Responses 才会发送它。
  defp prompt_cache_options(provider, model, role_cfg) do
    provider_options = provider["promptCacheOptions"]
    role_options = role_cfg["promptCacheOptions"]

    raw =
      cond do
        prompt_cache_options_map?(provider_options) -> provider_options
        is_map(provider_options) -> Map.get(provider_options, model) || role_options
        true -> role_options
      end

    if is_map(raw) and raw["enabled"] in [false, "false"], do: nil, else: raw
  end

  defp prompt_cache_options_map?(options) when is_map(options) do
    Map.has_key?(options, "mode") or Map.has_key?(options, :mode)
  end

  defp prompt_cache_options_map?(_), do: false

  @doc "读取某 provider 下单模型的上下文窗口覆盖值；未设置返回 nil。"
  def context_window_override(provider_name, model)
      when is_binary(provider_name) and is_binary(model) do
    cfg = load()
    provider_context_override(cfg["providers"][provider_name] || %{}, model)
  end

  defp provider_context_override(provider, model) when is_map(provider) and is_binary(model) do
    case provider["contextWindows"] do
      %{} = map ->
        case map[model] do
          n when is_integer(n) and n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp provider_context_override(_, _), do: nil

  @doc """
  设置/清除某 provider 下单模型的上下文窗口覆盖（WebUI 模型弹窗）。
  n 为正整数时写入 `providers.<name>.contextWindows.<model>`；n 为 nil 时删除覆盖
  （恢复 provider 元数据自动探测）。provider 不存在返回 {:error, {:unknown_provider, name}}。
  落盘到当前生效的配置文件（与 set_default_model 同一目标）。
  """
  def set_context_window(provider_name, model, n)
      when is_binary(provider_name) and is_binary(model) and (is_nil(n) or (is_integer(n) and n > 0)) do
    cfg = load()

    case cfg["providers"][provider_name] do
      nil ->
        {:error, {:unknown_provider, provider_name}}

      provider when is_map(provider) ->
        overrides =
          case provider["contextWindows"] do
            %{} = map -> map
            _ -> %{}
          end

        overrides =
          case n do
            nil -> Map.delete(overrides, model)
            n -> Map.put(overrides, model, n)
          end

        provider =
          if map_size(overrides) == 0 do
            Map.delete(provider, "contextWindows")
          else
            Map.put(provider, "contextWindows", overrides)
          end

        cfg = put_in(cfg, ["providers", provider_name], provider)
        write_config!(cfg)
        :ok
    end
  end

  def set_context_window(_, _, n) when not is_nil(n), do: {:error, :bad_context_window}

  @doc "WebUI 模型目录：按厂家分组的完整列表 + 当前默认（provider/model）。"
  def model_catalog(opts \\ []) do
    cfg = load()
    providers_cfg = for {name, p} <- cfg["providers"] || %{}, is_map(p), do: {name, p}

    providers =
      providers_cfg
      |> Task.async_stream(
        fn {name, p} ->
          %{
            name: name,
            models: provider_models(name, p, opts),
            # 单模型上下文窗口覆盖表（WebUI 可编辑）+ provider 级默认（若有）
            contextWindows: context_windows_map(p),
            contextWindow: p["contextWindow"]
          }
        end,
        max_concurrency: 8,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> %{name: "unknown", models: []}
      end)

    default = get_in(cfg, ["roles", "default"]) || %{}
    %{providers: providers, current: %{provider: default["provider"], model: default["model"]}}
  end

  @doc """
  切换默认模型（/model <id>）：
    * "provider/model-id" —— 首段须是已配置 provider 名，其余整体为模型 id
      （如 openrouter/deepseek/deepseek-v4-flash-0731 → provider=openrouter，
      model=deepseek/deepseek-v4-flash-0731）
    * "model-id"（不含斜杠）—— 保留当前 provider，只改型号
  首段不是已知 provider 时报错拒绝，绝不把带前缀的 id 写进 roles.default.model。
  落盘到当前生效的配置文件（找不到则创建 ~/.newbee/model.json）。
  """
  def set_default_model(model_id) do
    id = if is_binary(model_id), do: String.trim(model_id), else: ""
    cfg = load()

    case split_model_id(id, cfg) do
      {:error, _reason} = err ->
        err

      {provider_name, model} ->
        default = get_in(cfg, ["roles", "default"]) || %{"provider" => provider_name}
        default = default |> Map.put("provider", provider_name) |> Map.put("model", model)
        cfg = put_in(cfg, ["roles", "default"], default)
        write_config!(cfg)
        :ok
    end
  end
  @doc """
  WebUI 模型配置页：新增/更新一个 provider，并可选地更新角色绑定。

  ## 参数
    * `name` — provider 键名（原名称，用于定位；新增时传 nil 或与 `new_name` 相同）
    * `attrs` — 字符串键 map，可含：
        - "newName"   — 重命名后的键名（缺省 = name）
        - "baseUrl"   — API 根地址（必填）
        - "api"       — 协议（openai-completions / responses / anthropic / gemini）
        - "apiKey"    — 密钥或 ${ENV} 引用
        - "models"    — 模型 id 列表（list of string）
        - "contextWindow"    — provider 级默认上下文窗口（正整数或 nil 清除）
        - "contextWindows"   — 单模型覆盖表 %{"model" => n}（空 map 清除）
        - "responsesContinuation" — boolean（false 清除）
        - "extras"    — %{"k" => v} 额外字段，原样写入（保留键外的任意字段）
        - "roles"     — %{"role" => model_id} 绑定；model_id 为 nil/"" 解绑
  返回 :ok | {:error, reason}。校验失败时不落盘。
  """
  def upsert_provider(name, attrs) when is_binary(name) and is_map(attrs) do
    new_name = attrs |> Map.get("newName", name) |> to_string() |> String.trim()
    base_url = attrs |> Map.get("baseUrl", "") |> to_string() |> String.trim()

    # apiKey 为 nil 表示"保持原值"（前端掩码未改动）；空串视为待保留/新建必填
    api_key = attrs["apiKey"]
    existing = (load()["providers"] || %{})[name]

    cond do
      new_name == "" -> {:error, :bad_provider_name}
      base_url == "" -> {:error, :bad_base_url}
      # 新建（无 existing）且未提供 key → 拒绝；更新且 apiKey=nil → 保留原值
      is_nil(existing) and (is_nil(api_key) or to_string(api_key) |> String.trim() == "") ->
        {:error, :bad_api_key}
      true -> do_upsert_provider(name, new_name, attrs)
    end
  end

  def upsert_provider(_, _), do: {:error, :bad_request}

  defp do_upsert_provider(name, new_name, attrs) do
    cfg = load()
    providers = cfg["providers"] || %{}

    # 重名检查（重命名到新键时，新键不能已被占用）
    if new_name != name and Map.has_key?(providers, new_name) do
      {:error, {:provider_exists, new_name}}
    else
      existing = providers[name] || %{}

      provider =
        existing
        # 清掉受管字段，由 attrs 重建（保留未受管的额外字段在 extras 里）
        |> Map.drop(["baseUrl", "api", "apiKey", "models", "contextWindows", "contextWindow", "responsesContinuation"])
        |> Map.put("baseUrl", attrs["baseUrl"] |> to_string() |> String.trim())
        |> Map.put("api", attrs |> Map.get("api", "openai-completions") |> to_string())
        |> Map.put("models", sanitize_models(attrs["models"]))
        |> put_api_key(attrs["apiKey"], existing)
        |> maybe_put_ctxw(attrs["contextWindow"])

        |> maybe_put_ctxws(attrs["contextWindows"])
        |> maybe_put_resp_cont(attrs["responsesContinuation"])
        |> Map.merge(sanitize_extras(attrs["extras"]))

      providers =
        providers
        |> Map.delete(name)
        |> Map.put(new_name, provider)

      roles = update_roles(cfg["roles"] || %{}, name, new_name, attrs["roles"])

      cfg = cfg |> Map.put("providers", providers) |> Map.put("roles", roles)
      write_config!(cfg)
      :ok
    end
  end

  defp sanitize_models(list) when is_list(list) do
    list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp sanitize_models(_), do: []


  # apiKey 处理：nil/空串 → 保留 existing 原值；否则用新值（去除首尾空白）
  defp put_api_key(provider, nil, existing), do: Map.put(provider, "apiKey", existing["apiKey"] || "")
  defp put_api_key(provider, new, _existing) do
    v = new |> to_string() |> String.trim()
    Map.put(provider, "apiKey", v)
  end

  defp maybe_put_ctxw(p, n) when is_integer(n) and n > 0, do: Map.put(p, "contextWindow", n)
  defp maybe_put_ctxw(p, s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> Map.put(p, "contextWindow", n)
      _ -> p
    end
  end
  defp maybe_put_ctxw(p, _), do: p

  defp maybe_put_ctxws(p, map) when is_map(map) and map_size(map) > 0 do
    clean =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), to_pos_int(v)} end)
      |> Enum.filter(fn {k, v} -> k != "" and is_integer(v) end)
      |> Map.new()
    if map_size(clean) > 0, do: Map.put(p, "contextWindows", clean), else: p
  end
  defp maybe_put_ctxws(p, _), do: p

  defp to_pos_int(n) when is_integer(n) and n > 0, do: n
  defp to_pos_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end
  defp to_pos_int(_), do: nil

  defp maybe_put_resp_cont(p, true), do: Map.put(p, "responsesContinuation", true)
  defp maybe_put_resp_cont(p, "true"), do: Map.put(p, "responsesContinuation", true)
  defp maybe_put_resp_cont(p, _), do: p

  defp sanitize_extras(map) when is_map(map) do
    reserved = ~w(newName baseUrl api apiKey models contextWindow contextWindows responsesContinuation roles extras)
    Map.drop(map, reserved)
  end
  defp sanitize_extras(_), do: %{}

  # roles 更新：
  # 1) 先把所有引用旧名的角色 provider 改为新名（重命名跟随）
  # 2) 再按 attrs["roles"] 增删绑定（model nil/"" = 解绑）
  defp update_roles(roles, old_name, new_name, nil) do
    # 无显式绑定变更：只做重命名跟随
    Map.new(roles, fn
      {role, %{"provider" => ^old_name} = r} -> {role, Map.put(r, "provider", new_name)}
      {role, r} -> {role, r}
    end)
  end

  defp update_roles(roles, old_name, new_name, binds) when is_map(binds) do
    roles =
      Map.new(roles, fn
        {role, %{"provider" => ^old_name} = r} -> {role, Map.put(r, "provider", new_name)}
        {role, r} -> {role, r}
      end)

    Enum.reduce(binds, roles, fn
      {role, model}, acc when is_binary(role) ->
        model = model |> to_string() |> String.trim()

        cond do
          model == "" ->
            # 解绑：仅当该角色正绑定到这个 provider 时才移除，避免误删别家绑定
            case acc[role] do
              %{"provider" => ^new_name} -> Map.delete(acc, role)
              _ -> acc
            end

          role == "" ->
            acc

          true ->
            # 绑定/换绑：provider 指向当前，model 指向所选
            Map.put(acc, role, %{"provider" => new_name, "model" => model})
        end

      _, acc ->
        acc
    end)
  end

  @doc """
  WebUI 模型配置页：删除一个 provider，并解绑所有指向它的角色。
  返回 :ok | {:error, {:unknown_provider, name}}。default 角色被解绑时会
  回退到剩余的第一个 provider（若还有），保证聊天不中断。
  """
  def delete_provider(name) when is_binary(name) do
    cfg = load()
    providers = cfg["providers"] || %{}

    if Map.has_key?(providers, name) do
      providers = Map.delete(providers, name)

      {roles, removed_default?} =
        Enum.reduce(cfg["roles"] || %{}, {%{}, false}, fn
          {role, %{"provider" => ^name}}, {acc, _} -> {acc, role == "default"}
          {role, r}, {acc, d} -> {Map.put(acc, role, r), d}
        end)

      # default 被删：回退到剩余 provider 的第一个模型，保证聊天可用
      roles =
        if removed_default? and map_size(providers) > 0 do
          {fallback_name, fallback_p} = Enum.at(providers, 0)
          fallback_model =
            case fallback_p["models"] do
              [m | _] when is_binary(m) -> m
              _ -> nil
            end

          if fallback_model do
            Map.put(roles, "default", %{"provider" => fallback_name, "model" => fallback_model})
          else
            roles
          end
        else
          roles
        end

      cfg = cfg |> Map.put("providers", providers) |> Map.put("roles", roles)
      write_config!(cfg)
      :ok
    else
      {:error, {:unknown_provider, name}}
    end
  end

  def delete_provider(_), do: {:error, :bad_request}


  @doc "当前生效的配置文件路径（找不到时返回将要创建的 ~/.newbee/model.json 路径）。"
  def config_path, do: config_target()


  # 当前生效的配置文件路径（找不到则创建 ~/.newbee/model.json）
  defp config_target do
    Enum.find(
      [
        System.get_env("NEWBEE_MODEL_JSON"),
        "model.json",
        "model.local.json",
        Path.join([System.user_home!(), ".newbee", "model.json"])
      ],
      &(&1 && File.exists?(&1))
    ) || Path.join(System.user_home!(), ".newbee/model.json")
  end

  defp write_config!(cfg) do
    target = config_target()
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, Jason.encode_to_iodata!(cfg, pretty: true))
    :ok
  end

  # "a/b/c" → {"a", "b/c"}（a 是已知 provider）；"c" → {当前 provider, "c"}
  defp split_model_id("", _cfg), do: {:error, :bad_model_id}

  defp split_model_id(id, cfg) do
    case String.split(id, "/", parts: 2) do
      [model] ->
        {get_in(cfg, ["roles", "default", "provider"]) || "openrouter", model}

      [head, rest] ->
        if Map.has_key?(cfg["providers"] || %{}, head),
          do: {head, rest},
          else: {:error, {:unknown_provider, head}}
    end
  end

  @doc "当前配置的人类可读描述（给 /model 命令用）。"
  def describe do
    cfg = load()

    for {role, rc} <- cfg["roles"] || %{} do
      p = cfg["providers"][rc["provider"]] || %{}
      "#{role}: #{rc["provider"]}/#{rc["model"]} @ #{p["baseUrl"]}"
    end
  end

  @doc "已知型号候选（供 TUI Tab 补全）：汇总各 provider 的 models 列表 + 当前 roles 已用型号，去重排序。"
  def model_candidates do
    cfg = load()

    from_providers =
      for {_pname, p} <- cfg["providers"] || %{}, m <- p["models"] || [], is_binary(m), do: m

    from_roles =
      for {_role, rc} <- cfg["roles"] || %{}, is_binary(rc["model"]), do: rc["model"]

    (from_providers ++ from_roles)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── 模型列表自动拉取 ──

  @models_cache :newbee_llm_models_cache
  @models_ttl :timer.minutes(5)

  @doc """
  取某 provider 的模型列表：优先缓存（5 分钟），其次 GET {baseUrl}/models
  （OpenAI 兼容 data[].id），失败回退配置里的静态 models 列表。
  """
  def provider_models(name, provider, opts \\ []) do
    ensure_cache_table()
    key = {name, provider["baseUrl"]}
    force = Keyword.get(opts, :refresh, false)

    case :ets.lookup(@models_cache, key) do
      [{^key, ids, ts}] when not force ->
        # 有缓存、未过期且非强制：直接返回缓存
        if :erlang.monotonic_time(:millisecond) - ts < @models_ttl do
          ids
        else
          do_fetch_and_cache(name, provider, key)
        end

      _ when force ->
        # 强制刷新：同步拉取
        do_fetch_and_cache(name, provider, key)

      _ ->
        # 无缓存非强制：返回静态列表（不自动拉取）
        static_models(provider)
    end
  end

  defp do_fetch_and_cache(_name, provider, key) do
    ids = fetch_models(provider) || static_models(provider)
    :ets.insert(@models_cache, {key, ids, :erlang.monotonic_time(:millisecond)})
    ids
  end

  @doc """
  按名字取某 provider 的模型列表（供按厂商刷新）。provider 名不存在时返回 nil。
  """
  def provider_models_by_name(name, opts \\ []) do
    cfg = load()
    provider = get_in(cfg, ["providers", name])

    if is_map(provider) do
      provider_models(name, provider, opts)
    else
      nil
    end
  end

  # 从 provider 的 OpenAI 兼容 /models 接口拉取模型 id 列表
  defp fetch_models(provider) do
    base = provider["baseUrl"]
    key = expand_env(provider["apiKey"])

    if is_binary(base) and String.trim(base) != "" do
      url = String.trim_trailing(base, "/") <> "/models"

      with {:ok, %{"data" => data}} when is_list(data) <- http_get(url, key) do
        data
        |> Enum.map(fn m -> m["id"] end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> case do
          [] -> nil
          ids -> ids
        end
      else
        _ -> nil
      end
    else
      nil
    end
  end

  defp static_models(provider) do
    Enum.filter(provider["models"] || [], &is_binary/1)
  end

  # 只保留正整数覆盖项（配置文件可能被手编辑出脏数据）
  defp context_windows_map(provider) do
    case provider["contextWindows"] do
      %{} = map ->
        Map.new(map, fn {k, v} -> {to_string(k), v} end)
        |> Enum.filter(fn {_k, v} -> is_integer(v) and v > 0 end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(@models_cache) do
      :undefined ->
        try do
          :ets.new(@models_cache, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  defp http_get(url, api_key) do
    headers =
      if is_binary(api_key) and api_key != "" do
        [{"authorization", "Bearer " <> api_key}]
      else
        []
      end

    result =
      if URI.parse(url).host == "openrouter.ai" do
        openrouter_get(url, headers)
      else
        req_get(url, headers)
      end

    case result do
      {:ok, body} ->
        {:ok, body}

      other ->
        Logger.warning("model_catalog: fetch failed for " <> url <> ": " <> inspect(other))
        :error
    end
  end

  defp openrouter_get(url, headers) do
    auth_args = Enum.flat_map(headers, fn {key, value} -> ["--header", key <> ": " <> value] end)
    args = ["--silent", "--show-error", "--fail", "--max-time", "30"] ++ auth_args ++ [url]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
        end

      {output, status} ->
        {:error, {:curl_failed, status, String.slice(output, 0, 200)}}
    end
  rescue
    error -> {:error, {:curl_exception, Exception.message(error)}}
  end

  # Finch can hang on OpenRouter under transparent-proxy/fake-IP setups.
  defp req_get(url, headers) do
    case Req.get(url, headers: headers, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: st} = resp} when st in 200..299 -> {:ok, resp.body}
      {:ok, %Req.Response{status: st}} -> {:error, {:http_status, st}}
      {:error, _e} -> httpc_get(url, headers)
    end
  end

  defp httpc_get(url, headers) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    req =
      {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}

    try do
      :httpc.set_options(ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()])

      case :httpc.request(:get, req, [timeout: 30_000, connect_timeout: 10_000], body_format: :binary) do
        {:ok, {{_, 200, _}, _, body}} ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
          end

        {:ok, {{_, st, _}, _, _body}} ->
          {:error, {:http_status, st}}

        {:error, e} ->
          {:error, e}
      end
    rescue
      e -> {:error, {:httpc_exception, Exception.message(e)}}
    catch
      k, r -> {:error, {:httpc_thrown, {k, r}}}
    end
  end

  # ── internals ──

  defp resolve_path do
    Enum.find(
      [
        System.get_env("NEWBEE_MODEL_JSON"),
        "model.json",
        "model.local.json",
        Path.join([System.user_home!(), ".newbee", "model.json"])
      ],
      &(&1 && File.exists?(&1))
    )
  end

  defp parse(path) do
    case File.read(path) |> then(fn {:ok, b} -> Jason.decode(b) end) do
      {:ok, cfg} -> cfg
      {:error, e} -> raise "model.json 解析失败 #{path}: #{inspect(e)}"
    end
  end

  defp default do
    %{
      "providers" => %{
        "openrouter" => %{
          "baseUrl" => "https://openrouter.ai/api/v1",
          "apiKey" => "${OPENROUTER_API_KEY}",
          "models" => []
        }
      },
      "roles" => %{
        "default" => %{"provider" => "openrouter", "model" => "deepseek/deepseek-v4-flash-0731"}
      }
    }
  end

  defp expand_env(nil), do: nil

  defp expand_env("${" <> rest) do
    var = String.trim_trailing(rest, "}")

    case String.split(var, ":", parts: 2) do
      ["prime", name] -> prime_key(name)
      [env_var] -> System.get_env(env_var)
    end
  end

  defp expand_env(literal), do: literal

  defp prime_key(name) do
    path = Path.join([System.user_home!(), ".prime", "agent", "auth.json"])

    with {:ok, body} <- File.read(path),
         {:ok, auth} <- Jason.decode(body),
         %{"key" => key} <- Map.get(auth, name) do
      key
    else
      _ -> nil
    end
  end
end
