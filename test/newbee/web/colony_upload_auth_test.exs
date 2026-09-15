# 回归：群聊附件直连 /api/upload 必须带 Bearer。
#
# 背景（真实缺陷）：composer.js 曾用 state.token 拼 Authorization，而 colony 的
# store.js 里 token 恒为 null（从未赋值），RPC 却从 localStorage 取 token。
# 于是本地回环模式一切正常，远程/需登录模式 RPC 正常、附件上传必然 401
# 「未登录或会话已过期」——用户报的“群聊不能粘图片”就是这个。
defmodule Newbee.Web.ColonyUploadAuthTest do
  use ExUnit.Case, async: false

  alias Newbee.Web.{Auth, Router}

  @opts Router.init([])

  setup do
    sandbox = Newbee.TestSupport.WebTmpHome.enter("colony_upload_auth")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)

    Auth.password_set?()
    Router.set_bind_ip({127, 0, 0, 1})
    on_exit(fn -> Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  describe "远程绑定（非回环）下的附件直连上传" do
    setup do
      Router.set_bind_ip({0, 0, 0, 0})
      :ok = Auth.set_password("hunter22")
      sid = "colony-upload-auth-" <> Integer.to_string(System.unique_integer([:positive]))
      on_exit(fn -> Newbee.Session.delete(sid) end)
      %{sid: sid}
    end

    test "不带 token 上传 → 401 且提示与用户所见一致", %{sid: sid} do
      conn =
        Plug.Test.conn(:post, "/api/upload/" <> sid <> "?name=pasted.png", "binary")
        |> Plug.Conn.put_req_header("content-type", "image/png")
        |> Router.call(@opts)

      assert conn.status == 401
      assert %{"error" => %{"message" => "未登录或会话已过期"}} = Jason.decode!(conn.resp_body)
    end

    test "带有效 token 上传 → 成功（前端同源令牌即可用）", %{sid: sid} do
      {:ok, token} = Auth.issue_token()

      conn =
        Plug.Test.conn(:post, "/api/upload/" <> sid <> "?name=pasted.png", "binary")
        |> Plug.Conn.put_req_header("content-type", "image/png")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Router.call(@opts)

      assert conn.status == 201
      assert %{"ok" => %{"id" => _}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "前端令牌来源" do
    test "colony 的直连上传与 RPC 用同一个令牌，不再读永不赋值的 state.token" do
      api = File.read!("priv/web/colony/api.js")
      composer = File.read!("priv/web/colony/composer.js")

      assert api =~ "export function authToken()"
      assert api =~ "const t = authToken();"

      assert composer =~ "authToken"
      refute composer =~ "state.token"

      # uploadAttachment 与 deleteAttachment 各一处
      assert composer |> String.split("= authToken();") |> length() == 3
    end
  end

  describe "令牌失效与加载失败的可恢复性" do
    test "rpc 遇到 unauthorized 时清掉失效令牌（本地模式可自愈）" do
      api = File.read!("priv/web/colony/api.js")

      assert api =~ "export function forgetAuthToken()"
      assert api =~ ~s(result.error.code === "unauthorized")
      assert api =~ "forgetAuthToken();"
      # URL 上的 ?token= 也要抹掉，否则坏令牌会被反复写回 localStorage
      assert api =~ "searchParams.delete(\"token\")"
    end

    test "加载失败不退回「还没有蜂群」引导态，并保留错误提示" do
      store = File.read!("priv/web/colony/store.js")
      app = File.read!("priv/web/colony/app.js")
      sidebar = File.read!("priv/web/colony/sidebar.js")

      # store: 失败时设置 lastError、不清空列表、有界重试
      assert store =~ "state.lastError = error.message || String(error);"
      assert store =~ "if (!authRetryUsed) {"
      assert store =~ "setTimeout(() => { void loadColonies(); }, 600);"
      refute store =~ "state.colonies = [];"

      # app: 引导分支必须先排除加载失败
      assert app =~ "if (state.lastError) {"
      assert app =~ "暂时无法加载蜂群："

      # sidebar: 空列表也要区分“没有匹配/加载失败/真的还没有”
      assert sidebar =~ "蜂群列表加载失败，点上方重试"
    end
  end

  describe "深钻与成员对话层级的面包屑" do
    test "页面提供面包屑容器，样式与模块同源" do
      html = File.read!("priv/web/index.html")
      css = File.read!("priv/web/colony/colony.css")

      # 回归：colony/breadcrumbs.js 一直按 #session-sub 渲染，但 index.html 里没有这个元素，
      # 结果深钻任务 / 打开成员对话时标题停在「群聊」、没有层级路径也没有返回入口。
      assert html =~ ~s(id="session-sub")
      assert html =~ "colony-sub"
      assert css =~ ".colony-sub .crumb-link"
      assert css =~ ".colony-sub .crumb-sep"
    end

    test "蜂群页标题不再暗示双击改名" do
      html = File.read!("priv/web/index.html")
      css = File.read!("priv/web/colony/colony.css")

      # 回归：colony 页加载的是 colony/app.js，没有 attachTitleRename；
      # 但 topbar 标题一直挂着 title="双击重命名" + I 形光标，双击却毫无反应。
      assert html =~ "id=\"session-title\""
      refute html =~ "双击重命名"
      assert css =~ ".colony-home #topbar .session-title { cursor: default; }"
    end

    test "容器缺失时仍更新标题，不再整体失效" do
      js = File.read!("priv/web/colony/breadcrumbs.js")

      assert js =~ "document.getElementById(\"session-sub\")"
      assert js =~ "if (!title) return;"
      # 两个分支都要在 appendChild 前守卫 sub
      assert js |> String.split("if (!sub) return;") |> length() == 3
    end
  end

  describe "只读长文本的复制入口" do
    test "邀请链接与帮助弹窗提供复制按钮" do
      forms = File.read!("priv/web/colony/forms.js")
      manage = File.read!("priv/web/colony/manage.js")

      # 回归：邀请链接是只读 textarea，之前只能手动选中复制。
      assert forms =~ "if (field.copy) {"
      assert forms =~ "navigator.clipboard.writeText(input.value)"

      invites = manage |> String.split("copy:true") |> length()
      # 邀请（同事/另一台环境）+ 帮助
      assert invites == 3
    end
  end

  describe "全群暂停按钮可见性" do
    test "updateScope 必须同时清掉 .hidden 类" do
      js = File.read!("priv/web/colony/composer.js")
      html = File.read!("priv/web/index.html")
      css = File.read!("priv/web/style.css")

      # 回归：静态标记 class 里带 hidden（index.html），CSS 是 .hidden{display:none !important}，
      # 而 updateScope 只改 hidden 属性、从不动类，于是「暂停/恢复全群 AI」永远不可见。
      assert html =~ "id=\"colony-pause\""
      assert css =~ ".hidden { display: none !important; }"
      assert js =~ "pause.classList.toggle('hidden', !show);"
      assert js =~ "pause.hidden = !show;"
    end

    test "成员级暂停/恢复有成功反馈" do
      js = File.read!("priv/web/colony/sidebar.js")

      assert js =~ "已暂停「${m.display}」在本群的执行"
      assert js =~ "已恢复「${m.display}」在本群的执行"
    end
  end

  describe "代码块复制与 Markdown 渲染" do
    test "colony 启动时注册复制事件委托" do
      app = File.read!("priv/web/colony/app.js")
      md = File.read!("priv/web/colony/md.js")

      # 回归：bindMarkdownCopy 只被 import、从未调用，于是消息里渲染出的
      # .md-copy 按钮点了没反应（实测剪贴板未被写入）。
      assert app =~ "import { bindMarkdownCopy } from \"./md.js\";"
      assert app =~ "bindMarkdownCopy();"
      assert md =~ "export function bindMarkdownCopy()"
      assert md =~ ~s(document.addEventListener("click")
      assert md =~ ".md-copy"
    end

    test "Markdown 渲染转义 HTML（防注入）" do
      md = File.read!("priv/web/colony/md.js")

      # 渲染器必须转义后再生成本地标签，否则模型输出里的 <script>/<img onerror> 会执行。
      assert md =~ "export function escapeHtml(s)"
      assert md =~ "escapeHtml(text)"
    end
  end

  test "任务级暂停/恢复有成功反馈" do
    js = File.read!("priv/web/colony/workflow.js")

    assert js =~ "已暂停这项工作（人仍可发言）"
    assert js =~ "已恢复这项工作"
  end

  describe "任务深钻的卡片去重" do
    test "被深钻任务自己的轨迹事件不再重复渲染卡片" do
      js = File.read!("priv/web/colony/drill.js")

      # 回归：traceNode 会把 `type: "task"` 的事件渲染成「该任务的当前卡片」，
      # 于是同一张卡在深钻里出现两次（实测 .work-flow-card = 2）。
      assert js =~ "const taskEventId = (t) => t.task_id || t.data?.task_id || t.data?.taskId;"
      assert js =~ "if (!id || id === task.id) return false;"
      assert js =~ "if (seenTaskCards.has(id)) return false;"
    end

    test "任务卡的控制动作有成功反馈" do
      js = File.read!("priv/web/colony/taskcard.js")

      assert js =~ "pause:'已暂停这项工作（人仍可发言）'"
      assert js =~ "resume:'已恢复这项工作'"
      assert js =~ "interrupt:'已中止这项工作'"
    end
  end

  describe "输入框模板预填" do
    test "prefill 不覆盖用户已输入的内容" do
      js = File.read!("priv/web/colony/composer.js")

      # 回归：prefill 曾是 input.value = text，用户打了半句再点「＋ 新工作 / ＋ 新任务」
      # 就被清空。现在模板插到原话前面。
      assert js =~ "const typed = input.value || \"\";"
      assert js =~ "!typed.trim().startsWith(text)"
      refute js =~ "input.value = text;"
    end
  end

  describe "卡片「更多」菜单的定位锚点" do
    test "card-menu-wrap 自身是定位锚点，不能只写在 .work-actions 下" do
      css = File.read!("priv/web/colony/colony.css")

      # 回归：菜单是 position:absolute + bottom:100%+6px 的向上弹层；
      # 之前 position:relative 只写在 .work-actions 下，工作流卡片用的 .work-flow-actions
      # 不匹配 → 菜单锚到整屏高的 #app，飘到视口上方（实测 top=-126，按钮在 345，点了看不到）。
      assert css =~ ".card-menu-wrap { position: relative; }"
      refute css =~ ".work-actions .card-menu-wrap { position: relative;"
    end
  end

  describe "创建蜂群期间的误投防护" do
    test "建群未完成前发送会被拦下，不会落到上一个蜂群" do
      app = File.read!("priv/web/colony/app.js")
      composer = File.read!("priv/web/colony/composer.js")

      # 回归：建群要走 create → loadColonies → selectColony，这段窗口里 state.colonyId
      # 还是旧群，此时发送会把消息投进上一个蜂群（实测把测试消息发进了真实群）。
      assert app =~ "state.switching = true;"
      assert app =~ "state.switching = false;"
      assert composer =~ "if (state.switching) { toast('正在创建蜂群，请稍候再发送', true); return; }"
    end
  end

  describe "添加成员的失败恢复" do
    test "重名失败后保留已填内容并重开对话框" do
      js = File.read!("priv/web/colony/manage.js")

      assert js =~ "let preset = {display:'研发助手', capabilities:'edit,shell,research'};"
      assert js =~ "while (!added) {"
      assert js =~ "preset = {display:value.display, capabilities:value.capabilities};"
    end
  end

  describe "发送串行化" do
    test "并发提交排队而不是静默丢弃" do
      js = File.read!("priv/web/colony/composer.js")

      # 回归：原来是 `if (send.sending) return;`——连按 Enter 时第二条被无声丢掉
      # （实测 4 次提交只发出 2 个 colony.say）。现在排到队列里串行发送。
      assert js =~ "export function send(ctx, text) {"
      assert js =~ "send.queue = next.catch(() => {});"
      assert js =~ "async function doSend(ctx, text)"
      refute js =~ "if (send.sending) return;"
    end
  end

  describe "成员层级的第三层面包屑" do
    test "从成员层级深钻任务时，标题与面包屑显示任务名（支持嵌套）" do
      js = File.read!("priv/web/colony/breadcrumbs.js")

      # 回归：成员层级只处理了「对话」子层，从历史任务/侧栏深钻任务时
      # 标题仍停在成员名，用户看不出点进了哪里。
      assert js =~ "const topDrill = drills[drills.length - 1];"
      assert js =~ "title.textContent = topDrill ? (topDrill.entry.title || \"任务\") : (bee.display || \"Bee\");"
      # 父任务 → 子任务要同时画出来（否则回不到父任务）
      assert js =~ "if (entry.type === \"drill\") drills.push({ entry, index });"
    end
  end

  describe "移动端触控目标" do
    test "历史任务行在手机宽度下加高到 44px" do
      css = File.read!("priv/web/colony/colony.css")

      # 回归：.bee-task-row 桌面默认 6px 内边距（约 32px 高），手机端误触率高；
      # 现有移动端约定（.group-view-tabs button）用 44px。
      assert css =~ ".bee-task-row { padding: 12px; }"
      assert css =~ "@media (max-width: 768px) {"
    end

    test "面包屑与轨迹任务条在手机宽度下加高到 32px（桌面不变）" do
      css = File.read!("priv/web/colony/colony.css")

      # 实测 320 宽：面包屑 18px、轨迹任务条 23px，都是可点导航项，手指点不准。
      assert css =~ ".colony-sub .crumb-link { display: inline-flex; align-items: center; min-height: 32px; }"
      assert css =~ ".bee-task { display: inline-flex; align-items: center; min-height: 32px; padding: 4px 8px; }"
      # 只在移动端媒体查询里生效：基础样式保持原来的紧凑尺寸
      assert css =~ ".colony-sub .crumb-link {\n  background: none; border: 0; padding: 0; cursor: pointer;"
    end
  end

  describe "成员视图对 AI 成员的输入" do
    test "会转进它的对话，而不是撞 conversation_required" do
      composer = File.read!("priv/web/colony/composer.js")
      app = File.read!("priv/web/colony/app.js")
      shell = File.read!("priv/web/colony/shell.js")
      workspace = File.read!("priv/web/app.js")

      # 回归：成员层级里给 AI 打字，colony.say 会走 1:1 通道并被服务端拒绝
      # （conversation_required），用户只看到报错，这句话也发不出去。
      assert composer =~ "await ctx.deliverToConversation(member, text);"
      assert app =~ "deliverToConversation: async (bee, text) =>"
      assert shell =~ "export function sendIntoConversation(text)"
      # 宿主重发直到 embed 回执；embed 用 commandId 幂等 + 回执，避免发两遍
      assert shell =~ "newbeeCommand:'send'"
      assert shell =~ "newbeeWorkspace === 'sent'"
      assert workspace =~ "newbeeWorkspace: \"sent\", commandId: data.commandId"
      # 提示文案不再承诺一个发不出去的地址
      assert composer =~ "将转入 ${bee.display} 的对话"
    end
  end

  describe "成员层级里的嵌套深钻" do
    test "面包屑给出父任务层级，可点回父任务" do
      js = File.read!("priv/web/colony/breadcrumbs.js")

      # 回归：bee 模式只渲染最后一层 drill，从子任务回不到父任务
      # （state.stack 里其实已有父任务，只是没画出来）。
      assert js =~ "const drills = [];"
      assert js =~ "if (entry.type === \"drill\") drills.push({ entry, index });"
      assert js =~ "last ? () => {} : () => gotoLevel(d.index)"
    end
  end
end
