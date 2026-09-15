defmodule Newbee.Environment.AutonomyTest do
  use ExUnit.Case, async: true

  alias Newbee.Environment.Autonomy

  test "档位与默认" do
    assert Autonomy.levels() == [:observe, :manual, :autonomous, :emergency_stop]
    assert Autonomy.default() == :manual
  end

  test "Ring 映射（§8.3）" do
    assert Autonomy.ring_of(:tool) == 3
    assert Autonomy.ring_of(:rule) == 2
    assert Autonomy.ring_of(:prompt) == 2
    assert Autonomy.ring_of(:provider) == 1
    assert Autonomy.ring_of(:stateful_service) == 1
  end

  test "Ring 门槛要求" do
    assert :counterfactual in Autonomy.required_layers(2)
    refute :counterfactual in Autonomy.required_layers(3)
    assert :cross_project in Autonomy.required_layers(1)
  end

  test "激活判定合取（§8.1）" do
    # emergency_stop 冻结一切，仅允许回退
    assert {:deny, :emergency_stop} = Autonomy.activation_decision(:tool, :emergency_stop)
    assert {:allow, :rollback} = Autonomy.activation_decision(:tool, :emergency_stop, rollback: true)

    # observe 只建议
    assert {:deny, :observe_only} = Autonomy.activation_decision(:tool, :observe)

    # manual 需批准
    assert {:deny, :needs_approval} = Autonomy.activation_decision(:tool, :manual)
    assert {:allow, :manual_approved} = Autonomy.activation_decision(:tool, :manual, approved: true)

    # autonomous 自动激活 tool
    assert {:allow, :autonomous} = Autonomy.activation_decision(:tool, :autonomous)

    # rule/prompt 即使 autonomous 也须先经 canary
    assert {:allow, :canary} = Autonomy.activation_decision(:rule, :autonomous)
    assert {:allow, :autonomous} = Autonomy.activation_decision(:rule, :autonomous, canary_done: true)

    # provider/stateful_service 封顶 manual——autonomous 档位也不能自动激活
    assert {:deny, :needs_approval} = Autonomy.activation_decision(:provider, :autonomous)
    assert {:allow, :manual_approved} = Autonomy.activation_decision(:stateful_service, :autonomous, approved: true)
  end

  test "低风险且确定性验证全过时可自动放行" do
    release = %{kind: :tool, effects: []}
    evaluation = %{} |> Map.put(:passed, true) |> Map.put(:failed_layers, []) |> Map.put(:layers, %{static: %{passed: true}, deterministic: %{passed: true}})

    assert Autonomy.automatic_confidence?(release, evaluation)
    refute Autonomy.automatic_confidence?(%{kind: :tool, effects: [:network]}, evaluation)
    assert {:allow, :autonomous} = Autonomy.activation_decision(:tool, :manual, certain: true)
    assert {:deny, :needs_approval} = Autonomy.activation_decision(:provider, :manual, certain: true)
  end


  test "挣来的自治（§8.1）：证据不足不建议升档" do
    refute Autonomy.suggest_upgrade?(%{verified_antibodies: 0, replay_coverage: 0.0, recent_changes: []})

    assert Autonomy.suggest_upgrade?(%{
             verified_antibodies: 6,
             replay_coverage: 0.8,
             recent_changes: []
           })

    # 近期有人工回退 → 不建议
    refute Autonomy.suggest_upgrade?(%{
             verified_antibodies: 6,
             replay_coverage: 0.8,
             recent_changes: [%Newbee.Environment.Change{status: :rolled_back}]
           })
  end
end
