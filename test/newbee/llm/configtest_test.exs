defmodule Newbee.LLM.ConfigTest do
  use ExUnit.Case, async: false

  # 这些测试验证真实配置的解析（用户环境），无配置时跳过而非失败
  setup do
    configured? =
      Enum.any?(
        [
          System.get_env("NEWBEE_MODEL_JSON"),
          "model.json",
          "model.local.json",
          Path.join([System.user_home!(), ".newbee", "model.json"])
        ],
        &(&1 && File.exists?(&1))
      )

    if configured? do
      :ok
    else
      {:skip, "未配置 model.json（NEWBEE_MODEL_JSON / ./model.json / ~/.newbee/model.json）"}
    end
  end

  test "从 ~/.newbee/model.json（或 env 覆盖）加载并解析角色" do
    # 不断言具体型号（用户会换 provider）；断言 roles→providers 的解析逻辑正确
    cfg = Newbee.LLM.Config.load()
    role = cfg["roles"]["default"]
    provider = cfg["providers"][role["provider"]]

    client = Newbee.LLM.Config.client_for("default")
    assert client.model == role["model"]
    assert client.base_url == provider["baseUrl"]
    assert client.reasoning_effort == role["reasoningEffort"]
  end

  test "默认角色带真实 api_key（直接写在配置里，非占位）" do
    assert is_binary(Newbee.LLM.Config.client_for("default").api_key)
    refute Newbee.LLM.Config.client_for("default").api_key == "<redacted>"
  end


  test "未知角色回退 default" do
    c1 = Newbee.LLM.Config.client_for("nonexistent")
    c2 = Newbee.LLM.Config.client_for("default")
    assert c1.model == c2.model
  end

  describe "set_default_model" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "newbee-configtest-#{System.system_time(:native)}_#{System.unique_integer([:positive])}/model.json")
      File.mkdir_p!(Path.dirname(tmp))
      File.write!(
        tmp,
        Jason.encode!(%{
          "providers" => %{
             "opencode" => %{"baseUrl" => "https://opencode.ai/zen/go/v1", "apiKey" => "k", "models" => ["ox-alpha-free"]},
             "openrouter" => %{"baseUrl" => "https://openrouter.ai/api/v1", "apiKey" => "k", "models" => []}
           },
          "roles" => %{"default" => %{"provider" => "openrouter", "model" => "deepseek/deepseek-v4-flash-0731"}}
        })
      )

      System.put_env("NEWBEE_MODEL_JSON", tmp)

      on_exit(fn ->
        System.delete_env("NEWBEE_MODEL_JSON")
        File.rm_rf!(Path.dirname(tmp))
      end)

      :ok
    end

    test "provider 前缀被解析为 provider 名 + 裸模型 id" do
      assert :ok = Newbee.LLM.Config.set_default_model("opencode/ox-alpha-free")
      cfg = Newbee.LLM.Config.load()

      assert cfg["roles"]["default"] == %{
               "provider" => "opencode",
               "model" => "ox-alpha-free"
             }

      client = Newbee.LLM.Config.client_for("default")
      assert client.model == "ox-alpha-free"
      assert client.base_url == "https://opencode.ai/zen/go/v1"
    end

    test "多段 id：首段是 provider，其余整体保留为模型 id" do
      assert :ok = Newbee.LLM.Config.set_default_model("openrouter/deepseek/deepseek-v4-flash-0731")
      cfg = Newbee.LLM.Config.load()
      assert cfg["roles"]["default"]["provider"] == "openrouter"
      assert cfg["roles"]["default"]["model"] == "deepseek/deepseek-v4-flash-0731"
    end

    test "无斜杠：只改模型 id，provider 保持不变" do
      assert :ok = Newbee.LLM.Config.set_default_model("ox-alpha-free")
      cfg = Newbee.LLM.Config.load()
      assert cfg["roles"]["default"]["provider"] == "openrouter"
      assert cfg["roles"]["default"]["model"] == "ox-alpha-free"
    end

    test "未知 provider 前缀被拒绝且不落盘" do
      before = File.read!(System.get_env("NEWBEE_MODEL_JSON"))
      assert {:error, {:unknown_provider, "nosuch"}} = Newbee.LLM.Config.set_default_model("nosuch/m1")
      assert File.read!(System.get_env("NEWBEE_MODEL_JSON")) == before
    end

    test "空串与非字符串拒绝" do
      assert {:error, :bad_model_id} = Newbee.LLM.Config.set_default_model("")
      assert {:error, :bad_model_id} = Newbee.LLM.Config.set_default_model(nil)
      assert {:error, :bad_model_id} = Newbee.LLM.Config.set_default_model("   ")
    end
  end

  describe "set_context_window" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "newbee-configtest-#{System.system_time(:native)}_#{System.unique_integer([:positive])}/model.json")
      File.mkdir_p!(Path.dirname(tmp))

      File.write!(
        tmp,
        Jason.encode!(%{
          "providers" => %{
            "openrouter" => %{
              "baseUrl" => "https://openrouter.ai/api/v1",
              "apiKey" => "k",
              "models" => [],
              "contextWindow" => 200_000
            }
          },
          "roles" => %{
            "default" => %{"provider" => "openrouter", "model" => "deepseek/deepseek-v4-flash-0731"}
          }
        })
      )

      System.put_env("NEWBEE_MODEL_JSON", tmp)

      on_exit(fn ->
        System.delete_env("NEWBEE_MODEL_JSON")
        File.rm_rf!(Path.dirname(tmp))
      end)

      :ok
    end

    test "写入单模型覆盖并落盘，client_for 立即生效" do
      assert :ok = Newbee.LLM.Config.set_context_window("openrouter", "deepseek/deepseek-v4-flash-0731", 131_072)

      cfg = Newbee.LLM.Config.load()
      assert cfg["providers"]["openrouter"]["contextWindows"] == %{"deepseek/deepseek-v4-flash-0731" => 131_072}

      client = Newbee.LLM.Config.client_for("default")
      assert client.context_window == 131_072
      assert Newbee.LLM.Config.context_window_override("openrouter", "deepseek/deepseek-v4-flash-0731") == 131_072
    end

    test "nil 清除覆盖并回退 provider 级 contextWindow" do
      assert :ok = Newbee.LLM.Config.set_context_window("openrouter", "deepseek/deepseek-v4-flash-0731", 131_072)
      assert :ok = Newbee.LLM.Config.set_context_window("openrouter", "deepseek/deepseek-v4-flash-0731", nil)

      cfg = Newbee.LLM.Config.load()
      refute Map.has_key?(cfg["providers"]["openrouter"], "contextWindows")

      client = Newbee.LLM.Config.client_for("default")
      assert client.context_window == 200_000
      assert Newbee.LLM.Config.context_window_override("openrouter", "deepseek/deepseek-v4-flash-0731") == nil
    end

    test "覆盖只作用于指定模型，其它模型不受影响" do
      assert :ok = Newbee.LLM.Config.set_context_window("openrouter", "deepseek/deepseek-v4-flash-0731", 64_000)

      other = Newbee.LLM.Config.client_for("default", model: "openai/gpt-5")
      assert other.context_window == 200_000
    end

    test "未知 provider 拒绝且不落盘" do
      before = File.read!(System.get_env("NEWBEE_MODEL_JSON"))
      assert {:error, {:unknown_provider, "nosuch"}} = Newbee.LLM.Config.set_context_window("nosuch", "m1", 1000)
      assert File.read!(System.get_env("NEWBEE_MODEL_JSON")) == before
    end

    test "非法覆盖值拒绝" do
      assert {:error, :bad_context_window} = Newbee.LLM.Config.set_context_window("openrouter", "m1", 0)
      assert {:error, :bad_context_window} = Newbee.LLM.Config.set_context_window("openrouter", "m1", -5)
      assert {:error, :bad_context_window} = Newbee.LLM.Config.set_context_window("openrouter", "m1", "abc")
    end

    test "model_catalog 暴露 contextWindows 与 provider 级默认" do
      assert :ok = Newbee.LLM.Config.set_context_window("openrouter", "deepseek/deepseek-v4-flash-0731", 99_000)

      cat = Newbee.LLM.Config.model_catalog()
      p = Enum.find(cat.providers, &(&1.name == "openrouter"))
      assert p.contextWindows == %{"deepseek/deepseek-v4-flash-0731" => 99_000}
      assert p.contextWindow == 200_000
    end
  end
end
