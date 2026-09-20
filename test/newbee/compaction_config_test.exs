defmodule Newbee.Compaction.ConfigTest do
  use ExUnit.Case, async: true
  alias Newbee.Compaction.Config

  test "missing config is legacy" do
    assert {:ok, config} = Config.resolve(nil)
    assert config.mode == :legacy
    assert config.warning == nil
    refute Map.has_key?(config, :api_key)
  end

  test "explicit jev uses documented defaults" do
    assert {:ok, config} = Config.resolve(%{"mode" => "jev"})
    assert config.mode == :jev
    assert config.model == "jev-latest"
    assert config.api_key_env == "TYPESAFE_API_KEY"
    assert config.keep_threshold == 0.5
    assert config.preserve_recent_messages == 8
    assert config.max_candidates == 64
    assert config.max_state_tokens == 20_000
    assert config.max_request_tokens == 28_000
    assert config.max_batches == 2
    assert config.request_timeout_ms == 3_000
    assert config.total_timeout_ms == 6_000
    assert config.failure_threshold == 3
    assert config.cooldown_ms == 60_000
    assert config.truncate_head_chars == 200
    assert config.truncate_tail_chars == 200
    assert config.min_reduction_ratio == 0.10
  end

  test "test env does not auto-enable without explicit mode" do
    config = Config.load(raw_config: nil)
    assert config.mode == :legacy
  end

  test "auto-enable turns unspecified mode into jev" do
    config = Config.load(raw_config: nil, auto_enable: true)
    assert config.mode == :jev
    refute Map.has_key?(config, :api_key)
  end

  test "explicit legacy is not auto-enabled" do
    config = Config.load(raw_config: %{"mode" => "legacy"}, auto_enable: true)
    assert config.mode == :legacy
  end

  test "plaintext apiKey is rejected" do
    assert {:error, :plaintext_api_key} = Config.resolve(%{"mode" => "jev", "apiKey" => "secret"})
    loaded = Config.load(raw_config: %{"mode" => "jev", "jev" => %{"apiKey" => "secret"}})
    assert loaded.mode == :legacy
    assert loaded.warning == :plaintext_api_key
    refute inspect(loaded) =~ "secret"
  end

  test "invalid types and cross-field conflicts fall back" do
    loaded = Config.load(raw_config: %{"mode" => "nope"})
    assert loaded.mode == :legacy
    assert loaded.warning == :invalid_mode

    loaded = Config.load(raw_config: %{"mode" => "jev", "jev" => %{"keepThreshold" => 2}})
    assert loaded.mode == :legacy
    assert match?({:invalid_field, :keep_threshold}, loaded.warning)

    loaded =
      Config.load(raw_config: %{"mode" => "jev", "jev" => %{"maxStateTokens" => 24_000, "maxRequestTokens" => 20_000}})

    assert loaded.mode == :legacy
    assert loaded.warning == :state_tokens_not_below_request
  end
end
