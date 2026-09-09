defmodule Newbee.Collaboration.CrossHost.ConnectionsTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.CrossHost.{Connections, Store}

  defmodule FakeWorker do
    def join(base_url, group_id, password, fingerprint, display, []) do
      send(self(), {:enrolled, base_url, group_id, password, fingerprint, display})

      {:ok,
       %{
         "protocol" => "xbridge.v1",
         "group" => %{"id" => group_id, "name" => "远端群", "devices" => %{}},
         "device" => %{"id" => "device-test", "plain" => "device-secret", "token_hash" => "hidden"},
         "caps" => %{},
         "quota" => %{}
       }}
    end
  end

  setup do
    Store.clear()
    :ok
  end

  test "normalizes bare Hub addresses and rejects cleartext" do
    assert {:ok, "https://192.168.0.20:4173"} = Connections.normalize_url("192.168.0.20")
    assert {:ok, "https://hub.example:8443"} = Connections.normalize_url("https://hub.example:8443/")
    assert {:error, "bad_request", _} = Connections.normalize_url("http://192.168.0.20:4173")
    assert {:error, "bad_request", _} = Connections.normalize_url("https://hub.example/path")
  end

  test "persists the device token separately and returns only public enrollment data" do
    gid = "remote-#{System.unique_integer([:positive])}"
    manager = :"connections_test_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{manager}.json")
    start_supervised!({Connections, name: manager, path: path})

    on_exit(fn ->
      _ = Connections.disconnect(gid, manager)
      _ = Newbee.Web.Session.destroy("worker-" <> gid)
      _ = File.rm(path)
      Store.clear()
    end)

    fingerprint = "sha256:" <> String.duplicate("a", 64)

    assert {:ok, enrollment} =
             Connections.join("192.168.0.20", gid, "invite-secret", fingerprint, "构建机",
               manager: manager,
               worker: FakeWorker
             )

    assert_receive {:enrolled, "https://192.168.0.20:4173", ^gid, "invite-secret", ^fingerprint, "构建机"}
    refute get_in(enrollment, ["device", "plain"])
    refute get_in(enrollment, ["device", "token_hash"])

    assert {:ok, %{"remote" => true, "server_url" => "https://192.168.0.20:4173"} = group} = Store.get_group(gid)
    refute inspect(group) =~ "device-secret"
    refute inspect(group) =~ "invite-secret"

    body = File.read!(path)
    assert body =~ "device-secret"
    refute body =~ "invite-secret"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert {:ok, %{group_id: ^gid}} = Connections.status(gid, manager)
  end

  test "advertises manifests and honors full control opt-in" do
    source = """
    defmodule Newbee.RemoteExtensions.ConnDemo do
      def call, do: :ok
    end
    """

    manifest = %{"name" => "conn.demo", "version" => "1", "module" => "Newbee.RemoteExtensions.ConnDemo", "arity" => 0}
    assert {:ok, _} = Newbee.Collaboration.CrossHost.Extensions.install(source, manifest)

    gid = "remote-cmd-#{System.unique_integer([:positive])}"
    manager = :"connections_cmd_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{manager}.json")
    start_supervised!({Connections, name: manager, path: path})

    on_exit(fn ->
      _ = Connections.disconnect(gid, manager)
      _ = Newbee.Web.Session.destroy("worker-" <> gid)
      _ = File.rm(path)
      Store.clear()
    end)

    fingerprint = "sha256:" <> String.duplicate("c", 64)

    assert {:ok, _enrollment} =
             Connections.join("192.168.0.20", gid, "invite-secret", fingerprint, "构建机",
               manager: manager,
               worker: FakeWorker,
               allow_full_control: true
             )

    config = File.read!(path) |> Jason.decode!() |> get_in(["connections", gid])
    assert config["full_control"] == true
    assert config["base_url"] == "https://192.168.0.20:4173"

    assert {:ok, %{"mode" => "normal"}} = Connections.set_full_control(gid, false, manager)
    config = File.read!(path) |> Jason.decode!() |> get_in(["connections", gid])
    assert config["full_control"] == false

    assert {:ok, %{"mode" => "full"}} = Connections.set_full_control(gid, true, manager)
    config = File.read!(path) |> Jason.decode!() |> get_in(["connections", gid])
    assert config["full_control"] == true
  end
end
