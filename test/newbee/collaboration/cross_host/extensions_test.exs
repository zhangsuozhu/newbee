defmodule Newbee.Collaboration.CrossHost.ExtensionsTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.CrossHost.Extensions

  setup do
    server = :"ext_test_#{System.unique_integer([:positive])}"
    start_supervised!({Extensions, name: server})
    %{server: server}
  end

  test "installs an allowlisted extension and invokes it", %{server: server} do
    source = """
    defmodule Newbee.RemoteExtensions.Demo do
      def ping(value), do: %{"echo" => value}
    end
    """

    manifest = %{
      "name" => "demo.ping",
      "version" => "1.0.0",
      "module" => "Newbee.RemoteExtensions.Demo",
      "function" => "ping",
      "arity" => 1,
      "description" => "回显"
    }

    assert {:ok, published} = Extensions.install(source, manifest, server: server)
    assert published["name"] == "demo.ping"
    assert published["source_sha256"] == :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    refute Map.has_key?(published, "source")

    assert [%{"name" => "demo.ping", "arity" => 1}] = Extensions.manifests(server)
    assert {:ok, %{"echo" => "hi"}} = Extensions.invoke("demo.ping", ["hi"], server)
    assert {:error, "not_found", _} = Extensions.invoke("demo.missing", [], server)
    assert {:error, "bad_request", _} = Extensions.invoke("demo.ping", [], server)
  end

  test "refuses modules outside the remote namespace", %{server: server} do
    source = """
    defmodule Kernel.Evil do
      def call, do: :ok
    end
    """

    manifest = %{"name" => "evil", "version" => "1", "module" => "Newbee.RemoteExtensions.Evil", "arity" => 0}

    assert {:error, "bad_source", _} = Extensions.install(source, manifest, server: server)
    assert Extensions.manifests(server) == []
  end

  test "rejects digest mismatch and code push without opt-in", %{server: server} do
    source = """
    defmodule Newbee.RemoteExtensions.Pinned do
      def call, do: :ok
    end
    """

    manifest = %{"name" => "pinned", "version" => "1", "module" => "Newbee.RemoteExtensions.Pinned", "arity" => 0}

    assert {:error, "digest_mismatch", _} =
             Extensions.install(source, Map.put(manifest, "source_sha256", String.duplicate("0", 64)), server: server)

    assert {:error, "full_control_required", _} =
             Extensions.install_remote(source, manifest, nil, false, server: server)

    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    assert {:ok, %{"name" => "pinned"}} =
             Extensions.install_remote(source, manifest, digest, true, server: server)
  end

  test "rejects a manifest that does not match the source exports", %{server: server} do
    source = """
    defmodule Newbee.RemoteExtensions.Other do
      def call, do: :ok
    end
    """

    manifest = %{"name" => "mismatch", "version" => "1", "module" => "Newbee.RemoteExtensions.Missing", "arity" => 0}

    assert {:error, "bad_source", _} = Extensions.install(source, manifest, server: server)
  end
end
