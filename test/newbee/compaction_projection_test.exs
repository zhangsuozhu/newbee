defmodule Newbee.Compaction.ProjectionTest do
  use ExUnit.Case, async: true
  alias Newbee.Compaction.{Config, Policy, Projection}

  defp messages do
    [
      %{"role" => "system", "content" => "base prompt"},
      %{"role" => "user", "content" => "do not rewrite me"},
      %{
        "role" => "assistant",
        "content" => "I will call tools",
        "tool_calls" => [
          tool("keep", "keep()"),
          tool("drop_r", "drop_r()"),
          tool("drop_c", "drop_c()")
        ]
      },
      %{"role" => "tool", "tool_call_id" => "keep", "content" => "KEEP_FULL"},
      %{"role" => "tool", "tool_call_id" => "drop_r", "content" => String.duplicate("R", 800)},
      %{"role" => "tool", "tool_call_id" => "drop_c", "content" => String.duplicate("C", 800)},
      %{"role" => "user", "content" => "thanks"}
    ]
  end

  defp tool(id, code) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code})}
    }
  end

  defp records(messages) do
    index = Policy.index_calls(messages)
    {:ok, config} = Config.resolve(%{"mode" => "jev"})
    drop_r = index["drop_r"]
    drop_c = index["drop_c"]
    replacement = Projection.replacement(drop_r.result["content"], "a" <> String.duplicate("b", 63), config)
    refute replacement == :keep

    [
      %{
        tool_call_id: "drop_r",
        source_sha: drop_r.source_sha,
        action: :drop_result,
        recovery_id: "a" <> String.duplicate("b", 63),
        head_chars: 200,
        tail_chars: 200,
        replacement: replacement
      },
      %{
        tool_call_id: "drop_c",
        source_sha: drop_c.source_sha,
        action: :drop_call,
        recovery_id: "c" <> String.duplicate("d", 63)
      }
    ]
  end

  test "keeps non-tool text byte-for-byte and only rewrites declared tools" do
    before = messages()
    recs = records(before)
    source = %{calls: Policy.index_calls(before)}
    assert {:ok, after_msgs, stats} = Projection.apply(before, recs, source: source)
    assert stats.results_dropped == 1
    assert stats.calls_dropped == 1
    user = Enum.find(after_msgs, &(&1["content"] == "do not rewrite me"))
    assert user == Enum.at(before, 1)
    assistant = Enum.find(after_msgs, &(&1["role"] == "assistant"))
    ids = Enum.map(assistant["tool_calls"], & &1["id"])
    assert ids == ["keep", "drop_r"]
    drop_r = Enum.find(after_msgs, &(&1["tool_call_id"] == "drop_r"))
    assert drop_r["content"] =~ "spill://"
    refute Enum.any?(after_msgs, &(&1["tool_call_id"] == "drop_c"))

    catalog =
      Enum.find(
        after_msgs,
        &(is_binary(&1["content"]) and String.starts_with?(&1["content"], Projection.catalog_prefix()))
      )

    assert catalog
    assert catalog["content"] =~ "drop_c"
    assert :ok = Projection.validate(before, after_msgs, recs)
  end

  test "short results are not replaced with longer text" do
    {:ok, config} = Config.resolve(%{"mode" => "jev"})
    assert Projection.replacement("tiny", String.duplicate("a", 64), config) == :keep
  end

  test "strip_catalog only removes the exact generated catalog" do
    before = messages()
    recs = records(before)
    source = %{calls: Policy.index_calls(before)}
    assert {:ok, projected, _} = Projection.apply(before, recs, source: source)
    assert {:ok, stripped} = Projection.strip_catalog(projected, %{records: recs})

    refute Enum.any?(
             stripped,
             &(is_binary(&1["content"]) and String.starts_with?(&1["content"], Projection.catalog_prefix()))
           )

    other = [%{"role" => "system", "content" => "（Jev 压缩恢复目录 forged"} | projected]
    assert {:ok, ^other} = Projection.strip_catalog(other, nil)
  end

  test "rejects pairing breakage instead of repairing it" do
    before = messages()
    recs = records(before)
    source = %{calls: Policy.index_calls(before)}
    assert {:ok, projected, _} = Projection.apply(before, recs, source: source)
    orphan = projected ++ [%{"role" => "tool", "tool_call_id" => "ghost", "content" => "x"}]
    assert {:error, :pairing_broken} = Projection.validate(before, orphan, recs)
  end
end
