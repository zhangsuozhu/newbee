defmodule Newbee.UploadTest do
  use ExUnit.Case, async: true

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup do
    sid = "upload-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Newbee.Session.delete(sid) end)
    %{sid: sid}
  end

  test "stores files under an opaque name and preserves safe metadata", %{sid: sid} do
    assert {:ok, item} = Newbee.Upload.store(sid, "../notes.txt", "text/plain\r\nx-bad: yes", "hello")
    assert item.name == "notes.txt"
    assert item.content_type == "text/plainx-bad: yes"
    assert item.size == 5
    assert item.image == false
    assert item.id =~ ~r/\A[0-9a-f]{24}\z/

    assert {:ok, stored} = Newbee.Upload.info(sid, item.id)
    assert stored["name"] == "notes.txt"
    assert stored["path"] |> Path.basename() == item.id <> ".txt"
    assert File.read!(stored["path"]) == "hello"
    refute String.contains?(stored["path"], "notes.txt")
  end

  test "prepares trusted local paths and supported images for the agent", %{sid: sid} do
    assert {:ok, text_file} = Newbee.Upload.store(sid, "spec.md", "text/markdown", "# spec")
    assert {:ok, image} = Newbee.Upload.store(sid, "screen.png", "image/png", @png)

    assert {:ok, prepared} =
             Newbee.Upload.prepare_prompt(sid, [text_file.id, image.id], "Inspect these files")

    assert prepared.text =~ "Inspect these files"
    assert prepared.text =~ "spec.md"
    assert prepared.text =~ "screen.png"
    assert prepared.text =~ "local_path:"
    assert ["data:image/png;base64," <> _] = prepared.images
    assert length(prepared.files) == 2
  end

  test "rejects traversal session ids and unknown upload ids", %{sid: sid} do
    assert {:error, "bad_request", _} =
             Newbee.Upload.store("../outside", "a.txt", "text/plain", "no")

    assert {:error, "bad_request", _} = Newbee.Upload.info(sid, "../secret")
    assert {:error, "not_found", _} = Newbee.Upload.info(sid, String.duplicate("a", 24))
  end

  test "deletes the file and metadata", %{sid: sid} do
    assert {:ok, item} = Newbee.Upload.store(sid, "data.bin", nil, <<1, 2, 3>>)
    assert {:ok, stored} = Newbee.Upload.info(sid, item.id)
    assert :ok = Newbee.Upload.delete(sid, item.id)
    refute File.exists?(stored["path"])
    assert {:error, "not_found", _} = Newbee.Upload.info(sid, item.id)
  end
end
