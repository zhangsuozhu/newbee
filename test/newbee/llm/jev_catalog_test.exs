defmodule Newbee.LLM.JevCatalogTest do
  use ExUnit.Case, async: false
  alias Newbee.LLM.{Catalog, Config}
  alias Newbee.Compaction.JevClient
  alias Newbee.Compaction.Config, as: CompactionConfig

  defp fixture do
    %{
      "schemaVersion" => 2,
      "providers" => %{
        "chat" => %{
          "baseUrl" => "https://chat.example/v1",
          "groups" => %{
            "default" => %{
              "apiKey" => "chat-key",
              "models" => [%{"id" => "chat-model", "contextWindow" => 128_000}]
            }
          }
        },
        "typesafe" => %{
          "name" => "Jev service",
          "baseUrl" => "https://scoring.example/v1",
          "groups" => %{
            "default" => %{
              "apiKey" => "scoring-first-key",
              "models" => [%{"id" => "jev-custom", "kind" => "jev", "api" => "typesafe-systemone"}]
            },
            "premium" => %{
              "apiKey" => "scoring-second-key",
              "models" => [%{"id" => "jev-custom", "kind" => "jev", "api" => "typesafe-systemone"}]
            }
          }
        }
      },
      "roles" => %{"default" => %{"provider" => "chat", "group" => "default", "model" => "chat-model"}},
      "compaction" => %{
        "mode" => "jev",
        "jev" => %{"modelRef" => %{"provider" => "typesafe", "group" => "premium", "model" => "jev-custom"}}
      }
    }
  end

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-jev-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "model.json")
    old_path = System.get_env("NEWBEE_MODEL_JSON")
    old_key = System.get_env("TYPESAFE_API_KEY")
    File.write!(path, Jason.encode!(fixture()))
    System.put_env("NEWBEE_MODEL_JSON", path)
    System.put_env("TYPESAFE_API_KEY", "wrong-legacy-global-key")

    on_exit(fn ->
      if old_path, do: System.put_env("NEWBEE_MODEL_JSON", old_path), else: System.delete_env("NEWBEE_MODEL_JSON")
      if old_key, do: System.put_env("TYPESAFE_API_KEY", old_key), else: System.delete_env("TYPESAFE_API_KEY")
      File.rm_rf!(root)
    end)

    %{path: path}
  end

  test "Jev stays in the editable catalog but cannot be used for chat or role selection" do
    view = Config.catalog_config()
    assert [%{"kind" => "jev"}] = view.config["providers"]["typesafe"]["groups"]["premium"]["models"]
    refute Jason.encode!(view) =~ "scoring-second-key"
    assert {:ok, _} = Config.save_catalog(view.config, view.revision)
    cat = Config.model_catalog()
    for p <- cat.providers, p.name != "chat", do: assert(p.models == [])
    assert Config.model_candidates() == ["chat/chat-model"]

    assert_raise RuntimeError, ~r/Jev/, fn ->
      Config.client_for("default", provider: "typesafe~premium", model: "jev-custom")
    end

    assert {:error, _} = Config.set_default_model("typesafe~premium/jev-custom")

    bad =
      put_in(view.config, ["roles", "default"], %{
        "provider" => "typesafe",
        "group" => "premium",
        "model" => "jev-custom"
      })

    assert {:error, _} = Catalog.prepare(bad, fixture())
  end

  test "Jev model and purpose are preserved by ordinary model and context changes", %{path: path} do
    assert :ok = Config.set_context_window("chat", "chat-model", 256_000)
    assert :ok = Config.set_default_model("chat/chat-model")
    persisted = path |> File.read!() |> Jason.decode!()
    assert persisted["providers"]["typesafe"] == fixture()["providers"]["typesafe"]
    assert persisted["compaction"] == fixture()["compaction"]
  end

  test "bound requests use the selected group's key, endpoint and model instead of global credentials", %{path: path} do
    for {group, key} <- [{"default", "scoring-first-key"}, {"premium", "scoring-second-key"}] do
      cfg = put_in(fixture(), ["compaction", "jev", "modelRef", "group"], group)
      File.write!(path, Jason.encode!(cfg))
      config = CompactionConfig.load()
      assert config.mode == :jev
      assert config.model == "jev-custom"
      assert config.endpoint == "https://scoring.example/v1/systemone"
      assert config.api_key_env == nil
      refute inspect(config) =~ key
      parent = self()

      transport = fn request, actual_key, _timeout, _cfg ->
        send(parent, {:request, request, actual_key})
        {:ok, 200, Jason.encode!(%{"answers" => %{"call_t0" => %{"noul" => 0.9}, "result_t0" => %{"noul" => 0.2}}})}
      end

      candidate = %{
        id: "t0",
        tool_call_id: "c0",
        name: "run_elixir",
        input: %{"code" => "1"},
        result_bytes: 10,
        pinned: false
      }

      assert {:ok, _, %{requests: 1}} =
               JevClient.score_on_host(%{"goal" => "test", "history" => []}, [[candidate]], config,
                 transport: transport
               )

      assert_receive {:request, request, ^key}
      assert request.url == config.endpoint
      body = Jason.decode!(request.body)
      assert body["model"] == "jev-custom"
      assert is_map(body["state"])
      assert is_map(body["questions"])
      refute Map.has_key?(body, "messages")
      refute request.body =~ key
    end
  end

  test "invalid binding falls back and cannot be saved as a valid catalog", %{path: path} do
    for ref <- [
          %{"provider" => "missing", "group" => "default", "model" => "jev-custom"},
          %{"provider" => "chat", "group" => "default", "model" => "chat-model"}
        ] do
      cfg = put_in(fixture(), ["compaction", "jev", "modelRef"], ref)
      assert {:error, _} = Catalog.prepare(cfg, fixture())
      File.write!(path, Jason.encode!(cfg))
      config = CompactionConfig.load()
      assert config.mode == :legacy
      assert config.warning == :invalid_jev_model_ref
    end
  end

  test "protocol/type mismatch and invalid scoring budgets are rejected" do
    cfg = fixture()
    g = cfg["providers"]["typesafe"]["groups"]["premium"]

    bad =
      put_in(cfg, ["providers", "typesafe", "groups", "premium"], %{
        g
        | "models" => [%{"id" => "jev-custom", "kind" => "jev", "api" => "openai-completions"}]
      })

    assert {:error, _} = Catalog.prepare(bad, cfg)
    bad = put_in(cfg, ["compaction", "jev", "maxStateTokens"], 29000)
    assert {:error, _} = Catalog.prepare(bad, cfg)
  end

  test "an endpoint already ending in systemone is not duplicated" do
    cfg = put_in(fixture(), ["providers", "typesafe", "baseUrl"], "https://scoring.example/v1/systemone/")

    assert {:ok, %{endpoint: "https://scoring.example/v1/systemone"}} =
             Catalog.jev_connection(cfg, cfg["compaction"]["jev"]["modelRef"])
  end

  test "official legacy TypeSafe Jev entries migrate without being advertised as chat" do
    legacy = %{
      "providers" => %{
        "typesafe" => %{
          "baseUrl" => "https://api.typesafe.ai",
          "api" => "openai-completions",
          "apiKey" => "old-key",
          "models" => ["jev-latest"]
        }
      },
      "roles" => %{}
    }

    cfg = Catalog.migrate(legacy)

    assert [%{"kind" => "jev", "api" => "typesafe-systemone"}] =
             cfg["providers"]["typesafe"]["groups"]["default"]["models"]

    refute Catalog.chat_model?(legacy["providers"]["typesafe"], "jev-latest")
    ref = %{"provider" => "typesafe", "group" => "default", "model" => "jev-latest"}
    assert {:ok, %{endpoint: "https://api.typesafe.ai/v1/systemone"}} = Catalog.jev_connection(cfg, ref)
    other = put_in(legacy, ["providers", "typesafe", "baseUrl"], "https://other.example/v1") |> Catalog.migrate()
    refute hd(other["providers"]["typesafe"]["groups"]["default"]["models"])["kind"]
  end

  test "web refresh updates an idle kernel and defers a busy kernel" do
    sid = "jev-hot-#{System.unique_integer([:positive])}"
    Newbee.Session.open(sid)
    Newbee.Session.set_provider(sid, "chat")
    Newbee.Session.set_model(sid, "chat-model")
    parent = self()
    kernel = spawn(fn -> kernel_stub(parent) end)

    on_exit(fn ->
      Process.exit(kernel, :kill)
      Newbee.Session.delete(sid)
    end)

    st = %Newbee.Web.Session{sid: sid, client: Config.client_for(), kernel: kernel, busy: false, booting: false}
    assert {:noreply, idle} = Newbee.Web.Session.handle_cast(:hot_model_config_changed, st)
    assert_receive {:kernel_call, {:switch_model, _}}
    assert_receive {:kernel_call, :reload_model_config}
    refute idle.model_config_pending
    assert {:noreply, busy} = Newbee.Web.Session.handle_cast(:hot_model_config_changed, %{st | busy: true})
    assert busy.model_config_pending
    refute_receive {:kernel_call, _}, 50
  end

  defp kernel_stub(parent) do
    receive do
      {:"$gen_call", from, message} ->
        send(parent, {:kernel_call, message})
        GenServer.reply(from, :ok)
        kernel_stub(parent)
    end
  end

  defmodule ScoringEndpoint do
    def init(parent), do: parent

    def call(conn, parent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)
      send(parent, {:actual_http, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), data})
      answers = Map.new(data["questions"], fn {id, _} -> {id, %{"noul" => 0.7}} end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"answers" => answers}))
    end
  end

  test "real HTTP transport uses SystemOne and supports connection and pool timeouts", %{path: path} do
    server = start_supervised!({Bandit, plug: {ScoringEndpoint, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    cfg = put_in(fixture(), ["providers", "typesafe", "baseUrl"], "http://127.0.0.1:#{port}/v1")
    File.write!(path, Jason.encode!(cfg))
    config = CompactionConfig.load()

    candidate = %{
      id: "t0",
      tool_call_id: "c0",
      name: "run_elixir",
      input: %{"code" => "1"},
      result_bytes: 10,
      pinned: false
    }

    assert {:ok, %{"call_t0" => 0.7}, %{requests: 1}} =
             JevClient.score_on_host(%{"goal" => "local test", "history" => []}, [[candidate]], config)

    assert_receive {:actual_http, "/v1/systemone", ["Bearer scoring-second-key"], data}
    assert data["model"] == "jev-custom"
    refute Map.has_key?(data, "messages")
  end

  test "kernel refresh applies the bound scorer and resets failures" do
    st = %Newbee.Agent.Loop{
      compaction_config: CompactionConfig.legacy(),
      jev_breaker: %{failures: 3, retry_at_ms: 10000}
    }

    assert {:reply, :ok, next} = Newbee.Agent.Loop.handle_call(:reload_model_config, self(), st)
    assert next.compaction_config.mode == :jev
    assert next.compaction_config.api_key_provider == "typesafe~premium"
    assert next.jev_breaker.failures == 0
    assert next.jev_breaker.retry_at_ms == nil
  end
end
