defmodule Newbee.LLM.CatalogTest do
  use ExUnit.Case, async: false
  alias Newbee.LLM.{Catalog, Config}

  defp legacy do
    %{
      "providers" => %{
        "gateway" => %{
          "baseUrl" => "https://example.test/v1",
          "apiKey" => "test-first-key",
          "api" => "openai-completions",
          "models" => ["vendor/shared"],
          "modelApis" => %{"vendor/shared" => "openai-responses"},
          "contextWindows" => %{"vendor/shared" => 128_000},
          "modelCapabilities" => %{"vendor/shared" => %{"vision" => false}},
          "modelResponsesContinuations" => %{"vendor/shared" => true}
        }
      },
      "roles" => %{"default" => %{"provider" => "gateway", "model" => "vendor/shared", "reasoningEffort" => "high"}}
    }
  end

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "model.json")
    old = System.get_env("NEWBEE_MODEL_JSON")
    File.write!(path, Jason.encode!(legacy()))
    System.put_env("NEWBEE_MODEL_JSON", path)

    on_exit(fn ->
      if old, do: System.put_env("NEWBEE_MODEL_JSON", old), else: System.delete_env("NEWBEE_MODEL_JSON")
      File.rm_rf!(root)
    end)

    %{path: path}
  end

  test "migration preserves protocol, context, capability, continuation and role extras" do
    cfg = Catalog.migrate(legacy())
    [m] = cfg["providers"]["gateway"]["groups"]["default"]["models"]
    assert m["api"] == "openai-responses"
    assert m["capabilities"] == %{"vision" => false}
    assert m["responsesContinuation"]
    assert Catalog.persist(Catalog.runtime(cfg)) == cfg
    assert Catalog.runtime(cfg)["roles"]["default"]["provider"] == "gateway"
    assert Catalog.runtime(cfg)["roles"]["default"]["reasoningEffort"] == "high"
  end

  test "migration retains role models absent from the static list" do
    cfg = put_in(legacy(), ["providers", "gateway", "models"], []) |> Catalog.migrate()
    assert [%{"id" => "vendor/shared"}] = cfg["providers"]["gateway"]["groups"]["default"]["models"]
    assert {:ok, _} = Catalog.prepare(Catalog.redact(cfg), cfg)
  end

  test "same model in two groups resolves separate keys and protocol", %{path: path} do
    second = %{
      "name" => "Premium",
      "apiKey" => "test-second-key",
      "models" => [
        %{
          "id" => "vendor/shared",
          "name" => "Shared premium",
          "api" => "anthropic",
          "contextWindow" => 256_000,
          "capabilities" => %{"vision" => true}
        }
      ]
    }

    cfg = Catalog.migrate(legacy()) |> put_in(["providers", "gateway", "groups", "premium"], second)
    File.write!(path, Jason.encode!(cfg))
    a = Config.client_for()
    b = Config.client_for("default", provider: "gateway~premium", model: "vendor/shared")
    assert a.api_key == "test-first-key"
    assert b.api_key == "test-second-key"
    assert b.base_url == a.base_url
    assert b.api == "anthropic"
    assert b.context_window == 256_000
    assert b.capabilities.vision
    assert Config.provider_api_key("gateway~premium") == "test-second-key"
    assert "gateway/vendor/shared" in Config.model_candidates()
    assert "gateway~premium/vendor/shared" in Config.model_candidates()
    assert {:error, {:unknown_model, "missing"}} = Config.set_default_model("gateway~premium/missing")
    assert :ok = Config.set_default_model("gateway~premium/vendor/shared")
    persisted = path |> File.read!() |> Jason.decode!()
    assert persisted["roles"]["default"]["group"] == "premium"
    assert persisted["roles"]["default"]["model"] == "vendor/shared"
    refute Map.has_key?(persisted, "__catalog")
    assert :ok = Config.set_context_window("gateway~premium", "vendor/shared", 512_000)
    assert Config.client_for().context_window == 512_000
    assert Config.context_window_override("gateway", "vendor/shared") == 128_000
  end

  test "editor hides keys; saves preserve keys and back up legacy bytes once", %{path: path} do
    original = File.read!(path)
    view = Config.catalog_config()
    refute Jason.encode!(view) =~ "test-first-key"
    assert view.config["providers"]["gateway"]["groups"]["default"]["keyConfigured"]
    assert {:ok, saved} = Config.save_catalog(view.config, view.revision)
    assert File.read!(path <> ".v1.bak") == original
    assert Config.provider_api_key("gateway") == "test-first-key"
    assert {:ok, _} = Config.save_catalog(saved.config, saved.revision)
    assert File.read!(path <> ".v1.bak") == original
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert {:error, :use_catalog_editor} = Config.delete_provider("gateway")
    assert {:error, :use_catalog_editor} = Config.upsert_provider("gateway", %{})
  end

  test "stale save cannot overwrite a key change", %{path: path} do
    view = Config.catalog_config()
    assert {:ok, saved} = Config.save_catalog(view.config, view.revision)
    updated = put_in(saved.config, ["providers", "gateway", "groups", "default", "apiKey"], "replacement-key")
    assert {:ok, _} = Config.save_catalog(updated, saved.revision)
    bytes = File.read!(path)
    assert {:error, _} = Config.save_catalog(saved.config, saved.revision)
    assert File.read!(path) == bytes
  end

  test "validation rejects duplicate models, invalid context/protocol, dangling references and missing keys" do
    cfg = Catalog.migrate(legacy())
    [m] = cfg["providers"]["gateway"]["groups"]["default"]["models"]

    for models <- [[m, m], [Map.put(m, "contextWindow", -1)], [Map.put(m, "api", "unsupported")], [%{"id" => ""}]] do
      assert {:error, _} =
               Catalog.prepare(put_in(cfg, ["providers", "gateway", "groups", "default", "models"], models), cfg)
    end

    assert {:error, _} = Catalog.prepare(put_in(cfg, ["roles", "default", "group"], "missing"), cfg)
    assert {:error, _} = Catalog.prepare(put_in(cfg, ["providers", "gateway", "baseUrl"], "bad"), cfg)
    assert {:error, _} = Catalog.prepare(put_in(cfg, ["providers", "gateway", "groups", "new"], %{"models" => []}), cfg)
  end

  test "hot config refresh preserves the active turn and its interrupt scope", %{path: path} do
    sid = "catalog_hot_#{System.unique_integer([:positive])}"
    Newbee.Session.open(sid)
    Newbee.Session.set_provider(sid, "gateway")
    Newbee.Session.set_model(sid, "vendor/shared")
    on_exit(fn -> Newbee.Session.delete(sid) end)
    {:ok, old} = Newbee.Web.Session.client_for_session(sid)
    old = %{old | session_id: "existing-upstream-session", responses_checkpoint: "existing-response"}
    cfg = Catalog.migrate(legacy()) |> put_in(["providers", "gateway", "groups", "default", "apiKey"], "updated-key")
    File.write!(path, Jason.encode!(cfg))

    for busy <- [false, true] do
      st = %Newbee.Web.Session{sid: sid, client: old, busy: busy, booting: false}
      assert {:noreply, next} = Newbee.Web.Session.handle_cast(:hot_model_config_changed, st)
      assert next.busy == busy
      assert next.client.api_key == "updated-key"
      assert next.client.interrupt_scope == old.interrupt_scope
      refute next.client.session_id == old.session_id
      assert is_nil(next.client.responses_checkpoint)
    end
  end

  test "deleted group moves an online session to the configured default", %{path: path} do
    sid = "catalog_deleted_#{System.unique_integer([:positive])}"
    Newbee.Session.open(sid)
    Newbee.Session.set_provider(sid, "gateway~removed")
    Newbee.Session.set_model(sid, "vendor/shared")
    on_exit(fn -> Newbee.Session.delete(sid) end)
    File.write!(path, Jason.encode!(Catalog.migrate(legacy())))
    st = %Newbee.Web.Session{sid: sid, client: Config.client_for(), booting: false}
    assert {:noreply, next} = Newbee.Web.Session.handle_cast(:hot_model_config_changed, st)
    assert next.client.provider == "gateway"
    assert Newbee.Session.provider(sid) == "gateway"
  end

  test "legacy boolean text becomes boolean in the canonical catalog" do
    cfg =
      legacy()
      |> put_in(["providers", "gateway", "modelResponsesContinuations", "vendor/shared"], "false")
      |> Catalog.migrate()

    [model] = cfg["providers"]["gateway"]["groups"]["default"]["models"]
    assert model["responsesContinuation"] == false
    assert {:ok, _} = Catalog.prepare(Catalog.redact(cfg), cfg)
  end

  test "model selection catalog is local and carries names without credentials" do
    cat = Config.model_catalog()
    assert [%{name: "gateway", displayName: "gateway / 默认分组", models: ["vendor/shared"]}] = cat.providers
    refute Jason.encode!(cat) =~ "test-first-key"
  end

  # 厂家级 TLS：形状/取值规范化在保存期完成，坏配置不落盘。
  test "provider tls 规范化后随 runtime/persist 往返保留", %{path: path} do
    cfg = legacy() |> Catalog.migrate()
    ca = write_ca!(path)

    input = put_in(cfg, ["providers", "gateway", "tls"], %{"caFile" => "  " <> ca <> "  "})

    assert {:ok, prepared} = Catalog.prepare(Catalog.redact(input), cfg)
    assert prepared["providers"]["gateway"]["tls"] == %{"caFile" => ca}

    # runtime 视图把厂家字段平铺给 Client，persist 再折回目录形态
    assert Catalog.runtime(prepared)["providers"]["gateway"]["tls"] == %{"caFile" => ca}
    assert Catalog.persist(Catalog.runtime(prepared))["providers"]["gateway"]["tls"] == %{"caFile" => ca}
  end

  test "provider tls 指纹统一成小写十六进制，清除时删除字段" do
    cfg = legacy() |> Catalog.migrate()
    pin = String.duplicate("AB", 32)

    input = put_in(cfg, ["providers", "gateway", "tls"], %{"pinnedSha256" => "sha256:" <> pin})
    assert {:ok, prepared} = Catalog.prepare(Catalog.redact(input), cfg)

    assert prepared["providers"]["gateway"]["tls"] == %{"pinnedSha256" => String.downcase(pin)}

    cleared = put_in(prepared, ["providers", "gateway", "tls"], %{"insecureSkipVerify" => false})
    assert {:ok, cleared} = Catalog.prepare(Catalog.redact(cleared), prepared)
    refute Map.has_key?(cleared["providers"]["gateway"], "tls")
  end

  test "provider tls 非法配置在保存时明确报错", %{path: path} do
    cfg = legacy() |> Catalog.migrate()
    base = Catalog.redact(cfg)
    ca = write_ca!(path)

    cases = [
      {%{"caFile" => "/nonexistent/newbee-ca.pem"}, "caFile"},
      {%{"caFile" => ca, "insecureSkipVerify" => true}, "互斥"},
      {%{"caFile" => ca, "pinnedSha256" => String.duplicate("a", 64)}, "互斥"},
      {%{"caCert" => "x"}, "caCert"},
      {%{"pinnedSha256" => "short"}, "pinnedSha256"},
      {%{"insecureSkipVerify" => "yes"}, "布尔"}
    ]

    for {tls, expected} <- cases do
      input = put_in(base, ["providers", "gateway", "tls"], tls)
      assert {:error, message} = Catalog.prepare(input, cfg)
      assert message =~ expected, "tls=#{inspect(tls)} 的报错信息不匹配：#{message}"
    end
  end

  # 只用于「caFile 可读」这条路径，与真实握手无关。
  defp write_ca!(path) do
    ca = Path.join(Path.dirname(path), "ca.pem")
    File.write!(ca, test_ca_pem())
    ca
  end

  defp test_ca_pem do
    [
      "-----BEGIN CERTIFICATE-----",
      "MIICDjCCAXegAwIBAgIUHMFF/odYEWSfuoqvs1UMqzbej6owDQYJKoZIhvcNAQEL",
      "BQAwGTEXMBUGA1UEAwwObmV3YmVlLXRlc3QtY2EwHhcNMjYxMDIzMDkwNzE5WhcN",
      "MzYxMDIwMDkwNzE5WjAZMRcwFQYDVQQDDA5uZXdiZWUtdGVzdC1jYTCBnzANBgkq",
      "hkiG9w0BAQEFAAOBjQAwgYkCgYEApwXQH9sQyDIsefe+f693daBwcTP7HzcWBvsv",
      "oK5/hcxeUINn9TMzrhc1xdMRGL7sec8uYoRvcr4q6hLe/7K10sI+8WFJZYZvBI7y",
      "8qVgDyUPMfT8UYpt23lUaUK2eYp4QK84g5rJZ/z15Y1f2IFaxmE3IquFC+rRedAw",
      "uoJCNOcCAwEAAaNTMFEwHQYDVR0OBBYEFJdO6EibDdSChVplggPwJW0ePiKUMB8G",
      "A1UdIwQYMBaAFJdO6EibDdSChVplggPwJW0ePiKUMA8GA1UdEwEB/wQFMAMBAf8w",
      "DQYJKoZIhvcNAQELBQADgYEAcCAnpbxu95cZ/CtnPsPbOa00CHmW2q29+uHk3b/L",
      "/GggkMSGtJK/w3bj/iVO3bQYjz8cUnx69leHlEFZZMrREJrzXD/huywYczvgxkyu",
      "N0ipqAZlNPqokbuOVR9z6ShJVjoXUn8iv0R84G6Ayz+jckE95HsNvkBKRdIN/RaG",
      "5NY=",
      "-----END CERTIFICATE-----"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
