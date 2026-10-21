defmodule Newbee.Browser.JevTest do
  use ExUnit.Case, async: false

  alias Newbee.Environment.{PluginContract, ToolContract}
  alias Newbee.Tools.{Browser, BrowserJev}

  setup do
    previous_key = System.get_env("TYPESAFE_API_KEY")
    System.delete_env("TYPESAFE_API_KEY")

    config_path =
      Path.expand(".newbee/jev-test-model-" <> Integer.to_string(System.unique_integer([:positive])) <> ".json")

    previous_config = System.get_env("NEWBEE_MODEL_JSON")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, Jason.encode!(%{providers: %{}}))
    System.put_env("NEWBEE_MODEL_JSON", config_path)

    on_exit(fn ->
      if is_binary(previous_key),
        do: System.put_env("TYPESAFE_API_KEY", previous_key),
        else: System.delete_env("TYPESAFE_API_KEY")

      if is_binary(previous_config),
        do: System.put_env("NEWBEE_MODEL_JSON", previous_config),
        else: System.delete_env("NEWBEE_MODEL_JSON")

      File.rm(config_path)
    end)

    :ok
  end

  test "browser jev is registered as a governed builtin tool" do
    assert Newbee.Plugins.module_for_plugin_id("tool.browser.jev") == BrowserJev
    assert %{capabilities: capabilities} = Newbee.Plugins.builtin("tool.browser.jev")
    assert :browser in capabilities
    assert PluginContract.valid_static?(BrowserJev)
    assert :ok = ToolContract.validate_builtin(BrowserJev)
  end

  test "missing Jev configuration fails before launching a browser" do
    test_pid = self()

    assert {:error, %{reason: :jev_not_configured}} =
             Newbee.Browser.Jev.run(
               %{url: "https://example.com", goal: "Open the documentation"},
               browser_run: fn request ->
                 send(test_pid, {:browser, request})
                 flunk("browser must not launch without Jev configuration")
               end,
               http_post: fn _url, _body, _headers ->
                 send(test_pid, :http)
                 flunk("Jev must not be called without configuration")
               end
             )

    refute_received {:browser, _}
    refute_received :http
  end

  test "regular Browser requests stay independent of Jev configuration" do
    assert {:error, %{reason: :invalid_backend}} = Browser.run(%{backend: "unknown"})
    assert {:error, %{reason: :invalid_timeout}} = Browser.run(%{timeout: 100})
  end

  test "invalid goals fail before contacting Playwright or TypeSafe" do
    test_pid = self()

    opts = [
      browser_run: fn request ->
        send(test_pid, {:browser, request})
        flunk("browser")
      end,
      http_post: fn _, _, _ ->
        send(test_pid, :http)
        flunk("http")
      end
    ]

    assert {:error, %{reason: :invalid_goal}} = Newbee.Browser.Jev.run(%{url: "https://example.com"}, opts)
    assert {:error, %{reason: :invalid_url}} = Newbee.Browser.Jev.run(%{goal: "Open docs"}, opts)
    refute_received {:browser, _}
    refute_received :http
  end

  test "Jev can only execute a code-owned candidate action" do
    snapshot = %{
      "url" => "https://example.com/",
      "title" => "Example",
      "text" => "Example Domain More information",
      "controls" => [
        %{"tag" => "a", "id" => "more", "name" => "More information", "disabled" => false}
      ],
      "links" => [%{"text" => "More information", "href" => "https://example.com/docs"}]
    }

    test_pid = self()

    browser_run = fn request ->
      send(test_pid, {:browser, request})
      actions = request["actions"] || request[:actions]

      cond do
        request["session"] == "new" ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => snapshot}]}}

        match?([%{"action" => "click"} | _], actions) or
            match?([%{action: "click"} | _], actions) ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => %{"clicked" => true}}]}}

        match?([%{"action" => "snapshot"} | _], actions) or
            match?([%{action: "snapshot"} | _], actions) ->
          {:ok,
           %{
             "session" => "sess-1",
             "results" => [
               %{
                 "result" => %{
                   "url" => "https://example.com/docs",
                   "title" => "Docs",
                   "text" => "Documentation",
                   "controls" => [],
                   "links" => []
                 }
               }
             ]
           }}

        match?([%{"action" => "close"} | _], actions) or match?([%{action: "close"} | _], actions) ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => %{"closed" => true}}]}}

        true ->
          flunk("unexpected browser request: " <> inspect(request))
      end
    end

    http_post = fn url, body, headers ->
      send(test_pid, {:http, url, body, headers})

      choice =
        if is_map(body) and get_in(body, ["state", "page", "url"]) == "https://example.com/",
          do: "control_0",
          else: "done"

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "answers" => %{
               "action" => %{
                 "type" => "choice",
                 "choice" => choice,
                 "confidence" => 0.91,
                 "probabilities" => %{choice => 0.91, "stop" => 0.09}
               }
             }
           })
       }}
    end

    assert {:ok, result} =
             Newbee.Browser.Jev.run(
               %{url: "https://example.com", goal: "Open More information", max_steps: 3, close: true},
               config: %{"apiKey" => "test-key", "baseUrl" => "https://api.typesafe.ai"},
               browser_run: browser_run,
               http_post: http_post
             )

    assert result["status"] == "done"
    assert result["steps"] == 1
    assert hd(result["decisions"])["choice"] == "control_0"
    assert_received {:browser, open_request}
    assert open_request["session"] == "new"
    assert_received {:http, "https://api.typesafe.ai/v1/systemone", first_body, headers}

    assert Enum.any?(headers, fn {k, v} ->
             String.downcase(to_string(k)) == "authorization" and v == "Bearer test-key"
           end)

    criteria = get_in(first_body, ["questions", "action", "criteria"])
    assert Map.has_key?(criteria, "control_0")
    refute Map.has_key?(criteria, "invented")
    assert_received {:browser, click_request}
    [click] = click_request["actions"]
    assert click["action"] == "click"
    assert click["by"] == "id"
    assert click["selector"] == "more"
  end

  test "low confidence stops without executing a browser action" do
    snapshot = %{"url" => "https://example.com/", "title" => "Example", "text" => "Hi", "controls" => [], "links" => []}
    test_pid = self()

    browser_run = fn request ->
      send(test_pid, {:browser, request})

      case request["session"] do
        "new" ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => snapshot}]}}

        _ ->
          [action | _] = request["actions"]

          if action["action"] == "close",
            do: {:ok, %{"session" => "sess-1", "results" => []}},
            else: flunk("unexpected action " <> inspect(action))
      end
    end

    http_post = fn _url, _body, _headers ->
      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "answers" => %{
               "action" => %{
                 "type" => "choice",
                 "choice" => "scroll_down",
                 "confidence" => 0.2,
                 "probabilities" => %{"scroll_down" => 0.2, "stop" => 0.8}
               }
             }
           })
       }}
    end

    assert {:ok, result} =
             Newbee.Browser.Jev.run(
               %{url: "https://example.com", goal: "Find a hidden control", min_confidence: 0.6, close: true},
               config: %{"apiKey" => "test-key"},
               browser_run: browser_run,
               http_post: http_post
             )

    assert result["status"] == "stopped"
    assert result["reason"] == "low_confidence"
    assert result["steps"] == 0
  end

  test "an invented Jev action id is rejected" do
    snapshot = %{"url" => "https://example.com/", "title" => "Example", "text" => "Hi", "controls" => [], "links" => []}

    browser_run = fn request ->
      if request["session"] == "new" do
        {:ok, %{"session" => "sess-1", "results" => [%{"result" => snapshot}]}}
      else
        {:ok, %{"session" => "sess-1", "results" => []}}
      end
    end

    http_post = fn _url, _body, _headers ->
      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "answers" => %{
               "action" => %{
                 "type" => "choice",
                 "choice" => "eval_js",
                 "confidence" => 0.99,
                 "probabilities" => %{"eval_js" => 0.99}
               }
             }
           })
       }}
    end

    assert {:error, %{reason: :jev_invalid_choice, choice: "eval_js"}} =
             Newbee.Browser.Jev.run(
               %{url: "https://example.com", goal: "Click anything", close: true},
               config: %{"apiKey" => "test-key"},
               browser_run: browser_run,
               http_post: http_post
             )
  end

  test "HTML name drives input_values matching and the locator fallback" do
    snapshot = %{
      "url" => "https://example.com/form",
      "title" => "Form",
      "text" => "Customer name",
      "controls" => [
        %{"tag" => "input", "type" => "text", "html_name" => "custname", "name" => "", "disabled" => false}
      ],
      "links" => []
    }

    test_pid = self()

    browser_run = fn request ->
      send(test_pid, {:browser, request})
      actions = request["actions"] || request[:actions]

      cond do
        request["session"] == "new" ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => snapshot}]}}

        match?([%{"action" => "fill"} | _], actions) or match?([%{action: "fill"} | _], actions) ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => %{"filled" => true}}]}}

        match?([%{"action" => "snapshot"} | _], actions) or match?([%{action: "snapshot"} | _], actions) ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => Map.put(snapshot, "text", "Filled")}]}}

        match?([%{"action" => "close"} | _], actions) or match?([%{action: "close"} | _], actions) ->
          {:ok, %{"session" => "sess-1", "results" => [%{"result" => %{"closed" => true}}]}}

        true ->
          flunk("unexpected browser request: " <> inspect(request))
      end
    end

    http_post = fn _url, body, _headers ->
      choice = if get_in(body, ["state", "page", "text"]) == "Customer name", do: "control_0", else: "done"

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "answers" => %{
               "action" => %{
                 "type" => "choice",
                 "choice" => choice,
                 "confidence" => 0.9,
                 "probabilities" => %{choice => 0.9}
               }
             }
           })
       }}
    end

    assert {:ok, result} =
             Newbee.Browser.Jev.run(
               %{
                 url: "https://example.com/form",
                 goal: "Fill the customer name",
                 input_values: %{"custname" => "newbee"},
                 max_steps: 2,
                 close: true
               },
               config: %{"apiKey" => "test-key"},
               browser_run: browser_run,
               http_post: http_post
             )

    assert result["status"] == "done"
    assert_received {:browser, _open_request}
    assert_received {:browser, fill_request}
    [fill] = fill_request["actions"]
    assert fill["action"] == "fill"
    assert fill["value"] == "newbee"
    assert fill["by"] == "css"
    assert fill["selector"] == "input[name=\"custname\"]"
  end
end
