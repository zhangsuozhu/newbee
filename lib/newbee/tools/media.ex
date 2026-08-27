defmodule Newbee.Tools.Media do
  @moduledoc """
  媒体上屏工具 (DESIGN §3.2 工具库)：把图片/音频/视频一键展示到 WebUI。

  模型在 run_elixir 里调用：

      Newbee.Tools.Media.show(Path.expand("shots/a.png"), caption: "页面截图")
      Newbee.Tools.Media.show("out/result.mp4", name: "生成视频", caption: "最终渲染")

  - 文件会被复制进当前会话的媒体制品目录，生成 /media/<sid>/<id> URL；
  - 事件 :media_show 经 Bus → WebSocket 下行，前端即时渲染卡片；
  - 返回 describe 文本（含 media_id / url），供模型转述给用户。
  """

  @doc "把文件上屏到当前会话。返回 {:ok, payload} | {:error, code, msg}。"
  def show(path, opts \\ []) when is_binary(path) do
    sid = current_session_id()
    Newbee.Media.show(sid, path, opts)
  end

  @doc "把文件上屏到指定会话。"
  def show_to(sid, path, opts \\ []) when is_binary(sid) and is_binary(path) do
    Newbee.Media.show(sid, path, opts)
  end

  @doc "列出当前会话已上屏媒体。"
  def list do
    sid = current_session_id()
    Newbee.Media.list(sid)
  end

  @doc "删除已上屏媒体。"
  def delete(media_id) when is_binary(media_id) do
    sid = current_session_id()
    Newbee.Media.delete(sid, media_id)
  end

  # 当前会话 id 从主节点取（DEE 求值节点与主 VM 的 persistent_term 不共享；
  # Host.call 在 on_main? 时本地调用，否则 RPC 到主节点）。
  defp current_session_id do
    case Newbee.Host.call(Newbee.Session, :current_id, []) do
      id when is_binary(id) -> id
      _ -> "unknown"
    end
  end
end
