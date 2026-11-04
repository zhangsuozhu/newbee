defmodule Newbee.Colony.WorkspaceReview do
  @moduledoc """
  Colony 原生成果审阅与幂等应用（docs/superagent-conversation-ux.md 场景 E）。

  审阅与应用只围绕 Colony 自己的 Task/Honey/Workspace：

  - `review/1` 只读：核对 Task 处于 `pending_review`、Honey 的 `work_revision`
    与 Task 的 `context_revision` 一致，再比较工作区基线快照与真实内容，
    给出覆盖完整差异的 `patch_sha256`、文件清单与目标目录现状（可应用/已应用/冲突）。
    展示用的文件内容与 diff 有大小上限，但 hash 覆盖未截断的真实差异。
  - `apply/3` 写入：目标固定取 `workspace.root`，不接受调用方提供目录；写入前重新
    计算差异并与被审阅 hash 比对，逐文件核对目标是否仍等于基线，拒绝路径逃逸与
    符号链接，不触碰本次差异之外的文件（用户 dirty/untracked 原样保留）。
    应用意图先落盘到 Task 的 `application` 字段，重复请求返回同一回执；崩溃或回执
    不明时按实际 before/after 指纹核对，不重放覆盖新改动。

  本模块不改 Task 状态、不代替 Honey 验收（由 `Newbee.Colony.Work.review/5` finalize
  收尾），也不执行任何 Git 写操作（不 commit/push、不动 index）。

  已知边界：断点恢复只按「本次意图覆盖的文件」判断。若某文件已被写回基线内容
  （例如人手动回退），重试会把它当作「未应用」重新写入；这不覆盖基线之外的任何
  内容，但也不是撤销。真正撤销需要另一次以实际差异为依据、需确认影响的操作。

  ## 可跑示例

      task = ...            # Colony Task：pending_review、带独立 workspace
      {:ok, review} = Newbee.Colony.WorkspaceReview.review(task)
      review["patch_sha256"]
      {:ok, receipt} = Newbee.Colony.WorkspaceReview.apply(task, review["patch_sha256"], "req-1")
      receipt["state"]  #=> "applied"
  """

  alias Newbee.Colony.Store
  alias Newbee.Collaboration.Workspace, as: Baseline

  @workspace_kinds ~w(filesystem_copy git_worktree)
  @reviewable_honey_states ~w(pending_review auto_verified)
  @in_flight_states ~w(applying partial unknown failed)
  @max_display_files 40
  @max_file_display_bytes 6_000
  @max_display_patch_bytes 120_000
  @max_apply_bytes 256 * 1_024 * 1_024
  @max_apply_files 4_096
  @request_id_re ~r/\A[0-9A-Za-z._:-]{1,180}\z/
  @sha_re ~r/\A[0-9a-f]{64}\z/

  ## ── review ──────────────────────────────────────────────────────────────

  @doc "只读审阅：返回字符串键 map（patch_sha256/files/conflicts/target_root/…）。"
  def review(task) when is_map(task) do
    with {:ok, task} <- resolve(task),
         {:ok, honey} <- reviewable(task),
         {:ok, workspace} <- workspace(task),
         {:ok, base} <- baseline(workspace),
         :ok <- baseline_matches(workspace, base),
         {:ok, source} <- Baseline.snapshot(workspace["path"]),
         {:ok, diff} <- diff(base, source) do
      {:ok, review_view(task, honey, workspace, diff)}
    end
  end

  def review(_), do: {:error, "bad_request", "需要一份 Colony 工作"}

  ## ── apply ───────────────────────────────────────────────────────────────

  @doc """
  把被审阅的那份差异应用到 `workspace.root`；幂等，并按 Task 的 `application`
  字段断点恢复。返回 `{:ok, receipt}` 或 `{:error, code, message}`。
  """
  def apply(task, expected_sha256, request_id) when is_map(task) do
    with :ok <- valid_request(request_id, expected_sha256),
         {:ok, stored} <- stored(task),
         {:ok, workspace} <- workspace(stored) do
      with_target_lock(workspace["root"], fn ->
        locked_apply(stored["id"], expected_sha256, request_id)
      end)
    end
  end

  def apply(_, _, _), do: {:error, "bad_request", "需要任务、审阅 hash 与请求 ID"}

  defp with_target_lock(root, fun) do
    case :global.trans({{__MODULE__, Path.expand(root)}, self()}, fun, [node()]) do
      :aborted -> {:error, "apply_busy", "该目标目录上已有应用操作在进行，请稍后重试"}
      result -> result
    end
  end

  defp locked_apply(task_id, patch_sha256, request_id) do
    with {:ok, task} <- fetch_task(task_id) do
      case prior_application(task, patch_sha256, request_id) do
        {:done, receipt} -> {:ok, receipt}
        {:error, _code, _message} = error -> error
        :fresh -> do_apply(task, patch_sha256, request_id)
      end
    end
  end

  defp do_apply(task, patch_sha256, request_id) do
    with {:ok, honey} <- reviewable(task),
         {:ok, workspace} <- workspace(task),
         {:ok, diff} <- current_diff(workspace),
         :ok <- same_review(patch_sha256, diff["patch_sha256"]),
         :ok <- precheck(workspace, diff),
         {:ok, intent} <- persist_intent(task, workspace, diff, honey, request_id) do
      write_changes(task, workspace, intent)
    end
  end

  defp current_diff(workspace) do
    with {:ok, base} <- baseline(workspace),
         :ok <- baseline_matches(workspace, base),
         {:ok, source} <- Baseline.snapshot(workspace["path"]) do
      diff(base, source)
    end
  end

  ## ── 上一次应用的核对 ────────────────────────────────────────────────────

  defp prior_application(task, patch_sha256, request_id) do
    case application_of(task) do
      %{"request_id" => ^request_id, "patch_sha256" => other} when other != patch_sha256 ->
        {:error, "request_conflict", "同一应用请求 ID 不能对应另一份改动"}

      %{"state" => "applied"} = application ->
        if application["patch_sha256"] == patch_sha256,
          do: {:done, replay_receipt(application, request_id)},
          else: {:error, "already_applied", "该成果已应用了另一个版本（#{application["patch_sha256"]}），如需新版本请重新审阅"}

      %{"state" => state} = application when state in @in_flight_states ->
        reconcile(task, application, patch_sha256, request_id)

      _ ->
        :fresh
    end
  end

  defp reconcile(task, application, patch_sha256, request_id) do
    with {:ok, workspace} <- workspace(task) do
      case reconcile_state(workspace["root"], application) do
        :untouched ->
          :fresh

        :applied ->
          if application["patch_sha256"] == patch_sha256,
            do: {:done, recover_applied(task, application, request_id)},
            else: {:error, "already_applied", "上一次应用已写入目标且版本不同（#{application["patch_sha256"]}），请重新审阅后再决定"}

        {:unknown, diagnostics} ->
          fail_reconcile(task, application, "state_unknown", diagnostics)
      end
    end
  end

  defp fail_reconcile(task, application, reason, diagnostics) do
    mark_unknown(task, application, %{"reason" => reason, "observed" => diagnostics})
    {:error, "apply_unknown", "上次应用的状态不确定（#{diagnostic_text(diagnostics)}）；已保留诊断，请核对已有改动后再决定"}
  end

  # 只看本次意图覆盖的文件：全部仍是 before → 没写过，可以安全地按原意图应用；
  # 全部 after → 已写完，回放同一回执；其余（含部分完成）→ 状态未知，保留诊断。
  defp reconcile_state(root, %{"files" => files}) when is_list(files) do
    states = Enum.map(files, fn file -> {file, observed_state(root, file)} end)

    cond do
      states == [] ->
        {:unknown, [%{"path" => nil, "observed" => "no_recorded_files"}]}

      Enum.all?(states, fn {_file, state} -> state == :after end) ->
        :applied

      Enum.all?(states, fn {_file, state} -> state == :before end) ->
        :untouched

      # 部分改变：每个文件都能确认，但不是「全部应用」也不是「全部未应用」。
      # 按设计保留诊断并拒绝盲目重试，由人核对后再重试（此时会走已应用/未应用分支）。
      true ->
        {:unknown, observed_diagnostics(states)}
    end
  end

  defp reconcile_state(_root, _application),
    do: {:unknown, [%{"path" => nil, "observed" => "missing_intent"}]}

  defp observed_diagnostics(states) do
    Enum.map(states, fn {file, state} ->
      %{"path" => file["path"], "observed" => Atom.to_string(state)}
    end)
  end

  defp diagnostic_text(list) when is_list(list) and list != [] do
    list
    |> Enum.map(fn entry -> "#{entry["path"] || "?"}=#{entry["observed"] || entry["reason"]}" end)
    |> Enum.join(", ")
    |> String.slice(0, 400)
  end

  defp diagnostic_text(_), do: "没有可核对的检查点"

  ## ── 目标核对 ────────────────────────────────────────────────────────────

  defp precheck(workspace, diff) do
    changes = diff["changes"]

    with :ok <- ensure_changes(changes),
         :ok <- ensure_size(changes),
         :ok <- real_directory(workspace["root"], "target_root"),
         :ok <- ensure_sources(workspace, changes) do
      conflicts =
        Enum.flat_map(changes, fn change ->
          case classify(change, workspace["root"]) do
            {"conflict", reason} -> [%{"path" => change["path"], "reason" => reason}]
            _ -> []
          end
        end)

      case conflicts do
        [] -> :ok
        list -> conflict_error(list)
      end
    end
  end

  defp conflict_error(list) do
    code =
      if Enum.any?(list, &(&1["reason"] == "symlink_not_allowed")),
        do: "symlink_not_allowed",
        else: "workspace_conflict"

    paths = list |> Enum.map(& &1["path"]) |> Enum.take(6) |> Enum.join(", ")
    {:error, code, "目标在审阅后发生变化（#{paths}）；现有文件已保留，请重新比较后再应用"}
  end

  defp ensure_changes([]), do: {:error, "no_changes", "工作区没有可应用的差异，无需应用"}

  defp ensure_changes(changes) when length(changes) > @max_apply_files,
    do: {:error, "workspace_too_large", "本次差异文件数超过单次应用上限（#{@max_apply_files}）"}

  defp ensure_changes(_), do: :ok

  defp ensure_size(changes) do
    total = changes |> Enum.map(fn change -> entry_size(change["after"]) end) |> Enum.sum()

    if total <= @max_apply_bytes,
      do: :ok,
      else: {:error, "workspace_too_large", "本次差异超过单次应用上限（#{@max_apply_bytes} 字节）"}
  end

  defp entry_size(nil), do: 0
  defp entry_size(%{"bytes" => bytes}) when is_integer(bytes) and bytes >= 0, do: bytes
  defp entry_size(entry), do: byte_size_or_nil(content_or_nil(entry)) || 0

  # 候选必须在应用前仍与审阅内容一致，防止审阅后工作区又被改写。
  defp ensure_sources(workspace, changes) do
    Enum.reduce_while(changes, :ok, fn change, :ok ->
      case change["kind"] do
        "deleted" ->
          {:cont, :ok}

        _ ->
          source = Path.join(workspace["path"], change["path"])
          expected = after_sha(change)

          case File.lstat(source) do
            {:ok, %File.Stat{type: :regular}} ->
              case File.read(source) do
                {:ok, content} ->
                  if is_binary(expected) and sha256(content) == expected,
                    do: {:cont, :ok},
                    else: {:halt, {:error, "stale_review", "候选内容已变化（#{change["path"]}），请重新比较"}}

                {:error, reason} ->
                  {:halt, {:error, "workspace_missing", "候选文件不可读 #{change["path"]}：#{inspect(reason)}"}}
              end

            {:ok, %File.Stat{type: :symlink}} ->
              {:halt, {:error, "symlink_not_allowed", "候选文件是符号链接：#{change["path"]}"}}

            {:ok, _other} ->
              {:halt, {:error, "stale_review", "候选文件类型已变化（#{change["path"]}），请重新比较"}}

            {:error, reason} ->
              {:halt, {:error, "workspace_missing", "候选文件缺失 #{change["path"]}：#{inspect(reason)}"}}
          end
      end
    end)
  end

  ## ── 写盘 ────────────────────────────────────────────────────────────────

  defp write_changes(task, workspace, intent) do
    result =
      Enum.reduce_while(intent["changes"], {:ok, []}, fn change, {:ok, done} ->
        case apply_change(workspace, change) do
          {:ok, outcome} ->
            receipt = change |> receipt_file() |> Map.put("outcome", Atom.to_string(outcome))
            {:cont, {:ok, done ++ [receipt]}}

          {:error, reason} ->
            {:halt, {:error, reason, change, done}}
        end
      end)

    case result do
      {:ok, applied} -> verify_and_finalize(task, workspace, intent, applied)
      {:error, reason, change, _done} -> fail_application(task, workspace, intent, reason, change)
    end
  end

  defp apply_change(workspace, change) do
    with :ok <- safe_relative(change["path"]),
         :ok <- reject_symlink_components(workspace["root"], change["path"]),
         {:ok, observed} <- target_state(workspace["root"], change["path"]) do
      decide(workspace, change, observed)
    end
  end

  defp decide(workspace, change, %{"state" => "missing"}) do
    case change["kind"] do
      "added" -> write_file(workspace, change)
      "deleted" -> {:ok, :already}
      _ -> {:error, "target_missing"}
    end
  end

  defp decide(workspace, change, %{"state" => "file"} = observed) do
    cond do
      observed["sha256"] == change["after_sha256"] and observed["mode"] == change["after_mode"] ->
        {:ok, :already}

      observed["sha256"] == change["before_sha256"] and observed["mode"] == change["before_mode"] ->
        write_or_delete(workspace, change)

      true ->
        {:error, "target_changed"}
    end
  end

  defp decide(_workspace, _change, _observed), do: {:error, "target_not_file"}

  defp write_or_delete(workspace, %{"kind" => "deleted"} = change) do
    target = Path.join(workspace["root"], change["path"])

    case File.rm(target) do
      :ok -> {:ok, :applied}
      {:error, :enoent} -> {:ok, :already}
      {:error, reason} -> {:error, "delete_failed: #{inspect(reason)}"}
    end
  end

  defp write_or_delete(workspace, change), do: write_file(workspace, change)

  defp write_file(workspace, change) do
    source = Path.join(workspace["path"], change["path"])
    target = Path.join(workspace["root"], change["path"])
    dir = Path.dirname(target)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(source),
         {:ok, content} <- File.read(source),
         :ok <- same_content(content, change["after_sha256"], change["path"]),
         :ok <- File.mkdir_p(dir),
         :ok <- reject_symlink_components(workspace["root"], change["path"]),
         :ok <- write_atomically(dir, target, content, change["after_mode"]) do
      {:ok, :applied}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "source_unreadable: #{inspect(reason)}"}
      other -> {:error, "source_unreadable: #{inspect(other)}"}
    end
  end

  defp same_content(content, expected, path) do
    if is_binary(expected) and sha256(content) == expected,
      do: :ok,
      else: {:error, "stale_review: 候选内容已变化（#{path}）"}
  end

  # 同目录临时文件 + rename：目标要么是旧内容要么是新内容，不留半写文件。
  defp write_atomically(dir, target, content, mode) do
    tmp = Path.join(dir, ".newbee-apply-" <> Integer.to_string(System.unique_integer([:positive])))

    with :ok <- File.write(tmp, content, [:binary]),
         :ok <- File.chmod(tmp, mode || 0o644),
         :ok <- File.rename(tmp, target),
         :ok <- verify_written(target, content, mode) do
      :ok
    else
      error ->
        File.rm(tmp)
        normalize_write_error(error)
    end
  end

  defp normalize_write_error({:error, reason}) when is_atom(reason),
    do: {:error, "write_failed: #{inspect(reason)}"}

  defp normalize_write_error(other), do: {:error, "write_failed: #{inspect(other)}"}

  defp verify_written(target, content, mode) do
    case File.lstat(target) do
      {:ok, %File.Stat{type: :regular, mode: observed_mode, size: size}} ->
        cond do
          size != byte_size(content) -> {:error, "verify_failed: size"}
          :erlang.band(observed_mode, 0o777) != (mode || 0o644) -> {:error, "verify_failed: mode"}
          true -> :ok
        end

      {:ok, _other} ->
        {:error, "verify_failed: not_regular"}

      {:error, reason} ->
        {:error, "verify_failed: #{inspect(reason)}"}
    end
  end

  defp verify_and_finalize(task, workspace, intent, applied) do
    if Enum.all?(intent["changes"], &(observed_state(workspace["root"], &1) == :after)) do
      receipt = build_receipt(task, workspace, intent, applied)

      case persist_applied(task, intent, receipt) do
        :ok -> {:ok, receipt}
        {:error, _code, _message} = error -> error
      end
    else
      fail_application(task, workspace, intent, "verify_failed", nil)
    end
  end

  defp fail_application(task, workspace, intent, reason, change) do
    observed =
      Enum.map(intent["changes"], fn recorded ->
        %{
          "path" => recorded["path"],
          "observed" => Atom.to_string(observed_state(workspace["root"], recorded))
        }
      end)

    state = if Enum.any?(observed, &(&1["observed"] == "after")), do: "partial", else: "failed"

    diagnostics = %{
      "reason" => reason,
      "path" => change && change["path"],
      "observed" => observed,
      "at" => now()
    }

    application =
      intent
      |> Map.drop(["changes"])
      |> Map.merge(%{"state" => state, "diagnostics" => diagnostics, "updated_at" => now()})

    _ = put_application(task["id"], application)

    {code, label} = error_label(reason)

    {:error, code, "应用未完成（#{label}）；已记录检查点与各文件实际状态，请核对已有改动后再决定，不要盲目重试"}
  end

  defp error_label("target_changed"), do: {"workspace_conflict", "目标已被修改"}
  defp error_label("target_missing"), do: {"workspace_conflict", "目标文件缺失"}
  defp error_label("target_not_file"), do: {"workspace_conflict", "目标不是普通文件"}
  defp error_label("symlink_not_allowed"), do: {"symlink_not_allowed", "路径包含符号链接"}
  defp error_label("unsafe_path"), do: {"unsafe_path", "路径越界"}
  defp error_label("stale_review"), do: {"stale_review", "候选内容已变化"}
  defp error_label("verify_failed"), do: {"apply_failed", "写入后校验失败"}
  defp error_label("no_changes"), do: {"no_changes", "没有可应用的差异"}
  defp error_label(other), do: {"apply_failed", other}

  ## ── 持久化 ──────────────────────────────────────────────────────────────

  defp persist_intent(task, workspace, diff, honey, request_id) do
    intent = %{
      "state" => "applying",
      "request_id" => request_id,
      "patch_sha256" => diff["patch_sha256"],
      "target_root" => workspace["root"],
      "workspace_path" => workspace["path"],
      "base_ref" => workspace["base_ref"],
      "honey_id" => honey["id"],
      "task_id" => task["id"],
      "context_revision" => task["context_revision"] || 0,
      "files" => Enum.map(diff["changes"], &intent_file/1),
      "changes" => diff["changes"],
      "attempts" => previous_attempts(task) + 1,
      "started_at" => now(),
      "updated_at" => now(),
      "receipt" => nil,
      "diagnostics" => nil
    }

    # 只落盘指纹与元数据；完整候选内容留在本次调用内，避免 Store 膨胀。
    result =
      Store.transaction(fn data ->
        case get_in(data, ["tasks", task["id"]]) do
          %{"status" => "pending_review"} = current ->
            if current["context_revision"] == task["context_revision"] and current["result"] == honey["id"] and
                 current["workspace"] == task["workspace"] do
              updated =
                current |> Map.put("application", Map.drop(intent, ["changes"])) |> Map.update("revision", 1, &(&1 + 1))

              {:ok, {:ok, updated}, put_in(data, ["tasks", task["id"]], updated)}
            else
              {:error, "stale_result", "审阅期间工作要求、成果或工作区已经变化，请重新核对"}
            end

          _ ->
            {:error, "stale_result", "工作已经离开待采用状态，请刷新"}
        end
      end)

    case result do
      {:ok, _task} -> {:ok, intent}
      {:error, _code, _message} = error -> error
    end
  end

  defp persist_applied(task, intent, receipt) do
    application =
      intent
      |> Map.drop(["changes"])
      |> Map.merge(%{
        "state" => "applied",
        "receipt" => receipt,
        "applied_at" => receipt["applied_at"],
        "updated_at" => now(),
        "diagnostics" => nil
      })

    result =
      Store.transaction(fn data ->
        case get_in(data, ["tasks", task["id"]]) do
          nil ->
            {:error, "not_found", "工作不存在"}

          current ->
            updated = Map.put(current, "application", application)
            data = put_in(data, ["tasks", task["id"]], updated)

            {data, _entry} =
              Store.put_entry(data, "trace", %{
                "colony_id" => current["colony_id"],
                "bee_id" => current["created_by"] || current["assigned_bee_id"],
                "task_id" => current["id"],
                "type" => "honey",
                "text" => "成果已应用到项目目录（#{length(receipt["files"])} 个文件）",
                "data" => %{
                  "patch_sha256" => receipt["patch_sha256"],
                  "application" => "applied",
                  "request_id" => receipt["request_id"]
                }
              })

            {:ok, {:ok, updated}, data}
        end
      end)

    case result do
      {:ok, _task} -> :ok
      other -> other
    end
  end

  defp mark_unknown(task, application, diagnostics) do
    next =
      application
      |> Map.drop(["changes"])
      |> Map.merge(%{
        "state" => "unknown",
        "diagnostics" => Map.put(diagnostics, "at", now()),
        "updated_at" => now()
      })

    _ = put_application(task["id"], next)
    :ok
  end

  defp put_application(task_id, application) when is_binary(task_id) do
    result =
      Store.transaction(fn data ->
        case get_in(data, ["tasks", task_id]) do
          nil ->
            {:error, "not_found", "工作不存在"}

          task ->
            updated = Map.put(task, "application", application)
            {:ok, {:ok, updated}, put_in(data, ["tasks", task_id], updated)}
        end
      end)

    case result do
      {:ok, task} -> {:ok, task}
      other -> other
    end
  end

  defp put_application(_task_id, _application), do: {:error, "not_found", "工作不存在"}

  defp previous_attempts(task) do
    case application_of(task)["attempts"] do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _ -> 0
    end
  end

  defp recover_applied(task, application, request_id) do
    receipt = %{
      "state" => "applied",
      "request_id" => application["request_id"],
      "patch_sha256" => application["patch_sha256"],
      "target_root" => application["target_root"],
      "workspace_path" => application["workspace_path"],
      "base_ref" => application["base_ref"],
      "task_id" => task["id"],
      "honey_id" => application["honey_id"],
      "context_revision" => application["context_revision"],
      "files" => Enum.map(application["files"] || [], &receipt_file/1),
      "applied_at" => application["applied_at"] || application["updated_at"] || now(),
      "recovered" => true,
      "idempotent" => true,
      "requested_request_id" => request_id
    }

    case persist_applied(task, application, receipt) do
      :ok -> receipt
      {:error, _code, _message} -> Map.put(receipt, "persist_failed", true)
    end
  end

  defp replay_receipt(application, request_id) do
    receipt =
      application["receipt"] ||
        %{
          "state" => "applied",
          "request_id" => application["request_id"],
          "patch_sha256" => application["patch_sha256"],
          "target_root" => application["target_root"],
          "workspace_path" => application["workspace_path"],
          "base_ref" => application["base_ref"],
          "files" => Enum.map(application["files"] || [], &receipt_file/1),
          "applied_at" => application["applied_at"] || application["updated_at"]
        }

    receipt
    |> Map.put("state", "applied")
    |> Map.put("idempotent", true)
    |> Map.put("requested_request_id", request_id)
  end

  defp build_receipt(task, workspace, intent, applied) do
    %{
      "state" => "applied",
      "request_id" => intent["request_id"],
      "patch_sha256" => intent["patch_sha256"],
      "target_root" => workspace["root"],
      "workspace_path" => workspace["path"],
      "base_ref" => workspace["base_ref"],
      "task_id" => task["id"],
      "honey_id" => intent["honey_id"],
      "context_revision" => intent["context_revision"],
      "files" => applied,
      "applied_at" => now(),
      "idempotent" => false
    }
  end

  ## ── 任务与成果校验 ──────────────────────────────────────────────────────

  # 一律以 Store 记录为准：调用方传进来的 workspace/status/honey 都不能作数。
  defp resolve(%{"id" => id}) when is_binary(id), do: fetch_task(id)
  defp resolve(_), do: {:error, "not_found", "需要一份已保存的 Colony 工作"}

  defp stored(%{"id" => id}) when is_binary(id), do: fetch_task(id)
  defp stored(_), do: {:error, "not_found", "工作没有 ID"}

  defp fetch_task(id) do
    case Store.get_task(id) do
      {:ok, task} when is_map(task) -> {:ok, task}
      _ -> {:error, "not_found", "工作不存在"}
    end
  end

  defp reviewable(%{"status" => "pending_review"} = task) do
    with {:ok, colony_id} <- text_field(task["colony_id"], "not_found", "工作不属于任何蜂群"),
         {:ok, _colony} <- colony(colony_id),
         {:ok, honey_id} <- text_field(task["result"], "review_required", "该工作还没有待验收成果"),
         {:ok, honey} <- honey(honey_id),
         :ok <- honey_matches_task(honey, task),
         :ok <- honey_state(honey),
         :ok <- honey_revision(honey, task) do
      {:ok, honey}
    end
  end

  defp reviewable(%{"status" => status}) when is_binary(status),
    do: {:error, "task_not_pending_review", "只有待验收的工作可以审阅或应用（当前 #{status}）"}

  defp reviewable(_), do: {:error, "not_found", "需要一份 Colony 工作"}

  defp colony(id) do
    case Store.get_colony(id) do
      {:ok, colony} when is_map(colony) -> {:ok, colony}
      _ -> {:error, "not_found", "蜂群不存在，不能冒充已有验收"}
    end
  end

  defp honey(id) do
    case Store.get_honey(id) do
      {:ok, honey} when is_map(honey) -> {:ok, honey}
      _ -> {:error, "review_required", "成果不存在或已被清理"}
    end
  end

  defp honey_matches_task(honey, task) do
    cond do
      honey["task_id"] != task["id"] -> {:error, "review_required", "成果不属于当前工作"}
      honey["colony_id"] != task["colony_id"] -> {:error, "review_required", "成果不属于当前蜂群"}
      true -> :ok
    end
  end

  defp honey_state(honey) do
    case get_in(honey, ["review", "state"]) do
      state when state in @reviewable_honey_states ->
        :ok

      state when state in ["accepted", "rejected"] ->
        {:error, "already_reviewed", "成果已验收完成，不能再应用"}

      _ ->
        {:error, "review_required", "成果状态不允许应用"}
    end
  end

  defp honey_revision(honey, task) do
    if honey["work_revision"] == (task["context_revision"] || 0),
      do: :ok,
      else: {:error, "stale_result", "要求已变化，需要重新核对成果后再应用"}
  end

  defp application_of(task) do
    case task["application"] do
      application when is_map(application) -> application
      _ -> %{}
    end
  end

  defp valid_request(request_id, sha) do
    cond do
      not is_binary(request_id) or not Regex.match?(@request_id_re, request_id) ->
        {:error, "bad_request", "request ID 缺失或含非法字符"}

      not is_binary(sha) or not Regex.match?(@sha_re, sha) ->
        {:error, "bad_request", "审阅 hash 必须是 64 位小写十六进制"}

      true ->
        :ok
    end
  end

  defp same_review(expected, actual) do
    if is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual) and
         Plug.Crypto.secure_compare(expected, actual),
       do: :ok,
       else: {:error, "stale_review", "候选与审阅版本不一致（hash 已变化），请重新比较后再应用"}
  rescue
    _ -> {:error, "stale_review", "审阅版本无效，请重新比较"}
  end

  ## ── 工作区与基线 ────────────────────────────────────────────────────────

  defp workspace(%{"workspace" => %{"kind" => "shared"}}),
    do: {:error, "not_reviewable", "该工作与用户共用目录，没有可审阅的独立差异"}

  defp workspace(%{"workspace" => %{"review_status" => "cleaned"}}),
    do: {:error, "workspace_cleaned", "独立工作区已清理，不能再审阅或应用"}

  defp workspace(%{"workspace" => workspace}) when is_map(workspace) do
    with :ok <- isolated(workspace),
         {:ok, root} <- absolute(workspace["root"]),
         {:ok, path} <- absolute(workspace["path"]),
         {:ok, base_ref} <- sha_ref(workspace["base_ref"]),
         :ok <- contained(root, path),
         :ok <- real_directory(root, "target_root"),
         :ok <- real_directory(path, "workspace") do
      {:ok, %{"kind" => workspace["kind"], "root" => root, "path" => path, "base_ref" => base_ref}}
    end
  end

  defp workspace(_), do: {:error, "workspace_missing", "工作没有独立的审阅工作区"}

  defp isolated(%{"kind" => kind}) when kind in @workspace_kinds, do: :ok

  defp isolated(%{"kind" => kind}),
    do: {:error, "workspace_invalid", "工作区类型 #{inspect(kind)} 不能审阅或应用"}

  defp isolated(_), do: {:error, "workspace_invalid", "工作区缺少类型"}

  defp absolute(value) when is_binary(value) and value != "" do
    if String.contains?(value, <<0>>),
      do: {:error, "workspace_invalid", "工作区路径无效"},
      else: {:ok, Path.expand(value)}
  end

  defp absolute(_), do: {:error, "workspace_invalid", "工作区路径缺失"}

  defp sha_ref(value) when is_binary(value) do
    if Regex.match?(@sha_re, value),
      do: {:ok, value},
      else: {:error, "workspace_invalid", "工作区基线引用无效"}
  end

  defp sha_ref(_), do: {:error, "workspace_invalid", "工作区缺少基线引用"}

  defp contained(root, path) do
    parent = Path.expand(Path.join([root, ".newbee", "workspaces"]))
    relative = Path.relative_to(path, parent)

    if relative != "." and not String.starts_with?(relative, "..") and Path.dirname(relative) == ".",
      do: :ok,
      else: {:error, "workspace_invalid", "工作区必须在项目 .newbee/workspaces 之下"}
  end

  defp real_directory(path, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, "symlink_not_allowed", "#{label} 不能是符号链接"}
      {:ok, _} -> {:error, "workspace_missing", "#{label} 不是目录"}
      {:error, reason} -> {:error, "workspace_missing", "#{label} 不可用：#{inspect(reason)}"}
    end
  end

  defp baseline(workspace) do
    sidecar = workspace["path"] <> ".base_snapshot.term"

    case File.read(sidecar) do
      {:ok, binary} ->
        decode_baseline(binary)

      {:error, :enoent} ->
        {:error, "workspace_snapshot_missing", "工作区缺少基线快照，不能安全比较"}

      {:error, reason} ->
        {:error, "workspace_snapshot_failed", "基线快照不可读：#{inspect(reason)}"}
    end
  end

  defp decode_baseline(binary) do
    snapshot = :erlang.binary_to_term(binary, [:safe])

    if is_map(snapshot) and
         Enum.all?(snapshot, fn {path, entry} -> is_binary(path) and is_map(entry) end),
       do: {:ok, snapshot},
       else: {:error, "workspace_snapshot_invalid", "基线快照结构无效"}
  rescue
    _ -> {:error, "workspace_snapshot_invalid", "基线快照无法解析"}
  end

  defp baseline_matches(workspace, base) do
    if Baseline.snapshot_digest(base) == workspace["base_ref"],
      do: :ok,
      else: {:error, "workspace_conflict", "工作区基线清单已变化，需要重新建立工作区"}
  end

  ## ── 差异 ────────────────────────────────────────────────────────────────

  defp diff(base, source) do
    changes =
      (Map.keys(base) ++ Map.keys(source))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        case change(path, Map.get(base, path), Map.get(source, path)) do
          nil -> []
          change -> [change]
        end
      end)

    with :ok <- validate_paths(changes),
         :ok <- validate_base_entries(base, changes) do
      {:ok, %{"changes" => changes, "patch_sha256" => patch_sha256(changes)}}
    end
  end

  defp change(_path, nil, nil), do: nil

  defp change(path, nil, after_entry),
    do: with_fingerprints(%{"path" => path, "kind" => "added", "before" => nil, "after" => after_entry})

  defp change(path, before_entry, nil),
    do: with_fingerprints(%{"path" => path, "kind" => "deleted", "before" => before_entry, "after" => nil})

  defp change(path, before_entry, after_entry) do
    if before_entry["sha256"] == after_entry["sha256"] and
         mode_of(before_entry) == mode_of(after_entry),
       do: nil,
       else:
         with_fingerprints(%{
           "path" => path,
           "kind" => "modified",
           "before" => before_entry,
           "after" => after_entry
         })
  end

  # 每个 change 都带扁平指纹：写盘/核对只看指纹，不再反复解码内容。
  defp with_fingerprints(change) do
    before_content = content_or_nil(change["before"])
    after_content = content_or_nil(change["after"])

    Map.merge(change, %{
      "before_sha256" => sha_or_nil(before_content),
      "before_mode" => mode_of(change["before"]),
      "before_bytes" => byte_size_or_nil(before_content),
      "after_sha256" => sha_or_nil(after_content),
      "after_mode" => mode_of(change["after"]),
      "after_bytes" => byte_size_or_nil(after_content)
    })
  end

  defp validate_paths(changes) do
    Enum.reduce_while(changes, :ok, fn change, :ok ->
      case safe_relative(change["path"]) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "unsafe_path", "工作区差异包含不安全路径 #{inspect(change["path"])}（#{reason}）"}}
      end
    end)
  end

  defp validate_base_entries(base, changes) do
    Enum.reduce_while(changes, :ok, fn change, :ok ->
      case Map.get(base, change["path"]) do
        nil ->
          {:cont, :ok}

        entry ->
          case snapshot_content(entry) do
            {:ok, content} ->
              if entry["sha256"] == sha256(content) and valid_mode?(entry),
                do: {:cont, :ok},
                else: {:halt, {:error, "workspace_snapshot_invalid", "基线条目损坏：#{change["path"]}"}}

            {:error, _reason} ->
              {:halt, {:error, "workspace_snapshot_invalid", "基线条目无法解码：#{change["path"]}"}}
          end
      end
    end)
  end

  # patch_sha256 覆盖完整真实差异：kind、路径、两侧 sha/权限与完整内容都在 hash 里。
  defp patch_sha256(changes) do
    changes
    |> Enum.reduce(:crypto.hash_init(:sha256), fn change, context ->
      before_content = content_or_nil(change["before"]) || <<>>
      after_content = content_or_nil(change["after"]) || <<>>

      context
      |> :crypto.hash_update([change["kind"], <<0>>, change["path"], <<0>>])
      |> :crypto.hash_update([
        sha_or_nil(before_content) || "-",
        <<0>>,
        Integer.to_string(mode_of(change["before"]) || 0),
        <<0>>,
        before_content,
        <<0>>
      ])
      |> :crypto.hash_update([
        sha_or_nil(after_content) || "-",
        <<0>>,
        Integer.to_string(mode_of(change["after"]) || 0),
        <<0>>,
        after_content,
        <<0>>
      ])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  ## ── 视图 ────────────────────────────────────────────────────────────────

  defp review_view(task, honey, workspace, diff) do
    changes = diff["changes"]
    views = Enum.map(changes, &file_view(&1, workspace["root"]))

    conflicts =
      for view <- views, is_binary(view["conflict_reason"]) do
        %{"path" => view["path"], "reason" => view["conflict_reason"]}
      end

    shown = Enum.take(views, @max_display_files)
    {display_patch, omitted} = display_patch(changes)
    application = application_of(task)

    %{
      "patch_sha256" => diff["patch_sha256"],
      "files" => shown,
      "file_count" => length(views),
      "omitted_files" => max(length(views) - length(shown), 0),
      "target_root" => workspace["root"],
      "workspace_path" => workspace["path"],
      "workspace_kind" => workspace["kind"],
      "base_ref" => workspace["base_ref"],
      "summary" => summary(views, conflicts),
      "conflicts" => conflicts,
      "conflict_count" => length(conflicts),
      "clean" => conflicts == [] and views != [],
      "no_changes" => views == [],
      "display_patch" => display_patch,
      "display_truncated" =>
        omitted > 0 or length(views) > @max_display_files or
          Enum.any?(views, &(&1["before_truncated"] or &1["after_truncated"])),
      "omitted_patch_files" => omitted,
      "apply_state" => application["state"] || "not_applied",
      "applied_patch_sha256" => application["patch_sha256"],
      "applied_at" => application["applied_at"],
      "task_id" => task["id"],
      "honey_id" => honey["id"],
      "context_revision" => task["context_revision"] || 0,
      "work_revision" => honey["work_revision"],
      "reviewed_at" => now(),
      "limits" => %{
        "files" => @max_display_files,
        "file_bytes" => @max_file_display_bytes,
        "patch_bytes" => @max_display_patch_bytes
      }
    }
  end

  defp summary(views, conflicts) do
    counts =
      Enum.reduce(views, %{"added" => 0, "modified" => 0, "deleted" => 0}, fn view, acc ->
        Map.update(acc, view["kind"], 1, &(&1 + 1))
      end)

    base =
      case views do
        [] ->
          "工作区没有文件变更"

        _ ->
          "共 #{length(views)} 个文件变更：新增 #{counts["added"]}、修改 #{counts["modified"]}、删除 #{counts["deleted"]}"
      end

    case conflicts do
      [] -> base <> "；目标与基线一致，可应用"
      list -> base <> "；#{length(list)} 个文件与目标冲突，需要重新比较"
    end
  end

  defp file_view(change, root) do
    before = change["before"]
    after_entry = change["after"]
    before_content = content_or_nil(before)
    after_content = content_or_nil(after_entry)
    {target_state, reason} = classify(change, root)

    %{
      "path" => change["path"],
      "kind" => change["kind"],
      "before" => display_content(before),
      "after" => display_content(after_entry),
      "before_truncated" => truncated?(before_content),
      "after_truncated" => truncated?(after_content),
      "before_bytes" => byte_size_or_nil(before_content),
      "after_bytes" => byte_size_or_nil(after_content),
      "before_sha256" => sha_or_nil(before_content),
      "after_sha256" => sha_or_nil(after_content),
      "before_mode" => mode_of(before),
      "after_mode" => mode_of(after_entry),
      "binary" => binary?(before) or binary?(after_entry),
      "added_lines" => line_delta(before_content, after_content, :added),
      "deleted_lines" => line_delta(before_content, after_content, :deleted),
      "target_state" => target_state,
      "conflict_reason" => reason
    }
  end

  defp display_patch(changes) do
    {chunks, _size, omitted} =
      Enum.reduce(changes, {[], 0, 0}, fn change, {chunks, size, omitted} ->
        if omitted > 0 do
          {chunks, size, omitted + 1}
        else
          text = render_change(change)
          remaining = @max_display_patch_bytes - size

          cond do
            byte_size(text) <= remaining ->
              {chunks ++ [text], size + byte_size(text), 0}

            remaining > 200 ->
              {chunks ++ [String.slice(text, 0, remaining) <> "\n… 展示已截断 …"], @max_display_patch_bytes, 1}

            true ->
              {chunks, size, 1}
          end
        end
      end)

    {Enum.join(chunks, "\n"), omitted}
  end

  defp render_change(change) do
    path = change["path"]

    if binary?(change["before"]) or binary?(change["after"]) do
      "Binary files " <>
        if(change["kind"] == "added", do: "/dev/null", else: "a/" <> path) <>
        " and " <> if(change["kind"] == "deleted", do: "/dev/null", else: "b/" <> path) <> " differ"
    else
      old = display_content(change["before"]) || ""
      new = display_content(change["after"]) || ""

      header =
        "--- " <>
          if(change["kind"] == "added", do: "/dev/null", else: "a/" <> path) <>
          "\n+++ " <> if(change["kind"] == "deleted", do: "/dev/null", else: "b/" <> path)

      old_body = old |> String.split("\n") |> Enum.map_join("\n", &("-" <> &1))
      new_body = new |> String.split("\n") |> Enum.map_join("\n", &("+" <> &1))

      header <> "\n" <> old_body <> if(old_body == "", do: "", else: "\n") <> new_body
    end
  end

  ## ── 文件级状态 ──────────────────────────────────────────────────────────

  defp classify(change, root) do
    case target_state(root, change["path"]) do
      {:ok, observed} -> classify_observed(change, observed)
      {:error, reason} -> {"conflict", reason}
    end
  end

  defp classify_observed(%{"kind" => "added"} = change, observed) do
    cond do
      observed["state"] == "missing" -> {"pending", nil}
      matches?(observed, change["after_sha256"], change["after_mode"]) -> {"applied", nil}
      true -> {"conflict", "target_exists"}
    end
  end

  defp classify_observed(%{"kind" => "deleted"} = change, observed) do
    cond do
      observed["state"] == "missing" -> {"applied", nil}
      matches?(observed, change["before_sha256"], change["before_mode"]) -> {"pending", nil}
      true -> {"conflict", "target_changed"}
    end
  end

  defp classify_observed(change, observed) do
    cond do
      observed["state"] == "missing" -> {"conflict", "target_missing"}
      matches?(observed, change["before_sha256"], change["before_mode"]) -> {"pending", nil}
      matches?(observed, change["after_sha256"], change["after_mode"]) -> {"applied", nil}
      true -> {"conflict", "target_changed"}
    end
  end

  defp matches?(_observed, nil, _mode), do: false

  defp matches?(observed, sha, mode) do
    observed["state"] == "file" and is_binary(sha) and observed["sha256"] == sha and
      observed["mode"] == mode
  end

  defp target_state(root, path) do
    with :ok <- safe_relative(path),
         :ok <- reject_symlink_components(root, path) do
      target = Path.join(Path.expand(root), path)

      case File.lstat(target) do
        {:ok, %File.Stat{type: :regular, mode: mode}} ->
          case File.read(target) do
            {:ok, content} ->
              {:ok,
               %{
                 "state" => "file",
                 "sha256" => sha256(content),
                 "bytes" => byte_size(content),
                 "mode" => :erlang.band(mode, 0o777)
               }}

            {:error, reason} ->
              {:error, "target_unreadable: #{inspect(reason)}"}
          end

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, "symlink_not_allowed"}

        {:ok, _other} ->
          {:error, "target_not_file"}

        {:error, :enoent} ->
          {:ok, %{"state" => "missing"}}

        {:error, reason} ->
          {:error, "target_unreadable: #{inspect(reason)}"}
      end
    end
  end

  defp observed_state(root, file) do
    case target_state(root, file["path"]) do
      {:ok, %{"state" => "missing"}} ->
        if file["after_sha256"] == nil, do: :after, else: :before

      {:ok, %{"state" => "file"} = observed} ->
        cond do
          observed["sha256"] == file["after_sha256"] and observed["mode"] == file["after_mode"] -> :after
          observed["sha256"] == file["before_sha256"] and observed["mode"] == file["before_mode"] -> :before
          true -> :unknown
        end

      {:error, _reason} ->
        :unknown
    end
  end

  defp reject_symlink_components(root, path) do
    root = Path.expand(root)

    path
    |> Path.split()
    |> Enum.reduce_while({:ok, root}, fn component, {:ok, current} ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, "symlink_not_allowed"}}
        {:ok, _stat} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:halt, {:ok, next}}
        {:error, reason} -> {:halt, {:error, "target_unreadable: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp safe_relative(path) when is_binary(path) do
    expanded = Path.expand(path, "/newbee-target")
    components = Path.split(path)

    if path != "" and byte_size(path) <= 1_024 and Path.type(path) == :relative and
         not String.contains?(path, <<0>>) and
         not Enum.any?(components, &(&1 in ["", ".", ".."])) and
         expanded != "/newbee-target" and String.starts_with?(expanded, "/newbee-target/"),
       do: :ok,
       else: {:error, "unsafe_path"}
  end

  defp safe_relative(_), do: {:error, "unsafe_path"}

  ## ── 小工具 ──────────────────────────────────────────────────────────────

  defp intent_file(change) do
    before_content = content_or_nil(change["before"])
    after_content = content_or_nil(change["after"])

    %{
      "path" => change["path"],
      "kind" => change["kind"],
      "before_sha256" => sha_or_nil(before_content),
      "before_mode" => mode_of(change["before"]),
      "before_bytes" => byte_size_or_nil(before_content),
      "after_sha256" => sha_or_nil(after_content),
      "after_mode" => mode_of(change["after"]),
      "after_bytes" => byte_size_or_nil(after_content)
    }
  end

  defp receipt_file(file) do
    %{
      "path" => file["path"],
      "kind" => file["kind"],
      "sha256" => file["after_sha256"],
      "bytes" => file["after_bytes"],
      "mode" => file["after_mode"]
    }
  end

  defp after_sha(change), do: sha_or_nil(content_or_nil(change["after"]))

  defp snapshot_content(%{"encoding" => "base64", "content" => content}) when is_binary(content) do
    case Base.decode64(content) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "invalid_base64"}
    end
  end

  defp snapshot_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp snapshot_content(_), do: {:error, "invalid_entry"}

  defp content_or_nil(nil), do: nil

  defp content_or_nil(entry) do
    case snapshot_content(entry) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  defp display_content(nil), do: nil

  defp display_content(entry) do
    if binary?(entry) do
      nil
    else
      case snapshot_content(entry) do
        {:ok, content} -> truncate(content)
        {:error, _reason} -> nil
      end
    end
  end

  defp truncate(content) when byte_size(content) <= @max_file_display_bytes, do: content
  defp truncate(content), do: String.slice(content, 0, @max_file_display_bytes)

  defp truncated?(nil), do: false
  defp truncated?(content), do: byte_size(content) > @max_file_display_bytes

  defp binary?(%{"encoding" => "base64"}), do: true
  defp binary?(_), do: false

  defp mode_of(nil), do: nil
  defp mode_of(%{"mode" => mode}) when is_integer(mode) and mode >= 0 and mode <= 0o777, do: mode
  defp mode_of(_), do: 0o644

  defp valid_mode?(%{"mode" => mode}), do: is_integer(mode) and mode >= 0 and mode <= 0o777
  defp valid_mode?(_), do: true

  defp sha256(content) when is_binary(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp sha_or_nil(nil), do: nil
  defp sha_or_nil(content) when is_binary(content), do: sha256(content)

  defp byte_size_or_nil(nil), do: nil
  defp byte_size_or_nil(content) when is_binary(content), do: byte_size(content)

  defp line_delta(before_content, after_content, :added),
    do: max(line_count(after_content) - line_count(before_content), 0)

  defp line_delta(before_content, after_content, :deleted),
    do: max(line_count(before_content) - line_count(after_content), 0)

  defp line_count(nil), do: 0
  defp line_count(content), do: length(String.split(content, "\n"))

  defp text_field(value, _code, _message) when is_binary(value) and value != "", do: {:ok, value}
  defp text_field(_value, code, message), do: {:error, code, message}

  defp now, do: System.system_time(:millisecond)
end
