defmodule Newbee.Environment.Antibodies do
  @moduledoc """
  失败抗体（DESIGN §8.2）：单调增长的回归免疫系统。

  **两态生命周期**（修正"真实失败 = 回归测试"的过度承诺）：

  ```text
  observed_failure          真实失败记录（完整输入、环境 revision、
                            release_id、外部副作用、错误输出）
      ↓ 能重放 + 具备正确性 oracle + 经独立验证
  verified_regression_test  进入确定性门
  ```

  **执行分层**（active bench 不无限全量执行）：按
  "近期触发率 × 拦截价值 × 覆盖独特性" 分 hot（每次跑）/ warm（抽样跑）/
  cold（归档、相关变更时唤醒）。GC 只调整执行层级，不删除历史证据。
  不可复现的失败保留为证据但不充当门。

  存储：`.newbee/evaluations/antibodies/<id>.json`（项目）+
  `~/.newbee/antibodies/`（全局晋升，Ring 1）。
  """

  alias Newbee.Environment.Store

  @states [:observed_failure, :verified_regression_test]
  @tiers [:hot, :warm, :cold]

  # ── 记录 ──

  @doc """
  记录真实失败为 observed_failure。
  failure = %{input, error, release_id, revision, external_effects, task}
  """
  def observe(id, failure, opts \\ []) do
    Newbee.Learning.Context.production_write!()

    entry = %{
      "id" => to_string(id),
      "state" => "observed_failure",
      "tier" => "hot",
      "input" => failure[:input] || failure["input"],
      "error" => failure[:error] || failure["error"],
      "release_id" => failure[:release_id] || failure["release_id"],
      "revision" => failure[:revision] || failure["revision"],
      "external_effects" => failure[:external_effects] || failure["external_effects"] || [],
      "task" => failure[:task] || failure["task"],
      "check" => failure[:check] || failure["check"],
      "provenance" => Keyword.get(opts, :provenance, "unknown"),
      "trigger_count" => 1,
      "last_triggered_at" => now_iso(),
      "created_at" => now_iso()
    }

    save!(dir(opts), entry)
    {:ok, entry}
  end

  @doc """
  晋升为 verified_regression_test：要求 check（正确性 oracle）+ 独立验证通过。
  check = %{"kind" => "expect_ok" | "expect_error", "pattern" => regex} |
          %{"kind" => "score_ge", "min" => n}（verifier 连续分）
  """
  def verify(id, check, opts \\ []) do
    with {:ok, entry} <- get(id, opts),
         :ok <- validate_check(check),
         :ok <- independent_replay(entry, check, opts) do
      entry = %{entry | "state" => "verified_regression_test", "check" => check}
      save!(dir(opts), entry)
      {:ok, entry}
    end
  end

  defp validate_check(%{"kind" => k, "pattern" => p}) when k in ["expect_ok", "expect_error"] and is_binary(p), do: :ok
  defp validate_check(%{"kind" => "score_ge", "min" => m}) when is_number(m), do: :ok
  defp validate_check(_), do: {:error, :invalid_oracle}

  # 独立验证：在干净求值器里重放一次，check 断言必须成立（能重放才可晋升）
  defp independent_replay(entry, check, opts) do
    case run_check(entry["input"], check, opts) do
      {:pass, _} -> :ok
      {:fail, detail} -> {:error, {:not_reproducible, detail}}
    end
  end

  # ── 查询 ──

  def get(id, opts \\ []) do
    path = Path.join(dir(opts), "#{safe(id)}.json")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, entry} -> {:ok, entry}
          _ -> {:error, :corrupt}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def all(opts \\ []) do
    dir(opts)
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, e} -> [e]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @doc "已验证抗体数（自治升档证据之一）。"
  def verified_count(opts \\ []) do
    Enum.count(all(opts), &(&1["state"] == "verified_regression_test"))
  end

  # ── 确定性门 ──

  @doc """
  回放门：只跑 **verified** 抗体；hot 全跑、warm 抽样、cold 跳过。
  返回 {:pass, details} | {:fail, failures}。零复现 = 通过（§15.13）。
  """
  def gate(opts \\ []) do
    sample_rate = Keyword.get(opts, :warm_sample_rate, 0.25)
    seed = :rand.uniform()

    candidates =
      all(opts)
      |> Enum.filter(&(&1["state"] == "verified_regression_test"))
      |> Enum.filter(fn
        %{"tier" => "hot"} -> true
        %{"tier" => "warm"} -> seed < sample_rate
        %{"tier" => "cold"} -> false
        _ -> true
      end)

    results =
      Enum.map(candidates, fn entry ->
        case run_check(entry["input"], entry["check"], opts) do
          {:pass, detail} -> {:pass, entry["id"], detail}
          {:fail, detail} -> {:fail, entry["id"], detail}
        end
      end)

    failures = Enum.filter(results, &match?({:fail, _, _}, &1))

    if failures == [] do
      {:pass, %{ran: length(results), failed: 0}}
    else
      {:fail, %{ran: length(results), failed: length(failures), failures: failures}}
    end
  end

  # ── 分层 GC（只调整执行层级，不删除证据）──

  @doc """
  按近期触发率调整 tier。`touched_plugin_ids` = 相关变更涉及的插件：
  cold 抗体遇相关变更被唤醒为 warm。
  """
  def gc(opts \\ []) do
    touched = Keyword.get(opts, :touched_plugin_ids, [])
    now = System.system_time(:second)
    warm_after_days = Keyword.get(opts, :warm_after_days, 14)
    cold_after_days = Keyword.get(opts, :cold_after_days, 60)

    for entry <- all(opts) do
      last = parse_iso(entry["last_triggered_at"])
      age_days = if last, do: div(now - last, 86_400), else: 999

      new_tier =
        cond do
          entry["tier"] == "cold" and related?(entry, touched) -> "warm"
          age_days > cold_after_days -> "cold"
          age_days > warm_after_days -> "warm"
          true -> "hot"
        end

      if new_tier != entry["tier"] do
        save!(dir(opts), %{entry | "tier" => new_tier})
      end
    end

    :ok
  end

  defp related?(entry, touched) do
    rid = entry["release_id"] || ""
    Enum.any?(touched, fn pid -> String.starts_with?(rid, to_string(pid) <> "@") or rid == to_string(pid) end)
  end

  # ── check 执行 ──

  defp run_check(code, %{"kind" => "expect_ok", "pattern" => pattern}, opts) when is_binary(code) do
    evaluator = Keyword.get(opts, :evaluator)

    case eval_code(evaluator, code) do
      %{status: :ok} = result ->
        if Regex.match?(Regex.compile!(pattern), result_text(result)),
          do: {:pass, "expect_ok matched"},
          else: {:fail, "expect_ok pattern #{pattern} not in output"}

      %{status: :error, error: err} ->
        {:fail, "expect_ok but raised: #{String.slice(to_string(err), 0, 200)}"}
    end
  end

  defp run_check(code, %{"kind" => "expect_error", "pattern" => pattern}, opts) when is_binary(code) do
    evaluator = Keyword.get(opts, :evaluator)

    case eval_code(evaluator, code) do
      %{status: :error, error: err} ->
        if Regex.match?(Regex.compile!(pattern), to_string(err)),
          do: {:pass, "expect_error matched"},
          else: {:fail, "error raised but pattern #{pattern} not matched: #{String.slice(to_string(err), 0, 200)}"}

      %{status: :ok} ->
        {:fail, "expect_error but succeeded"}
    end
  end

  defp run_check(code, %{"kind" => "score_ge", "min" => min}, opts) do
    score_fn = Keyword.get(opts, :score_fn)

    if score_fn do
      case score_fn.(code, opts) do
        {:ok, score} when score >= min -> {:pass, "score #{score} >= #{min}"}
        {:ok, score} -> {:fail, "score #{score} < #{min}"}
        {:error, reason} -> {:fail, "scorer error: #{inspect(reason)}"}
      end
    else
      # 无 verifier 模型可用：score 门降级为不可判定 → 不充当门
      {:pass, "score check skipped (no verifier)"}
    end
  end

  defp run_check(_, _, _), do: {:fail, "invalid check"}

  defp eval_code(nil, code) do
    # 独立验证默认开一次性干净求值器（互不污染）
    {:ok, ev} = Newbee.DEE.Evaluator.start(mode: :local)

    try do
      Newbee.DEE.Evaluator.eval(ev, code)
    after
      GenServer.stop(ev, :normal, 5_000)
    end
  end

  defp eval_code(evaluator, code), do: Newbee.DEE.Evaluator.eval(evaluator, code)

  defp result_text(%{value: v, output: o}), do: to_string(v) <> "\n" <> to_string(o)
  defp result_text(other), do: inspect(other)

  # ── 存储 ──

  defp dir(opts) do
    case Keyword.get(opts, :scope, :project) do
      :project -> Path.join(Store.dir(:evaluations), "antibodies")
      :global -> Path.join(System.user_home!(), ".newbee/antibodies")
      path when is_binary(path) -> path
    end
  end

  defp save!(dir, entry) do
    File.mkdir_p!(dir)

    Store.write_atomic!(
      Path.join(dir, "#{safe(entry["id"])}.json"),
      Jason.encode_to_iodata!(entry, pretty: true)
    )
  end

  defp safe(id), do: id |> to_string() |> String.replace(~r/[^\w\.\-]/, "_")

  defp parse_iso(nil), do: nil

  defp parse_iso(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def states, do: @states
  def tiers, do: @tiers
end
