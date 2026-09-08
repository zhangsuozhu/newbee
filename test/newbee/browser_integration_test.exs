defmodule Newbee.Browser.IntegrationTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.Capability
  alias Newbee.Tools.Browser

  @moduletag skip: System.get_env("NEWBEE_BROWSER_INTEGRATION") != "1"
  @moduletag timeout: 60_000

  @html ~S|<title>Browser regression</title><label>Query<input id="query"></label><label>Password<input type="password" value="never-return-this"></label><label>Enabled<input id="flag" type="checkbox" checked></label><button onclick="setTimeout(() => document.getElementById('status').textContent = document.getElementById('query').value, 30)">Apply</button><div id="status"></div>|

  setup do
    :ok =
      Capability.register(
        self(),
        "browser-integration-" <> Integer.to_string(System.unique_integer([:positive])),
        File.cwd!()
      )

    {:ok, token} = Capability.issue(self())
    Process.put({Newbee.Tools.Media, :capability}, token)
    :ok
  end

  defp with_page(fun) do
    assert {:ok, opened} =
             Browser.run(%{
               session: "new",
               timeout: 10_000,
               actions: [
                 %{action: "set_content", html: @html},
                 %{action: "snapshot"}
               ]
             })

    try do
      fun.(opened)
    after
      Browser.run(%{session: opened["session"], timeout: 5_000, actions: [%{action: "close"}]})
    end
  end

  test "page state survives calls and real input events produce observable results" do
    with_page(fn opened ->
      snapshot = List.last(opened["results"])["result"]
      assert Enum.any?(snapshot["controls"], &(&1["name"] == "Query"))
      assert Enum.any?(snapshot["controls"], &(&1["checked"] === true))
      refute Jason.encode!(snapshot) =~ "never-return-this"

      assert {:ok, changed} =
               Browser.run(%{
                 session: opened["session"],
                 actions: [
                   %{action: "fill", by: "label", selector: "Query", value: "retained"},
                   %{action: "click", by: "role", selector: "button", name: "Apply"},
                   %{action: "wait", function: "document.querySelector('#status').textContent === 'retained'"},
                   %{action: "text", selector: "#status"}
                 ]
               })

      assert List.last(changed["results"])["result"] == "retained"
      assert changed["session"] == opened["session"]

      assert {:ok, checked} =
               Browser.run(%{session: opened["session"], actions: [%{action: "value", selector: "#query"}]})

      assert hd(checked["results"])["result"] == "retained"
    end)
  end

  test "failed actions retain completed results and allow inspection without replay" do
    with_page(fn opened ->
      assert {:error, %{code: "timeout", details: details}} =
               Browser.run(%{
                 session: opened["session"],
                 action_timeout: 100,
                 actions: [
                   %{action: "fill", selector: "#query", value: "already-filled"},
                   %{action: "click", selector: "#does-not-exist"}
                 ]
               })

      assert details["action_index"] == 1
      assert length(details["completed"]) == 1

      assert {:ok, checked} =
               Browser.run(%{session: opened["session"], actions: [%{action: "value", selector: "#query"}]})

      assert hd(checked["results"])["result"] == "already-filled"
    end)
  end

  test "another owner cannot use a handle and context settings cannot change silently" do
    with_page(fn opened ->
      task =
        Task.async(fn ->
          :ok = Capability.register(self(), "browser-other-owner", File.cwd!())
          {:ok, token} = Capability.issue(self())
          Process.put({Newbee.Tools.Media, :capability}, token)
          Browser.run(%{session: opened["session"], actions: [%{action: "title"}]})
        end)

      assert {:error, %{reason: :session_expired}} = Task.await(task)

      assert {:error, %{code: "session_options_changed"}} =
               Browser.run(%{
                 session: opened["session"],
                 viewport: %{width: 600, height: 400},
                 actions: [%{action: "title"}]
               })
    end)
  end

  test "snapshot bounds and tab cap are enforced" do
    with_page(fn opened ->
      assert {:ok, small} =
               Browser.run(%{session: opened["session"], actions: [%{action: "snapshot", max_chars: 4, limit: 1}]})

      snapshot = hd(small["results"])["result"]
      assert String.length(snapshot["text"]) == 4
      assert snapshot["text_truncated"] === true
      assert length(snapshot["controls"]) == 1
      assert snapshot["controls_truncated"] === true

      assert {:error, %{code: "tab_limit", details: %{"completed" => completed}}} =
               Browser.run(%{session: opened["session"], actions: List.duplicate(%{action: "new_tab"}, 4)})

      assert length(completed) == 3
    end)
  end

  test "one-shot requests still work without a session and temporary runtime files are cleaned" do
    before_dirs = Path.wildcard(".newbee/browser/tmp/runtime-*") |> Enum.sort()

    assert {:ok, result} =
             Browser.run(%{timeout: 10_000, actions: [%{action: "set_content", html: @html}, %{action: "title"}]})

    assert List.last(result["results"])["result"] == "Browser regression"
    refute Map.has_key?(result, "session")
    assert Path.wildcard(".newbee/browser/tmp/runtime-*") |> Enum.sort() == before_dirs
  end

  test "a stuck page script is bounded and its session cannot be resumed" do
    with_page(fn opened ->
      assert {:error, %{reason: :runner_timeout, state_lost: true}} =
               Browser.run(%{
                 session: opened["session"],
                 timeout: 500,
                 actions: [%{action: "evaluate", expression: "() => { for (;;) {} }"}]
               })

      {:ok, %{session_id: owner}} = Capability.resolve(Process.get({Newbee.Tools.Media, :capability}))
      key = {owner, File.cwd!(), opened["session"]}

      wait_for_exit = fn recur, attempts ->
        cond do
          Registry.lookup(Newbee.Browser.Registry, key) == [] ->
            :ok

          attempts == 0 ->
            flunk("timed-out session did not stop")

          true ->
            Process.sleep(20)
            recur.(recur, attempts - 1)
        end
      end

      wait_for_exit.(wait_for_exit, 150)

      assert {:error, %{reason: :session_expired}} =
               Browser.run(%{session: opened["session"], actions: [%{action: "title"}]})
    end)
  end

  test "session recording flushes video paths on close" do
    dir = Path.join([".newbee", "browser", "videos-test-" <> Integer.to_string(System.unique_integer([:positive]))])

    assert {:ok, opened} =
             Browser.run(%{
               session: "new",
               timeout: 15_000,
               record_video_dir: dir,
               video_size: "320,240",
               actions: [
                 %{action: "set_content", html: ~S|<button onclick="document.title='clicked'">Go</button>|},
                 %{action: "click", by: "role", selector: "button", name: "Go"}
               ]
             })

    try do
      assert {:ok, closed} = Browser.run(%{session: opened["session"], timeout: 10_000, actions: [%{action: "close"}]})
      videos = closed["videos"]

      for path <- videos do
        assert String.starts_with?(path, Path.expand(dir))
        assert File.stat!(path).size > 0
      end
    after
      File.rm_rf!(dir)
    end
  end

  test "captcha handoff mechanics: element screenshot, user fill, observable result" do
    png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    html =
      "<img id=\"captcha\" width=\"120\" height=\"40\" src=\"data:image/png;base64," <>
        png <>
        "\"><label>Code<input id=\"code\"></label><button onclick=\"document.getElementById('echo').textContent = document.getElementById('code').value\">Verify</button><div id=\"echo\"></div>"

    shot =
      Path.join([
        ".newbee",
        "browser",
        "captcha-test-" <> Integer.to_string(System.unique_integer([:positive])) <> ".png"
      ])

    assert {:ok, opened} =
             Browser.run(%{
               session: "new",
               timeout: 15_000,
               idle_timeout: 600_000,
               actions: [%{action: "set_content", html: html}]
             })

    try do
      assert {:ok, pictured} =
               Browser.run(%{
                 session: opened["session"],
                 idle_timeout: 600_000,
                 actions: [%{action: "screenshot", selector: "#captcha", path: shot}]
               })

      captured = hd(pictured["results"])["result"]
      assert captured["path"] == Path.expand(shot)
      assert captured["bytes"] > 0

      assert {:ok, solved} =
               Browser.run(%{
                 session: opened["session"],
                 actions: [
                   %{action: "fill", selector: "#code", value: "AB12"},
                   %{action: "click", by: "role", selector: "button", name: "Verify"},
                   %{
                     action: "wait",
                     function: "document.querySelector('#echo').textContent === 'AB12'"
                   },
                   %{action: "text", selector: "#echo"}
                 ]
               })

      assert List.last(solved["results"])["result"] == "AB12"
    after
      Browser.run(%{session: opened["session"], timeout: 5_000, actions: [%{action: "close"}]})
      File.rm(shot)
    end
  end
end
