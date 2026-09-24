defmodule Newbee.Evals.CompactionRecallTest do
  use ExUnit.Case, async: true

  alias Newbee.Evals.CompactionRecall

  test "synthetic fixture drops tool facts from context but keeps a spill address" do
    session = CompactionRecall.synthetic_session()
    assert {:ok, built} = CompactionRecall.arms(session)
    assert built.validation == :ok

    jev = Jason.encode!(built.contexts.jev)
    full = Jason.encode!(built.contexts.full)
    recency = Jason.encode!(built.contexts.recency)

    assert full =~ "FACT-MIDDLE-UNIQUE"
    assert full =~ "FACT-DROPPED-CALL"
    refute jev =~ "FACT-MIDDLE-UNIQUE"
    refute jev =~ "FACT-DROPPED-CALL"
    assert jev =~ "spill://eval-c1"
    assert jev =~ "spill://eval-c2"
    assert built.recoveries["eval-c1"] =~ "FACT-MIDDLE-UNIQUE"
    assert built.recoveries["eval-c2"] =~ "FACT-DROPPED-CALL"
    refute recency =~ "spill://"
  end

  test "synthetic scorecard is aggregate only and cannot keep" do
    report = CompactionRecall.run(CompactionRecall.synthetic_session())

    assert report.validation_failures == 0
    assert report.answerable == 3
    assert report.full_correct == 3
    assert report.legacy_correct == 1
    assert report.jev_correct == 1
    assert report.jev_read_correct == 3
    assert report.presence.jev.closed == 1
    assert report.presence.jev.one_read == 3
    assert report.verdict.status == :insufficient
    assert :synthetic_fixture in report.verdict.reasons
    assert :corpus_too_small in report.verdict.reasons

    Enum.each(["FACT-MIDDLE-UNIQUE", "FACT-DROPPED-CALL", "ALPHA-USER"], fn secret ->
      refute report.scorecard =~ secret
    end)
  end

  test "json round trip uses the file loader shape" do
    path =
      Path.join(System.tmp_dir!(), "compaction-recall-synthetic-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(CompactionRecall.synthetic_session()))
    report = CompactionRecall.run_file!(path)
    File.rm(path)

    assert report.session_id == "synthetic-001"
    assert report.verdict.status == :insufficient
  end

  test "normalizes atom-keyed session maps before running" do
    session =
      CompactionRecall.synthetic_session()
      |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)

    assert CompactionRecall.run(session).session_id == "synthetic-001"
  end

  test "pre-registered bar keeps only a non-synthetic corpus that clears every gate" do
    assert %{status: :keep, reasons: []} = CompactionRecall.judge(passing_stats())
  end

  test "wording swing inside the treatment margin is insufficient" do
    stats = passing_stats() |> Map.put(:wording_correct, 30) |> Map.put(:wording_swing, 20)
    verdict = CompactionRecall.judge(stats)

    assert verdict.status == :insufficient
    assert :inside_noise in verdict.reasons
  end

  test "validation failure invalidates the exam instead of tuning the threshold" do
    verdict = CompactionRecall.judge(Map.put(passing_stats(), :validation_failures, 1))

    assert verdict.status == :invalid
    assert :validation_failed in verdict.reasons
  end

  defp passing_stats do
    %{
      session_id: "heldout",
      synthetic: false,
      answerable: 100,
      validation_failures: 0,
      full_correct: 95,
      legacy_correct: 50,
      recency_correct: 40,
      jev_correct: 48,
      jev_read_correct: 70,
      wording_correct: 52,
      legacy_tokens: 1000,
      jev_tokens: 800,
      paired_jev_recency: %{won: 20, lost: 4, tied: 76},
      tool_jev_correct: 10,
      tool_jev_read_correct: 22,
      wording_swing: 2,
      presence: %{}
    }
  end
end
