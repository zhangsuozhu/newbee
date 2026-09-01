defmodule Newbee.Web.UploadTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  setup do
    sid = "web-upload-test-#{System.unique_integer([:positive])}"
    Newbee.Web.Router.set_bind_ip({127, 0, 0, 1})

    on_exit(fn ->
      Newbee.Session.delete(sid)
      Newbee.Web.Router.set_bind_ip({127, 0, 0, 1})
    end)

    %{sid: sid}
  end

  test "raw upload endpoint stores a generic file and delete removes it", %{sid: sid} do
    conn =
      Plug.Test.conn(:post, "/api/upload/#{sid}?name=report%20final.pdf", "%PDF-test")
      |> Plug.Conn.put_req_header("content-type", "application/pdf")
      |> Newbee.Web.Router.call(@opts)

    assert conn.status == 201
    assert %{"ok" => uploaded} = Jason.decode!(conn.resp_body)
    assert uploaded["name"] == "report final.pdf"
    assert uploaded["content_type"] == "application/pdf"
    assert uploaded["size"] == 9

    assert {:ok, stored} = Newbee.Upload.info(sid, uploaded["id"])
    assert File.read!(stored["path"]) == "%PDF-test"

    deleted =
      Plug.Test.conn(:delete, "/api/upload/#{sid}/#{uploaded["id"]}")
      |> Newbee.Web.Router.call(@opts)

    assert deleted.status == 200
    assert {:error, "not_found", _} = Newbee.Upload.info(sid, uploaded["id"])
  end

  test "upload endpoint rejects an empty body", %{sid: sid} do
    conn =
      Plug.Test.conn(:post, "/api/upload/#{sid}?name=empty.txt", "")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Newbee.Web.Router.call(@opts)

    assert conn.status == 400
    assert %{"error" => %{"code" => "empty_file"}} = Jason.decode!(conn.resp_body)
  end

  test "remote upload requires authentication", %{sid: sid} do
    Newbee.Web.Router.set_bind_ip({0, 0, 0, 0})

    conn =
      Plug.Test.conn(:post, "/api/upload/#{sid}?name=secret.txt", "secret")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Newbee.Web.Router.call(@opts)

    assert conn.status == 401
    assert conn.halted
  end
end
