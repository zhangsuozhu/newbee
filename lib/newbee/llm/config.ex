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
