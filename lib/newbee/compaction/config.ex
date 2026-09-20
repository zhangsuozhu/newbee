defmodule Newbee.Compaction.Config do
  @moduledoc """
  压缩配置解析与默认值。非法输入回落 legacy，不读取或返回 API key。
  """

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @api_key_env "TYPESAFE_API_KEY"
  @model "jev-latest"

  @keep_threshold 0.5
  @preserve_recent_messages 8
  @max_candidates 64
  @max_state_tokens 20_000
  @max_request_tokens 28_000
  @max_batches 2
  @request_timeout_ms 3_000
  @total_timeout_ms 6_000
  @failure_threshold 3
  @cooldown_ms 60_000
  @truncate_head_chars 200
  @truncate_tail_chars 200
  @min_reduction_ratio 0.10
  @max_records 128
  @max_recovery_bytes 1 * 1024 * 1024
  @max_projection_bytes 1 * 1024 * 1024
  @max_response_bytes 256 * 1024

  def endpoint, do: @endpoint
  def max_records, do: @max_records
  def max_recovery_bytes, do: @max_recovery_bytes
  def max_projection_bytes, do: @max_projection_bytes
  def max_response_bytes, do: @max_response_bytes
  def default_api_key_env, do: @api_key_env
  def default_model, do: @model

  @doc "唯一默认配置来源。"
  def legacy do
    %{
      mode: :legacy,
      warning: nil,
      api_key_env: @api_key_env,
      api_key_provider: "typesafe",
      model: @model,
      keep_threshold: @keep_threshold,
      preserve_recent_messages: @preserve_recent_messages,
      max_candidates: @max_candidates,
      max_state_tokens: @max_state_tokens,
      max_request_tokens: @max_request_tokens,
      max_batches: @max_batches,
      request_timeout_ms: @request_timeout_ms,
      total_timeout_ms: @total_timeout_ms,
      failure_threshold: @failure_threshold,
      cooldown_ms: @cooldown_ms,
      truncate_head_chars: @truncate_head_chars,
      truncate_tail_chars: @truncate_tail_chars,
      min_reduction_ratio: @min_reduction_ratio
    }
  end

  @doc """
  加载配置。opts 可注入 `:raw_config`；异常或非法字段回落 legacy，并带固定 warning。
  """
  def load(opts \\ []) do
    raw =
      case Keyword.fetch(opts, :raw_config) do
        {:ok, value} -> value
        :error -> compaction_raw()
      end

    auto? = Keyword.get(opts, :auto_enable, Mix.env() != :test)

    case resolve(raw) do
      {:ok, config} -> maybe_auto_enable(config, raw, auto?)
      {:error, reason} -> Map.put(legacy(), :warning, reason)
    end
  rescue
    _ -> Map.put(legacy(), :warning, :load_failed)
  catch
    _, _ -> Map.put(legacy(), :warning, :load_failed)
  end

  @doc "纯函数校验。raw 缺省得到 legacy；未知 mode 与非法配置返回 error。"
  def resolve(raw) when raw in [nil, %{}] do
    {:ok, legacy()}
  end

  def resolve(raw) when is_map(raw) do
    if plaintext_key?(raw) do
      {:error, :plaintext_api_key}
    else
      resolve_mode(raw)
    end
  end

  def resolve(_), do: {:error, :invalid_config}

  defp resolve_mode(raw) do
    mode = Map.get(raw, "mode") || Map.get(raw, :mode)

    case normalize_mode(mode) do
      :legacy when is_nil(mode) -> {:ok, legacy()}
      :legacy -> merge_jev(legacy(), jev_raw(raw), :legacy)
      :jev -> merge_jev(%{legacy() | mode: :jev}, jev_raw(raw), :jev)
      :error -> {:error, :invalid_mode}
    end
  end

  defp merge_jev(base, jev_raw, mode) do
    with {:ok, fields} <- parse_jev(jev_raw) do
      config = base |> Map.merge(fields) |> Map.put(:mode, mode)

      cond do
        config.max_state_tokens >= config.max_request_tokens ->
          {:error, :state_tokens_not_below_request}

        config.request_timeout_ms > config.total_timeout_ms ->
          {:error, :request_timeout_exceeds_total}

        true ->
          {:ok, config}
      end
    end
  end

  defp parse_jev(raw) when raw in [nil, %{}], do: {:ok, %{}}

  defp parse_jev(raw) when is_map(raw) do
    if plaintext_key?(raw) do
      {:error, :plaintext_api_key}
    else
      reductions = [
        {"apiKeyEnv", :api_key_env, &nonempty_string/1},
        {"apiKeyProvider", :api_key_provider, &nonempty_string/1},
        {"model", :model, &nonempty_string/1},
        {"keepThreshold", :keep_threshold, &ratio/1},
        {"preserveRecentMessages", :preserve_recent_messages, &int_in(&1, 2, 64)},
        {"maxCandidates", :max_candidates, &int_in(&1, 1, 128)},
        {"maxStateTokens", :max_state_tokens, &int_in(&1, 1_000, 25_000)},
        {"maxRequestTokens", :max_request_tokens, &int_in(&1, 2_000, 30_000)},
        {"maxBatches", :max_batches, &int_in(&1, 1, 4)},
        {"requestTimeoutMs", :request_timeout_ms, &int_in(&1, 100, 10_000)},
        {"totalTimeoutMs", :total_timeout_ms, &int_in(&1, 100, 20_000)},
        {"failureThreshold", :failure_threshold, &int_in(&1, 1, 10)},
        {"cooldownMs", :cooldown_ms, &int_in(&1, 1_000, 600_000)},
        {"truncateHeadChars", :truncate_head_chars, &int_in(&1, 0, 1_000)},
        {"truncateTailChars", :truncate_tail_chars, &int_in(&1, 0, 1_000)},
        {"minReductionRatio", :min_reduction_ratio, &ratio/1}
      ]

      Enum.reduce_while(reductions, {:ok, %{}}, fn {json_key, atom_key, parser}, {:ok, acc} ->
        value = Map.get(raw, json_key) || Map.get(raw, atom_key)

        cond do
          is_nil(value) ->
            {:cont, {:ok, acc}}

          true ->
            case parser.(value) do
              {:ok, parsed} -> {:cont, {:ok, Map.put(acc, atom_key, parsed)}}
              :error -> {:halt, {:error, {:invalid_field, atom_key}}}
            end
        end
      end)
    end
  end

  defp parse_jev(_), do: {:error, :invalid_jev_config}

  defp jev_raw(raw) do
    Map.get(raw, "jev") || Map.get(raw, :jev)
  end

  defp compaction_raw do
    cfg = Newbee.LLM.Config.load()
    Map.get(cfg, "compaction") || Map.get(cfg, :compaction)
  end

  defp normalize_mode(nil), do: :legacy
  defp normalize_mode("legacy"), do: :legacy
  defp normalize_mode(:legacy), do: :legacy
  defp normalize_mode("jev"), do: :jev
  defp normalize_mode(:jev), do: :jev
  defp normalize_mode(_), do: :error

  defp plaintext_key?(raw) when is_map(raw) do
    Enum.any?(["apiKey", "api_key", :apiKey, :api_key], &Map.has_key?(raw, &1)) or
      case Map.get(raw, "jev") || Map.get(raw, :jev) do
        inner when is_map(inner) ->
          Enum.any?(["apiKey", "api_key", :apiKey, :api_key], &Map.has_key?(inner, &1))

        _ ->
          false
      end
  end

  defp nonempty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: {:ok, trimmed}, else: :error
  end

  defp nonempty_string(_), do: :error

  defp ratio(value) when is_integer(value), do: ratio(value / 1)

  defp ratio(value) when is_float(value) and value >= 0 and value <= 1 do
    if value == trunc(value) * 1.0 or Float.round(value, 10) == value do
      {:ok, value}
    else
      {:ok, value}
    end
  end

  defp ratio(value) when is_float(value), do: :error
  defp ratio(_), do: :error

  defp int_in(value, min, max) when is_integer(value) and value >= min and value <= max, do: {:ok, value}
  defp int_in(_, _, _), do: :error

  defp maybe_auto_enable(config, raw, true) do
    if explicit_mode?(raw), do: config, else: %{config | mode: :jev}
  end

  defp maybe_auto_enable(config, _raw, _), do: config

  defp explicit_mode?(raw) when is_map(raw), do: Map.has_key?(raw, "mode") or Map.has_key?(raw, :mode)
  defp explicit_mode?(_), do: false
end
