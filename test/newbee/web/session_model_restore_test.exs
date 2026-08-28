defmodule Newbee.Web.SessionModelRestoreTest do
  use ExUnit.Case, async: false

  test "restored model keeps its per-model API protocol" do
    root = Path.join(System.tmp_dir!(), "newbee-session-model-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "model.json")
    sid = "test_model_restore_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)

    File.write!(
      config_path,
      Jason.encode!(%{
        "providers" => %{
          "opencode" => %{
            "baseUrl" => "https://example.test/v1",
            "apiKey" => "test",
            "models" => ["default-model", "muse-spark-1.2-contributor"],
            "modelApis" => %{"muse-spark-1.2-contributor" => "openai-responses"}
          }
        },
        "roles" => %{
          "default" => %{"provider" => "opencode", "model" => "default-model"}
        }
      })
    )

    old_config = System.get_env("NEWBEE_MODEL_JSON")
    System.put_env("NEWBEE_MODEL_JSON", config_path)
    Newbee.Session.open(sid)
    :ok = Newbee.Session.set_provider(sid, "opencode")
    :ok = Newbee.Session.set_model(sid, "muse-spark-1.2-contributor")

    on_exit(fn ->
      if old_config,
        do: System.put_env("NEWBEE_MODEL_JSON", old_config),
        else: System.delete_env("NEWBEE_MODEL_JSON")

      File.rm_rf!(root)
      Newbee.Session.delete(sid)
    end)

    assert {:ok, client} = Newbee.Web.Session.client_for_session(sid)
    assert client.provider == "opencode"
    assert client.model == "muse-spark-1.2-contributor"
    assert client.api == "openai-responses"
  end
end
