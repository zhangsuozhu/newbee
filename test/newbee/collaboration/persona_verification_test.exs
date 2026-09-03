defmodule Newbee.Collaboration.PersonaAndVerificationTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{ContextFork, Persona, Verification}

  setup do
    root = Path.join(System.tmp_dir!(), "hive-contract-#{System.unique_integer([:positive])}")
    persona_dir = Path.join(root, "personas")
    store = Path.join(root, "store")
    File.mkdir_p!(persona_dir)
    File.mkdir_p!(store)

    old_persona = System.get_env("NEWBEE_PERSONA_DIR")
    old_store = Application.get_env(:newbee, :global_root_override)
    System.put_env("NEWBEE_PERSONA_DIR", persona_dir)
    Application.put_env(:newbee, :global_root_override, store)

    on_exit(fn ->
      if old_persona,
        do: System.put_env("NEWBEE_PERSONA_DIR", old_persona),
        else: System.delete_env("NEWBEE_PERSONA_DIR")

      if old_store,
        do: Application.put_env(:newbee, :global_root_override, old_store),
        else: Application.delete_env(:newbee, :global_root_override)

      File.rm_rf!(root)
    end)

    %{root: root, persona_dir: persona_dir}
  end

  test "persona JSON is strict and only exposes runtime-backed fields", ctx do
    File.write!(
      Path.join(ctx.persona_dir, "fast-review.json"),
      Jason.encode!(%{
        "role" => "reviewer",
        "provider" => "openrouter",
        "model" => "test/model",
        "reasoning_effort" => "high",
        "instructions" => "cite evidence"
      })
    )

    assert {:ok, profile} = Persona.resolve("fast-review")
    assert profile["role"] == "reviewer"
    assert profile["model"] == "test/model"
    refute Map.has_key?(profile, "tool_allow")
    refute Map.has_key?(profile, "token_budget")

    File.write!(
      Path.join(ctx.persona_dir, "invalid.json"),
      Jason.encode!(%{"role" => "worker", "instructions" => "x", "imaginary_runtime_knob" => true})
    )

    assert {:error, "bad_persona", message} = Persona.resolve("invalid")
    assert message =~ "未知字段"
    refute "invalid" in Persona.list()
    assert "fast-review" in Persona.list()
    assert {:error, "bad_persona", _} = Persona.resolve("../outside")
  end

  test "structured verification executes argv safely and records reproducible evidence", ctx do
    File.write!(Path.join(ctx.root, "proof.txt"), "proof")
    sha = :crypto.hash(:sha256, "proof") |> Base.encode16(case: :lower)

    criteria = [
      %{"kind" => "file_exists", "path" => "proof.txt"},
      %{"kind" => "file_sha256", "path" => "proof.txt", "sha256" => sha},
      %{"kind" => "command", "program" => "python3", "args" => ["-c", "print('ok')"], "timeout_ms" => 5_000}
    ]

    {:ok, normalized} = Verification.normalize_contract(criteria)
    {:ok, attestation} = Verification.verify(%{"acceptance" => normalized}, ctx.root)

    assert attestation["all_passed"]
    assert length(attestation["results"]) == 3
    assert Enum.at(attestation["results"], 2)["exit_code"] == 0
    assert Enum.at(attestation["results"], 2)["captured_output_bytes"] == 3
    refute Enum.at(attestation["results"], 2)["output_truncated"]
    refute Map.has_key?(Enum.at(attestation["results"], 2), "output_excerpt")
    assert attestation["contract_sha256"] == Verification.contract_sha256(normalized)
  end

  test "verification rejects empty, shell-shaped, and escaping contracts" do
    assert {:error, "acceptance_required", _} = Verification.normalize_contract([])
    assert {:error, "bad_acceptance", _} = Verification.normalize_contract(["mix test"])

    assert {:error, "bad_acceptance", _} =
             Verification.normalize_contract([
               %{"kind" => "command", "program" => "bash", "args" => ["-c", "rm -rf /"]}
             ])

    assert {:error, "bad_acceptance", _} =
             Verification.normalize_contract([
               %{"kind" => "command", "program" => "python3", "args" => ["bad" <> <<0>>]}
             ])

    assert {:error, "bad_acceptance", _} =
             Verification.normalize_contract([%{"kind" => "file_exists", "path" => "../outside"}])

    assert {:error, "acceptance_limit", _} =
             Verification.normalize_contract(List.duplicate(%{"kind" => "file_exists", "path" => "x"}, 33))
  end

  test "file checks reject symlinks that leave the verification root", ctx do
    outside = Path.join(Path.dirname(ctx.root), "hive-outside-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(ctx.root, "link.txt"))
    on_exit(fn -> File.rm(outside) end)

    {:ok, criteria} =
      Verification.normalize_contract([%{"kind" => "file_exists", "path" => "link.txt"}])

    {:ok, attestation} = Verification.verify(%{"acceptance" => criteria}, ctx.root)
    refute attestation["all_passed"]
    assert hd(attestation["results"])["error"] == "symlink_not_allowed"
  end

  test "context fork copies only completed user/final-assistant turns" do
    parent = "fork-parent-#{System.unique_integer([:positive])}"
    child_last = "fork-child-last-#{System.unique_integer([:positive])}"
    child_all = "fork-child-all-#{System.unique_integer([:positive])}"
    :ok = Newbee.Session.mark_created(parent)
    :ok = Newbee.Session.mark_created(child_last)
    :ok = Newbee.Session.mark_created(child_all)
    session = Newbee.Session.open(parent)

    for message <- [
          %{"role" => "system", "content" => "secret system"},
          %{"role" => "user", "content" => "question one"},
          %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "call"}]},
          %{"role" => "tool", "content" => "tool output"},
          %{"role" => "assistant", "content" => "answer one"},
          %{"role" => "user", "content" => "question two"},
          %{"role" => "assistant", "content" => "answer two", "_usage" => %{"total" => 99}},
          %{"role" => "user", "content" => "incomplete"}
        ] do
      Newbee.Session.append(session, message)
    end

    assert {:ok, %{turns: 1, messages: 2}} = ContextFork.seed(parent, child_last, 1)

    assert [
             %{"role" => "user", "content" => "question two"},
             %{"role" => "assistant", "content" => "answer two"}
           ] = Newbee.Session.messages(Newbee.Session.open(child_last)) |> Enum.map(&Map.take(&1, ["role", "content"]))

    assert {:ok, %{turns: 2, messages: 4}} = ContextFork.seed(parent, child_all, :all)
    all = Newbee.Session.messages(Newbee.Session.open(child_all))
    refute Enum.any?(all, &(&1["role"] in ["system", "tool"]))
    refute Enum.any?(all, &Map.has_key?(&1, "tool_calls"))
  end

  test "context fork fails explicitly when inherited text exceeds its budget" do
    parent = "fork-large-parent-#{System.unique_integer([:positive])}"
    child = "fork-large-child-#{System.unique_integer([:positive])}"
    :ok = Newbee.Session.mark_created(parent)
    :ok = Newbee.Session.mark_created(child)
    session = Newbee.Session.open(parent)
    Newbee.Session.append(session, %{"role" => "user", "content" => String.duplicate("u", 70_000)})
    Newbee.Session.append(session, %{"role" => "assistant", "content" => String.duplicate("a", 70_000)})

    assert {:error, "fork_context_too_large", _} = ContextFork.seed(parent, child, :all)
    assert Newbee.Session.messages(Newbee.Session.open(child)) == []
  end

  test "persona instructions are materialized as trusted system context", ctx do
    session_id = "persona-prompt-#{System.unique_integer([:positive])}"
    :ok = Newbee.Session.mark_created(session_id)

    :ok =
      Newbee.Session.set_collaboration_profile(session_id, %{
        "name" => "reviewer",
        "role" => "reviewer",
        "group_id" => "g-proof",
        "parent_session_id" => "lead",
        "instructions" => "evidence-only-review"
      })

    client = %Newbee.LLM.Client{
      provider: "test",
      model: "fake",
      api_key: "fake",
      base_url: "http://fake",
      reasoning_effort: nil,
      interrupt_scope: make_ref(),
      context_window: 8_000
    }

    {:ok, loop} =
      Newbee.Agent.Loop.start_link(
        client: client,
        evaluator: nil,
        session_id: session_id,
        root: ctx.root,
        client_fun: fn _messages, _on_text, _on_reasoning -> {:error, :unused} end
      )

    state = :sys.get_state(loop)
    [%{"role" => "system", "content" => prompt} | _] = state.messages
    assert prompt =~ "[NEWBEE_COLLAB_PROFILE_V1]"
    assert prompt =~ "persona=reviewer role=reviewer"
    assert prompt =~ "evidence-only-review"
    GenServer.stop(loop)

    :ok =
      Newbee.Session.set_collaboration_profile(session_id, %{
        "name" => "reviewer",
        "role" => "reviewer",
        "group_id" => "g-proof",
        "parent_session_id" => "lead",
        "instructions" => "updated-evidence-policy"
      })

    {:ok, second_loop} =
      Newbee.Agent.Loop.start_link(
        client: %{client | interrupt_scope: make_ref()},
        evaluator: nil,
        session_id: session_id,
        root: ctx.root,
        client_fun: fn _messages, _on_text, _on_reasoning -> {:error, :unused} end
      )

    [%{"role" => "system", "content" => updated_prompt} | _] = :sys.get_state(second_loop).messages
    assert updated_prompt =~ "updated-evidence-policy"
    refute updated_prompt =~ "evidence-only-review"
    GenServer.stop(second_loop)
  end
end
