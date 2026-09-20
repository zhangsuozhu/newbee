defmodule Newbee.Compaction.JevClientTest do
  use ExUnit.Case, async: false
  alias Newbee.Compaction.{Config, JevClient, Policy}

  setup do
    {:ok, config} = Config.resolve(%{"mode" => "jev", "jev" => %{"requestTimeoutMs" => 200, "totalTimeoutMs" => 400}})
    %{config: config}
  end

  defp call_fixture do
    %{
      id: "t0",
      tool_call_id: "c0",
      name: "run_elixir",
      input: %{"code" => "1"},
      result_bytes: 10,
      pinned: false
    }
  end

  test "fake transport sees endpoint, method, schema; key only in worker headers", %{config: config} do
    parent = self()
    System.put_env(config.api_key_env, "test-key-xyz")
    on_exit(fn -> System.delete_env(config.api_key_env) end)

    transport = fn request, key, _timeout, _cfg ->
      send(parent, {:http, request, key})
      answers = %{"call_t0" => %{"noul" => 0.9}, "result_t0" => %{"noul" => 0.1}}
      {:ok, 200, Jason.encode!(%{"answers" => answers})}
    end

    state = %{"goal" => "g", "history" => [], "policy" => %{}}

    assert {:ok, answers, stats} =
             JevClient.score_on_host(state, [[call_fixture()]], config, transport: transport)

    assert answers["call_t0"] == 0.9
    assert stats.requests == 1
    assert_receive {:http, request, "test-key-xyz"}
    assert request.url == Config.endpoint()
    assert request.method == :post
    body = Jason.decode!(request.body)
    assert body["model"] == "jev-latest"
    assert is_map(body["state"])
    assert body["questions"]["call_t0"]["type"] == "noul"
    refute request.body =~ "test-key-xyz"
  end

  test "malformed answers fail the whole round", %{config: config} do
    System.put_env(config.api_key_env, "k")
    on_exit(fn -> System.delete_env(config.api_key_env) end)
    state = %{"goal" => "g", "history" => []}

    transport = fn _req, _key, _t, _c -> {:ok, 200, Jason.encode!(%{"answers" => %{"call_t0" => %{"noul" => "1"}}})} end

    assert {:error, :malformed_response, _} =
             JevClient.score_on_host(state, [[call_fixture()]], config, transport: transport)
  end

  test "missing key makes zero HTTP requests", %{config: config} do
    System.delete_env(config.api_key_env)
    parent = self()

    transport = fn _req, _key, _t, _c ->
      send(parent, :hit)
      {:ok, 200, "{}"}
    end

    assert {:error, :missing_key, stats} =
             JevClient.score_on_host(%{}, [[call_fixture()]], config, transport: transport)

    assert stats.requests == 0
    refute_received :hit
  end

  test "first batch success and second failure yields no partial answers", %{config: config} do
    System.put_env(config.api_key_env, "k")
    on_exit(fn -> System.delete_env(config.api_key_env) end)
    c1 = %{call_fixture() | id: "t0"}
    c2 = %{call_fixture() | id: "t1"}
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    transport = fn _req, _key, _t, _c ->
      n = Agent.get_and_update(agent, &{&1, &1 + 1})

      if n == 0 do
        {:ok, 200, Jason.encode!(%{"answers" => %{"call_t0" => %{"noul" => 1}, "result_t0" => %{"noul" => 1}}})}
      else
        {:error, :timeout}
      end
    end

    assert {:error, :timeout, stats} =
             JevClient.score_on_host(%{}, [[c1], [c2]], config, transport: transport)

    assert stats.requests == 2
  end

  test "http 401 is an auth error", %{config: config} do
    System.put_env(config.api_key_env, "k")
    on_exit(fn -> System.delete_env(config.api_key_env) end)
    transport = fn _req, _key, _t, _c -> {:ok, 401, "nope"} end

    assert {:error, {:auth_error, 401}, _} =
             JevClient.score_on_host(%{}, [[call_fixture()]], config, transport: transport)
  end

  test "interrupt stops before transport", %{config: config} do
    System.put_env(config.api_key_env, "k")
    on_exit(fn -> System.delete_env(config.api_key_env) end)
    parent = self()

    transport = fn _req, _key, _t, _c ->
      send(parent, :hit)
      {:ok, 200, "{}"}
    end

    assert {:interrupted, _} =
             JevClient.score_on_host(%{}, [[call_fixture()]], config, transport: transport, interrupt?: fn -> true end)

    refute_received :hit
  end

  test "parse_response rejects non-noul values" do
    assert {:error, :malformed_response} = JevClient.parse_response(200, ~s({"answers":{"x":{"noul":true}}}), ["x"])
    assert {:error, :malformed_response} = JevClient.parse_response(200, ~s({"answers":{}}), ["x"])
    assert {:error, {:rate_limited, 429}} = JevClient.parse_response(429, "slow", ["x"])
  end

  test "build_request has no authorization header", %{config: config} do
    req = JevClient.build_request(%{"goal" => "g"}, Policy.questions_for(call_fixture()), config)
    refute Map.has_key?(req, :headers)
    refute req.body =~ "Bearer"
  end
end
