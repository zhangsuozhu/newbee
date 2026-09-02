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
    with {:ok, sid} <- current_session_id() do
      Newbee.Media.show(sid, path, opts)
    end
  end

  @doc "把文件上屏到指定会话。"
  def show_to(sid, path, opts \\ []) when is_binary(sid) and is_binary(path) do
    Newbee.Media.show(sid, path, opts)
  end

  @doc "列出当前会话已上屏媒体。"
  def list do
    with {:ok, sid} <- current_session_id() do
      Newbee.Media.list(sid)
    end
  end

  @doc "删除已上屏媒体。"
  def delete(media_id) when is_binary(media_id) do
    with {:ok, sid} <- current_session_id() do
      Newbee.Media.delete(sid, media_id)
    end
  end

  # 当前会话 id：模型 cell 携带的是主节点签发的短时 capability，而不是可伪造的
  # session_id 字符串。回主节点校验令牌后解析真实会话；无效令牌失败关闭。
  # 没有 capability 时保留 CLI/TUI 直跑路径，回退到主节点 current。
  defp current_session_id do
    case Process.get({__MODULE__, :capability}) do
      token when is_binary(token) ->
        case Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [token]) do
          {:ok, %{session_id: sid}} when is_binary(sid) -> {:ok, sid}
          _ -> {:error, "invalid_context", "媒体会话 capability 无效"}
        end

      _ ->
        fallback_session_id()
    end
  end

  defp fallback_session_id do
    case Newbee.Host.call(Newbee.Session, :current_id, []) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, "no_session", "当前没有可用会话"}
    end
  end
end
