defmodule Newbee.SessionTombstoneTest do
  @moduledoc """
  删除墓碑：delete 成功后 TTL 内，mark_created / touch_index 不得再复活该会话。

  现场证据（WebUI 浏览器轮次 R453/R456/R457/R461/R472/R474/R475/R530，复现率约 1/5）：
  批量删除包含「当前会话」时，UI 提示「已删除 N 个会话」，但该会话刷新后仍在列表里——
  文件系统上 transcript 被重新创建为 0 字节文件并写回 .index.json，即迟到的
  ensure/mark_created（残留 WebSocket 的 cast_session 等）把刚删的空会话又建了出来。
  """
  use ExUnit.Case, async: false

  alias Newbee.Session

  defp transcript(id), do: Path.join([Newbee.GlobalStore.root(), "sessions", id <> ".jsonl"])

  defp index_path, do: Path.join([Newbee.GlobalStore.root(), "sessions", ".index.json"])

  defp indexed?(id) do
    case File.read(index_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) -> Enum.any?(list, &(&1["id"] == id))
          _ -> false
        end

      _ ->
        false
    end
  end

  setup do
    id = "tomb_#{System.unique_integer([:positive])}"
    on_exit(fn -> if File.regular?(transcript(id)), do: File.rm(transcript(id)) end)
    %{id: id}
  end

  test "正常创建的会话仍会进索引（墓碑不误伤未删除的 id）", %{id: id} do
    assert :ok = Session.mark_created(id)
    assert File.regular?(transcript(id))
    assert indexed?(id)
  end

  test "delete 后 mark_created 不得重建 transcript 与索引", %{id: id} do
    assert :ok = Session.mark_created(id)
    assert File.regular?(transcript(id))

    assert :ok = Session.delete(id)
    refute File.regular?(transcript(id))
    refute indexed?(id)
    assert Session.recently_deleted?(id)

    # 模拟迟到的 ensure：重建路径就是 mark_created
    assert :ok = Session.mark_created(id)
    refute File.regular?(transcript(id)), "墓碑 TTL 内不得重建 transcript"
    refute indexed?(id), "墓碑 TTL 内不得写回索引"
  end

  test "delete 后的 append 路径同样被 touch_index 挡住", %{id: id} do
    assert :ok = Session.mark_created(id)
    assert :ok = Session.delete(id)
    refute indexed?(id)

    # 迟到的 touch（append / set_cwd 都会走到）
    session = Session.open(id)
    Session.append(session, %{"role" => "user", "content" => "late write"})

    assert Session.recently_deleted?(id)
    refute indexed?(id), "墓碑 TTL 内 touch_index 不得把会话写回索引"
  end
end
