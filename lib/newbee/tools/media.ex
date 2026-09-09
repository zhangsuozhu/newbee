defmodule Newbee.Tools.Media do
  @moduledoc """
  媒体文件上屏：图片、音频、视频、文本和 Markdown。

  ## Runnable example
      Newbee.Tools.Media.show(Path.expand("docs/design.md"), caption: "设计文档")
      Newbee.Tools.Media.show("out/result.ex", name: "源码")
      Newbee.Tools.Media.show("out/result.mp4", name: "生成视频", caption: "最终渲染")
      Newbee.Tools.Media.show_to("session-id", "out/report.md", caption: "发到指定会话")
      Newbee.Tools.Media.list()
      Newbee.Tools.Media.delete("media-id")

  选择它来把本地文件作为会话流卡片展示：图片可放大，音视频带播放控件，合法 UTF-8 的
  文本/代码按语言高亮，Markdown 直接渲染。文本超过 256 KiB、包含 NUL 或无法识别为
  UTF-8 时退化为下载卡片。它复制文件，不修改源文件。

  `show/2` 用当前会话；`show_to/3` 用指定会话。返回值为
  `{:ok, payload} | {:error, code, message}`，其中文本实时 payload 含 `content`，历史
  回放会按返回的 URL 读取正文；`list/0` 和 `delete/1` 管理当前会话的媒体。
  """

  @doc "把文件上屏到当前会话：图片/音频/视频内联，文本和 Markdown 也会在 WebUI 中显示。返回 {:ok, payload} | {:error, code, msg}。"
  def show(path, opts \\ []) when is_binary(path) do
    with {:ok, sid} <- current_session_id() do
      Newbee.Media.show(sid, path, opts)
    end
  end

  @doc "把文件上屏到指定会话；文本/Markdown 会在目标 WebUI 会话流中内联显示。"
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
