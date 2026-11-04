defmodule Newbee.Colony.Source do
  @moduledoc "Opt-in local/GitHub intake, atomic event-to-work routing and durable reply intentions."
  alias Newbee.Colony.{Store, Work, Bee, Id}
  @modes ~w(observe explicit auto)
  @terminal ~w(done failed cancelled)

  @doc "Configure a host-owned source. New sources observe; secrets remain in named environment variables."
  def configure(attrs) when is_map(attrs) do
    with :ok <- validate(attrs) do
      root = Path.expand(attrs["root"])
      id = attrs["id"] || "source-" <> hash([attrs["kind"], attrs["repository"], root])

      Store.transaction(fn data ->
        old = data["source_instances"][id]

        cond do
          old && attrs["revision"] != old["revision"] ->
            {:error, "conflict", "来源配置已变化，请刷新"}

          old && (old["root"] != root or old["repository"] != attrs["repository"] or old["kind"] != attrs["kind"]) ->
            {:error, "source_identity", "来源身份和项目不能静默迁移，请新建来源"}

          true ->
            {data, colony, actor, worker} =
              if old do
                {data, data["colonies"][old["colony_id"]], data["bees"][old["actor_bee_id"]],
                 data["bees"][old["worker_bee_id"]]}
              else
                bootstrap(data, root)
              end

            config =
              Map.take(
                attrs,
                ~w(kind repository allowed_actors secret_env token_env label auto_prefix allowed_event_types)
              )

            config =
              Map.merge(config, %{
                "id" => id,
                "root" => root,
                "mode" => attrs["mode"] || "observe",
                "paused" => attrs["paused"] == true,
                "max_per_hour" => attrs["max_per_hour"] || 2,
                "cooldown_ms" => attrs["cooldown_ms"] || 60_000,
                "colony_id" => colony["id"],
                "actor_bee_id" => actor["id"],
                "worker_bee_id" => worker["id"],
                "revision" => if(old, do: old["revision"] + 1, else: 0),
                "updated_at" => now(),
                "created_at" => if(old, do: old["created_at"], else: now())
              })

            {:ok, {:ok, config}, put_in(data, ["source_instances", id], config)}
        end
      end)
    end
  end

  def configure(_), do: {:error, "bad_request", "来源配置必须是对象"}

  def list, do: Store.all("source_instances")

  def events(id),
    do:
      Store.all("source_events")
      |> Enum.filter(&(&1["source_id"] == id))
      |> Enum.sort_by(& &1["created_at"], :desc)
      |> Enum.take(200)

  @doc "A host may replay an observed/blocked receipt after changing policy; owned events never duplicate work."
  def replay(source_id, event_id) do
    Store.transaction(fn data ->
      with %{} = config <- data["source_instances"][source_id],
           %{"source_id" => ^source_id} = receipt <- data["source_events"][event_id] do
        if receipt["disposition"] in ["owned", "filtered", "self_event"] do
          {:ok, {:ok, receipt}, data}
        else
          event = receipt |> Map.put("id", receipt["external_id"])
          {next, updated} = route(data, config, receipt, event)
          updated = Map.put(updated, "replayed_at", now())
          {:ok, {:ok, updated}, put_in(next, ["source_events", event_id], updated)}
        end
      else
        _ -> {:error, "not_found", "来源或事件不存在"}
      end
    end)
  end

  @doc "Receive a normalized event from a host-authenticated local bridge; identities are configured, not supplied by the event."
  def ingest(id, event) when is_map(event) do
    with {:ok, config} <- Store.get("source_instances", id), :ok <- validate_event(config, event) do
      event_id = hash([id, event["id"]])
      digest = hash(event)
      sid = "source-" <> String.slice(hash([id, event["thread"]]), 0, 40)

      # Creating conversation metadata has no execution effect; the atomic Store receipt below is the acceptance boundary.
      with :ok <- Newbee.Session.set_cwd(sid, config["root"]), :ok <- Newbee.Session.mark_created(sid) do
        Store.transaction(fn data ->
          config = data["source_instances"][id]

          case data["source_events"][event_id] do
            %{"content_hash" => ^digest} = old ->
              {:ok, {:ok, old}, data}

            %{} ->
              {:error, "event_conflict", "相同来源事件 ID 的内容不同，请使用新的修订 ID"}

            nil ->
              receipt =
                Map.merge(Map.take(event, ~w(id thread actor event_type url text machine explicit self_reply)), %{
                  "id" => event_id,
                  "external_id" => event["id"],
                  "source_id" => id,
                  "content_hash" => digest,
                  "origin_session_id" => sid,
                  "created_at" => now()
                })

              {data, receipt} = route(data, config, receipt, event)
              {:ok, {:ok, receipt}, put_in(data, ["source_events", event_id], receipt)}
          end
        end)
      end
    end
  end

  def ingest(_, _), do: {:error, "bad_request", "来源事件必须是对象"}

  @doc "GitHub webhook verification is over the exact received bytes, before decoding or routing."
  def github(id, delivery_id, event_type, signature, body) when is_binary(body) and byte_size(body) <= 1_048_576 do
    with {:ok, %{"kind" => "github"} = config} <- Store.get("source_instances", id),
         secret when is_binary(secret) and byte_size(secret) >= 16 <- env(config["secret_env"]),
         :ok <- signature(secret, body, signature),
         {:ok, payload} when is_map(payload) <- Jason.decode(body),
         true <- is_binary(delivery_id) and byte_size(delivery_id) in 1..256 do
      case github_event(config, delivery_id, event_type, payload) do
        {:ok, event} -> ingest(id, event)
        {:error, "ignored_event", reason} -> filtered(id, delivery_id, body, event_type, reason)
        error -> error
      end
    else
      {:error, _, _} = error -> error
      _ -> {:error, "unauthorized", "来源不存在、Webhook 签名无效或载荷不受支持"}
    end
  end

  def github(_, _, _, _, _), do: {:error, "too_large", "来源载荷超过 1 MiB 或无效"}

  defp filtered(id, external_id, body, event_type, reason) do
    key = hash([id, external_id])
    digest = hash(body)

    Store.transaction(fn data ->
      case data["source_events"][key] do
        %{"content_hash" => ^digest} = old ->
          {:ok, {:ok, old}, data}

        %{} ->
          {:error, "event_conflict", "同一外部事件 ID 的内容已经变化"}

        nil ->
          receipt = %{
            "id" => key,
            "external_id" => external_id,
            "source_id" => id,
            "content_hash" => digest,
            "event_type" => event_type,
            "disposition" => "filtered",
            "reason" => reason,
            "created_at" => now()
          }

          {:ok, {:ok, receipt}, put_in(data, ["source_events", key], receipt)}
      end
    end)
  end

  defp github_event(config, id, type, payload) do
    repo = get_in(payload, ["repository", "full_name"])
    issue = payload["issue"]

    body =
      if type == "issue_comment", do: get_in(payload, ["comment", "body"]), else: get_in(payload, ["issue", "body"])

    sender = payload["sender"] || %{}

    if repo == config["repository"] and type in ["issue_comment", "issues"] and
         payload["action"] in ["created", "opened", "edited"] and is_map(issue) and is_integer(issue["number"]) and
         is_binary(body) do
      {:ok,
       %{
         "id" => id,
         "thread" => Integer.to_string(issue["number"]),
         "actor" => sender["login"] || "unknown",
         "machine" => sender["type"] == "Bot",
         "text" => body,
         "event_type" => type <> "." <> payload["action"],
         "url" => issue["html_url"],
         "explicit" => String.match?(body, ~r/\A\s*(?:@newbee\b|\/newbee\b)/iu),
         "self_reply" => String.contains?(body, "<!-- newbee-reply:")
       }}
    else
      {:error, "ignored_event", "来源或事件范围不匹配"}
    end
  end

  defp route(data, config, receipt, event) do
    sid = receipt["origin_session_id"]

    existing =
      Enum.filter(Map.values(data["tasks"]), &(&1["origin_session_id"] == sid and &1["status"] not in @terminal))
      |> Enum.max_by(& &1["created_at"], fn -> nil end)

    actor_allowed = event["actor"] in (config["allowed_actors"] || [])

    rule_match =
      is_binary(config["auto_prefix"]) and config["auto_prefix"] != "" and
        event["event_type"] in (config["allowed_event_types"] || []) and
        String.starts_with?(event["text"], config["auto_prefix"])

    requested =
      (is_map(existing) or event["explicit"] == true or rule_match) and actor_allowed and event["machine"] != true and
        event["self_reply"] != true

    disposition =
      cond do
        config["paused"] -> "paused"
        event["self_reply"] == true -> "self_event"
        config["mode"] == "observe" -> "observed"
        is_nil(existing) and event["explicit"] != true and config["mode"] != "auto" -> "context_only"
        not requested -> "context_only"
        budget_exhausted?(data, config, existing) -> "budget_exhausted"
        true -> "owned"
      end

    predicted = if requested, do: if(existing, do: "followup", else: "create"), else: "context_only"
    receipt = Map.merge(receipt, %{"disposition" => disposition, "predicted" => predicted})

    if disposition == "owned" do
      {task, data} =
        if existing do
          task =
            existing
            |> Map.update("revision", 1, &(&1 + 1))
            |> Map.update("context_revision", 1, &(&1 + 1))
            |> Map.put("updated_at", now())

          task =
            if task["status"] == "pending_review",
              do: Map.merge(task, %{"status" => "claimed", "result" => nil}),
              else: task

          {task, data}
        else
          colony = data["colonies"][config["colony_id"]]
          worker = data["bees"][config["worker_bee_id"]]

          attrs = %{
            "title" => String.slice(event["text"], 0, 100),
            "description" => event["text"],
            "cwd" => config["root"],
            "source_root" => config["root"],
            "origin_session_id" => sid,
            "conversation" => true,
            "autonomous" => true,
            "workflow" => true,
            "execution_generation" => 1,
            "consumed_context_revision" => 0,
            "inputs" => [],
            "actor_bee_id" => config["actor_bee_id"]
          }

          task =
            Work.build(colony, worker, attrs)
            |> Map.put("source_binding", %{
              "source_id" => config["id"],
              "thread" => event["thread"],
              "url" => event["url"]
            })

          {task, data}
        end

      input_id = "source-input:" <> receipt["id"]
      delivery = Work.new_delivery(task, %{"instruction" => event["text"], "input_id" => input_id})

      delivery =
        if task["status"] == "blocked" and is_nil(task["question"]) and
             String.contains?(task["next_step"] || "", ["回执", "无法确认", "没有心跳"]),
           do: Map.put(delivery, "status", "held"),
           else: delivery

      input = %{
        "id" => input_id,
        "text" => event["text"],
        "origin" => "user",
        "created_at" => now(),
        "consumed_at" => nil,
        "context_revision" => task["context_revision"],
        "delivery_id" => delivery["id"],
        "request_id" => receipt["external_id"]
      }

      # An explicitly subscribed answer may continue a human question. Context-only bot events never do.
      task =
        task
        |> Map.update("inputs", [input], &(&1 ++ [input]))
        |> Map.put("question", nil)
        |> Map.put("waiting_for", nil)

      next = data |> put_in(["tasks", task["id"]], task) |> put_in(["deliveries", delivery["id"]], delivery)
      {next, Map.merge(receipt, %{"task_id" => task["id"], "input_id" => input_id})}
    else
      {data, Map.put(receipt, "task_id", if(existing, do: existing["id"], else: nil))}
    end
  end

  defp budget_exhausted?(data, config, existing) do
    # Budgets bound new executions; explicit follow-ups to an existing work keep a usable control lane.
    if existing do
      get_in(existing, ["application", "state"]) in [
        "preparing",
        "applying",
        "prepared",
        "unknown",
        "partial",
        "failed",
        "applied",
        "text_accepted"
      ]
    else
      recent =
        Map.values(data["source_events"])
        |> Enum.filter(
          &(&1["source_id"] == config["id"] and &1["disposition"] == "owned" and &1["predicted"] == "create" and
              &1["created_at"] > now() - 3_600_000)
        )

      length(recent) >= config["max_per_hour"] or Enum.any?(recent, &(&1["created_at"] > now() - config["cooldown_ms"]))
    end
  end

  @doc "Queue one result or question per stable revision; failures remain independent of work success."
  def collect_replies do
    Store.transaction(fn data ->
      next =
        Enum.reduce(Map.values(data["tasks"]), data, fn task, acc ->
          binding = task["source_binding"]

          if is_map(binding) do
            question = task["question"]
            honey = data["honey"][task["result"]]

            cond do
              is_map(question) -> outbox(acc, task, "question:" <> question["id"], question["question"] || "需要你答复")
              is_map(honey) -> outbox(acc, task, "result:" <> honey["id"], honey["content"] || "成果已就绪")
              true -> acc
            end
          else
            acc
          end
        end)

      if next == data, do: {:ok, :ok, data}, else: {:ok, :ok, next}
    end)
  end

  defp outbox(data, task, key, body) do
    binding = task["source_binding"]
    id = hash([task["id"], key])

    if data["source_outbox"][id] do
      data
    else
      entry = %{
        "id" => id,
        "task_id" => task["id"],
        "source_id" => binding["source_id"],
        "thread" => binding["thread"],
        "body" => String.slice(body, 0, 50_000),
        "status" => "pending",
        "attempts" => 0,
        "created_at" => now(),
        "next_at" => 0
      }

      put_in(data, ["source_outbox", id], entry)
    end
  end

  @doc "A transport must reconcile its stable marker before sending; ambiguous timeouts stay retryable, not 'delivered'."
  def deliver(id, transport \\ &Newbee.Colony.Source.GitHub.deliver/2) do
    :global.trans({{__MODULE__, "reply", id}, self()}, fn -> do_deliver(id, transport) end)
  end

  defp do_deliver(id, transport) do
    with {:ok, entry} <- Store.get("source_outbox", id),
         {:ok, config} <- Store.get("source_instances", entry["source_id"]) do
      cond do
        entry["status"] == "delivered" ->
          {:ok, entry}

        config["paused"] or config["mode"] == "observe" ->
          {:error, "paused", "来源处于观察或暂停"}

        entry["next_at"] > now() ->
          {:error, "backoff", "正在退避，尚未到重试时间"}

        true ->
          result = transport.(config, entry)

          Store.update("source_outbox", id, nil, fn current ->
            current = Map.put(current, "attempts", current["attempts"] + 1)

            case result do
              {:ok, receipt} ->
                {:ok,
                 Map.merge(current, %{
                   "status" => "delivered",
                   "receipt" => receipt,
                   "delivered_at" => now(),
                   "last_error" => nil
                 })}

              {:error, reason} ->
                {:ok,
                 Map.merge(current, %{
                   "status" => "pending",
                   "last_error" => inspect(reason),
                   "next_at" => now() + min(3_600_000, 5_000 * Integer.pow(2, min(current["attempts"], 9)))
                 })}
            end
          end)
      end
    end
  end

  defp validate(attrs) do
    cond do
      attrs["kind"] not in ["local", "github"] ->
        {:error, "bad_request", "仅支持 local/github 来源"}

      attrs["mode"] not in [nil | @modes] ->
        {:error, "bad_request", "来源模式无效"}

      not is_binary(attrs["root"]) or not File.dir?(attrs["root"]) ->
        {:error, "workspace_missing", "来源需要真实项目根"}

      attrs["kind"] == "github" and
          not (is_binary(attrs["repository"]) and Regex.match?(~r/\A[\w.-]+\/[\w.-]+\z/, attrs["repository"])) ->
        {:error, "bad_request", "仓库需为 owner/repo"}

      not is_list(attrs["allowed_actors"] || []) or length(attrs["allowed_actors"] || []) > 100 or
          not Enum.all?(attrs["allowed_actors"] || [], &is_binary/1) ->
        {:error, "bad_request", "允许的来源用户列表无效"}

      attrs["mode"] in ["explicit", "auto"] and (attrs["allowed_actors"] || []) == [] ->
        {:error, "bad_request", "执行前需明确允许的来源用户"}

      attrs["mode"] == "auto" and
          not (is_binary(attrs["auto_prefix"]) and byte_size(attrs["auto_prefix"]) in 1..200 and
                 is_list(attrs["allowed_event_types"]) and length(attrs["allowed_event_types"]) in 1..20 and
                   Enum.all?(attrs["allowed_event_types"], &is_binary/1)) ->
        {:error, "bad_request", "自动模式必须限定正文前缀与事件类型；请先用观察模式验证"}

      attrs["max_per_hour"] != nil and not (is_integer(attrs["max_per_hour"]) and attrs["max_per_hour"] in 1..100) ->
        {:error, "bad_request", "每小时工作预算需为 1..100"}

      attrs["cooldown_ms"] != nil and not (is_integer(attrs["cooldown_ms"]) and attrs["cooldown_ms"] in 0..3_600_000) ->
        {:error, "bad_request", "冷却时间无效"}

      not Enum.all?(
        [attrs["secret_env"], attrs["token_env"]],
        &(is_nil(&1) or (is_binary(&1) and Regex.match?(~r/\A[A-Z][A-Z0-9_]{0,127}\z/, &1)))
      ) ->
        {:error, "bad_request", "密钥需引用环境变量名"}

      true ->
        :ok
    end
  end

  defp validate_event(config, event) do
    cond do
      not Enum.all?(~w(id thread actor text event_type), &(is_binary(event[&1]) and byte_size(event[&1]) in 1..100_000)) ->
        {:error, "bad_request", "来源事件缺少 ID/线程/作者/正文/类型"}

      byte_size(event["id"]) > 256 or byte_size(event["thread"]) > 256 ->
        {:error, "bad_request", "来源事件 ID 或线程过长"}

      config["kind"] == "github" and not Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, event["thread"]) ->
        {:error, "bad_request", "GitHub 线程编号无效"}

      true ->
        :ok
    end
  end

  defp signature(secret, body, signature) do
    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    if is_binary(signature) and byte_size(signature) == byte_size(expected) and
         Plug.Crypto.secure_compare(signature, expected), do: :ok, else: {:error, "unauthorized", "Webhook 签名无效"}
  end

  defp bootstrap(data, root) do
    cid = Id.new(:colony, :local)
    actor = Bee.new(%{"colony_id" => cid, "kind" => "human", "display" => "来源管理员", "role" => "queen"})
    worker = Bee.new(%{"colony_id" => cid, "kind" => "ai", "display" => "工作负责人"})

    colony = %{
      "id" => cid,
      "name" => "来源工作",
      "cwd" => root,
      "status" => "active",
      "created_at" => now(),
      "queen_bee_id" => actor["id"],
      "admin_bee_ids" => [actor["id"]],
      "conversation_only" => true
    }

    {data
     |> put_in(["colonies", cid], colony)
     |> put_in(["bees", actor["id"]], actor)
     |> put_in(["bees", worker["id"]], worker), colony, actor, worker}
  end

  defp env(name) when is_binary(name), do: System.get_env(name)
  defp env(_), do: nil
  defp hash(value), do: Newbee.Collaboration.Verification.value_sha256(value)
  defp now, do: System.system_time(:millisecond)
end
