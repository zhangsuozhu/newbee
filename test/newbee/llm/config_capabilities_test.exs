defmodule Newbee.LLM.ConfigCapabilitiesTest do
  use ExUnit.Case, async: false

  alias Newbee.LLM.{Capabilities, Config}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee-caps-#{System.system_time(:native)}_#{System.unique_integer([:positive])}/model.json"
      )

    File.mkdir_p!(Path.dirname(tmp))

    File.write!(
      tmp,
      Jason.encode!(%{
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.test/v1",
            "apiKey" => "k",
            "models" => ["m1", "m2"],
            "capabilities" => %{"vision" => false, "maxImagesPerRequest" => 5},
            "modelCapabilities" => %{
              "m1" => %{"vision" => true, "imageMaxBytes" => 2048},
              "m2" => %{"systemPromptUpdate" => "in-history"}
            }
          }
        },
        "roles" => %{"default" => %{"provider" => "p", "model" => "m1"}}
      })
    )

    System.put_env("NEWBEE_MODEL_JSON", tmp)

    on_exit(fn ->
      System.delete_env("NEWBEE_MODEL_JSON")
      File.rm_rf!(Path.dirname(tmp))
    end)

    :ok
  end

  test "provider 默认能力折进 client，且按模型覆盖" do
    m1 = Config.client_for("default", model: "m1")
    assert m1.capabilities[:vision] == true
    assert m1.capabilities[:image_max_bytes] == 2048
    assert m1.capabilities[:max_images_per_request] == 5
    assert m1.capabilities[:system_prompt_update] == nil

    m2 = Config.client_for("default", model: "m2")
    assert m2.capabilities[:vision] == false
    assert m2.capabilities[:system_prompt_update] == :in_history
    assert m2.capabilities[:max_images_per_request] == 5
  end

  test "未声明能力的模型只拿到 provider 默认值" do
    c = Config.client_for("default", model: "unknown-model")
    assert c.capabilities[:vision] == false
    assert c.capabilities[:max_images_per_request] == 5
  end

  test "fold 后 vision 字段与 capabilities 保持一致，角色级 vision 仍可覆盖" do
    c = Config.client_for("default", model: "m1")
    assert c.vision == c.capabilities[:vision]

    # 角色级 vision 覆盖 provider/模型声明
    File.write!(
      System.get_env("NEWBEE_MODEL_JSON"),
      File.read!(System.get_env("NEWBEE_MODEL_JSON"))
      |> Jason.decode!()
      |> put_in(["roles", "default", "vision"], false)
      |> Jason.encode!(pretty: true)
    )

    c2 = Config.client_for("default", model: "m1")
    assert c2.vision == false
    assert c2.capabilities[:vision] == false
  end

  test "旧配置的 provider 级 vision 仍被折成能力默认值" do
    cfg =
      System.get_env("NEWBEE_MODEL_JSON")
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("providers", fn providers ->
        Map.update!(providers, "p", fn p ->
          p |> Map.drop(["capabilities", "modelCapabilities"]) |> Map.put("vision", false)
        end)
      end)

    File.write!(System.get_env("NEWBEE_MODEL_JSON"), Jason.encode!(cfg, pretty: true))

    c = Config.client_for("default", model: "m1")
    assert c.vision == false
    assert c.capabilities[:vision] == false
  end

  describe "upsert_provider 的能力声明" do
    test "写入 provider 默认能力与按模型覆盖，非法值被丢弃" do
      assert :ok =
               Config.upsert_provider("p", %{
                 "baseUrl" => "https://example.test/v1",
                 "apiKey" => nil,
                 "models" => ["m1"],
                 "capabilities" => %{"vision" => "false", "bogus" => 1, "maxImagesPerRequest" => 0},
                 "modelCapabilities" => %{"m1" => %{"imageMaxBytes" => "1024", "nope" => true}}
               })

      provider = Config.load()["providers"]["p"]
      assert provider["capabilities"] == %{"vision" => false}
      assert provider["modelCapabilities"] == %{"m1" => %{"imageMaxBytes" => 1024}}

      c = Config.client_for("default", model: "m1")
      assert c.capabilities == %{vision: false, image_max_bytes: 1024}
    end

    test "attrs 未提供能力字段时保留既有声明（WebUI 表单不抹配置）" do
      assert :ok =
               Config.upsert_provider("p", %{"baseUrl" => "https://example.test/v1", "apiKey" => nil})

      provider = Config.load()["providers"]["p"]
      assert provider["capabilities"] == %{"vision" => false, "maxImagesPerRequest" => 5}
      assert provider["modelCapabilities"]["m2"] == %{"systemPromptUpdate" => "in-history"}
    end

    test "空能力 map 清除声明" do
      assert :ok =
               Config.upsert_provider("p", %{
                 "baseUrl" => "https://example.test/v1",
                 "apiKey" => nil,
                 "capabilities" => %{},
                 "modelCapabilities" => %{"m1" => %{}}
               })

      provider = Config.load()["providers"]["p"]
      refute Map.has_key?(provider, "capabilities")
      refute Map.has_key?(provider, "modelCapabilities")
    end

    test "capabilities 不会被 extras 当作额外字段重复写入" do
      assert :ok =
               Config.upsert_provider("p", %{
                 "baseUrl" => "https://example.test/v1",
                 "apiKey" => nil,
                 "capabilities" => %{"vision" => true},
                 "modelCapabilities" => %{"m1" => %{"vision" => true}},
                 "extras" => %{"capabilities" => %{"vision" => false}, "modelCapabilities" => %{}, "keepMe" => 1}
               })

      provider = Config.load()["providers"]["p"]
      assert provider["capabilities"] == %{"vision" => true}
      assert provider["modelCapabilities"] == %{"m1" => %{"vision" => true}}
      assert provider["keepMe"] == 1
    end
  end

  test "Capabilities.sanitize/1 是写入路径的规范化口径" do
    assert Capabilities.sanitize(%{"vision" => "false", "maxImagesPerRequest" => "5"}) ==
             %{"vision" => false, "maxImagesPerRequest" => 5}
  end
end
