defmodule Newbee.LLM.ConfigRecoveryTest do
  use ExUnit.Case, async: false

  test "invalid model JSON falls back to defaults" do
    dir =
      Path.join(System.tmp_dir!(), "newbee-config-recovery-" <> Integer.to_string(System.unique_integer([:positive])))

    File.mkdir_p!(dir)
    path = Path.join(dir, "model.json")
    File.write!(path, "{broken")
    previous = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", path)

    on_exit(fn ->
      if previous, do: System.put_env("NEWBEE_MODEL_JSON", previous), else: System.delete_env("NEWBEE_MODEL_JSON")
      File.rm_rf!(dir)
    end)

    cfg = Newbee.LLM.Config.load()
    assert cfg["providers"]["openrouter"]["baseUrl"] == "https://openrouter.ai/api/v1"
  end
end
