defmodule Newbee.Environment.Calibration do
  @moduledoc """
  校准投影（TCE 总纲 D 节，[D8][D11][D18]）：
  编译决策的"预测 vs 实测"对账系统——环境元学习的最小闭环。

  - `record/3`：编译 Change 提交时记录预测快照（predicted_save、后验参数、决策上下文）；
  - `settle/2`：实测数据回流后结算一次预测（相对平方误差 = (pred-realized)²/pred²）；
  - `score/1`：全部历史预测的 Brier 式均分；
  - `converging?/2`：滑动窗口内分数单调不增或低于阈值 → 收敛；
  - `adjust_compile_cost/1`：偏差超阈 → 编译成本估计上调（学习率 α），供 tce_hot_needs 使用。

  依据 R9：proper scoring rule 使系统性高报无利可图。
  """

  alias Newbee.Environment.Store

  @store_file "calibration.jsonl"
  # 学习率 α 与收敛窗口/阈值（§16 配置参数精神，非架构常量）
  @alpha 0.25
  @window 5
  @threshold 0.5

  defstruct path: nil

  # ── 记录 ──

  @doc """
  记录一条预测。id 为编译 Change 的 change_id 或 release_id；
  predicted_save 为 PatternStats 后验中位数（期望节省 token/单位时间）；
  meta 任意 JSON 可编码上下文（pattern/task_type/kappa 等）。
  """
  def record(id, predicted_save, meta \\ %{}) when is_number(predicted_save) do
    entry = %{
      "id" => to_string(id),
      "predicted_save" => predicted_save * 1.0,
      "meta" => meta,
      "at" => now_iso(),
      "settled" => false,
      "error" => nil
    }

    append(entry)
  end

  # ── 结算 ──

  @doc "实测 realized 回流后结算 id 对应的预测。返回更新后的 entry。"
  def settle(id, realized_save) when is_number(realized_save) do
    entries = read_all()

    entries
    |> Enum.map(fn e ->
      if e["id"] == to_string(id) and not e["settled"] do
        pred = e["predicted_save"] |> max(1.0)
        rel_err = :math.pow(pred - realized_save, 2) / (pred * pred)
        Map.merge(e, %{"settled" => true, "realized_save" => realized_save * 1.0, "error" => rel_err})
      else
        e
      end
    end)
    |> write_all()

    settled(entries, id)
  end

  defp settled(entries, id) do
    Enum.find(entries, fn e -> e["id"] == to_string(id) and e["settled"] end) ||
      Enum.find(read_all(), fn e -> e["id"] == to_string(id) and e["settled"] end)
  end

  # ── 评分 ──

  @doc "全部已结算预测的平均相对平方误差（Brier 式）。无样本时 nil。"
  def score do
    errs = read_all() |> Enum.filter(& &1["settled"]) |> Enum.map(& &1["error"])

    if errs == [], do: nil, else: Enum.sum(errs) / length(errs)
  end

  @doc "最近 window 个已结算误差序列（时间序）。"
  def recent_errors(window \\ @window) do
    read_all()
    |> Enum.filter(& &1["settled"])
    |> Enum.sort_by(& &1["at"])
    |> Enum.take(-window)
    |> Enum.map(& &1["error"])
  end

  @doc "收敛判据 [D18]：滑窗内平均分低于阈值，或后半段不高于前半段（单调不增趋势）。"
  def converging?(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @threshold)
    window = Keyword.get(opts, :window, @window)

    case recent_errors(window) do
      [] ->
        false

      errs ->
        avg = Enum.sum(errs) / length(errs)

        if avg <= threshold do
          true
        else
          half = div(length(errs), 2)

          if half == 0 do
            false
          else
            {front, back} = Enum.split(errs, half)
            front_avg = Enum.sum(front) / max(length(front), 1)
            back_avg = Enum.sum(back) / max(length(back), 1)
            back_avg <= front_avg
          end
        end
    end
  end

  @doc "偏差驱动编译成本调整 [D18]：base_cost × (1 + α×avg_error)，封顶 ×3。"
  def adjust_compile_cost(base_cost, opts \\ []) do
    alpha = Keyword.get(opts, :alpha, @alpha)

    case recent_errors(@window) do
      [] ->
        base_cost

      errs ->
        avg = Enum.sum(errs) / length(errs)
        factor = min(1.0 + alpha * avg, 3.0)
        trunc(base_cost * factor)
    end
  end

  # ── 存储 ──

  defp path, do: Path.join([Store.dir(:evaluations), "pattern_stats", @store_file])

  defp append(entry) do
    File.mkdir_p!(Path.dirname(path()))
    Store.append_jsonl!(path(), entry)
    entry
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp read_all do
    case File.read(path()) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, m} -> [m | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp write_all(entries) do
    content = entries |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    Store.write_atomic!(path(), content <> "\n")
  rescue
    _ -> :error
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
