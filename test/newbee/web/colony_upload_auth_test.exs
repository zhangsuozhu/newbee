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

      # store: 普通失败保留列表、有界重试；成员凭据失效另行清空旧视图
      assert store =~ "state.lastError = error.message || String(error);"
      assert store =~ "if (!authRetryUsed) {"
      assert store =~ "setTimeout(() => { void loadColonies(); }, 600);"

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
      assert forms =~ "const ok = await copyToClipboard(input.value);"

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

      assert js =~ "const settled = fresh?.control_state === (command === 'resume' ? 'running' : 'paused');"
      assert js =~ "已请求暂停这项工作，等待执行器确认（人仍可发言）"
      assert js =~ "已请求中止这项工作，等待执行器确认"
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
      assert js =~ "if (owner && !handover.length) {"
      assert js =~ "当前没有可交接的真人成员，请先邀请一位真人成员"
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

  describe "键盘可达性" do
    test "侧栏收起时不让屏外控件留在 Tab 顺序里" do
      shell = File.read!("priv/web/colony/shell.js")

      # 回归：侧栏收起后 #sidebar-toggle(left:-72)、#model-config-btn(left:-110)
      # 仍在屏幕外可聚焦，键盘用户会停在一个看不见的按钮上。
      assert shell =~ "sidebar.inert = collapsed;"
      assert shell =~ "sidebar.setAttribute('aria-hidden', 'true')"
      assert shell =~ "sidebar.removeAttribute('aria-hidden')"
      assert shell =~ "const focusExpand = collapsed"
      assert shell =~ "if (focusExpand) $('sidebar-expand')?.focus({preventScroll:true});"
      assert shell =~ "if (focusToggle) $('sidebar-toggle')?.focus({preventScroll:true});"
      assert shell =~ "else if (localStorage.getItem('newbee.sidebar') !== '1')"
      assert shell =~ "collapseSidebar(false, false);"
      assert shell =~ "event.key === 'Escape' && matchMedia('(max-width: 768px)').matches"
      assert shell =~ "event.stopImmediatePropagation();"
      assert shell =~ "collapseSidebar(true);"
      assert shell =~ "dialog[open]"
    end
  end

  describe "Bee 会话键盘操作" do
    test "历史会话行可用 Enter 或 Space 打开" do
      sidebar = File.read!("priv/web/colony/sidebar.js")

      assert sidebar =~ "item.tabIndex = 0;"
      assert sidebar =~ "item.setAttribute(\"role\", \"button\");"
      assert sidebar =~ "[\"Enter\", \" \"].includes(event.key)"
      assert sidebar =~ "event.preventDefault();"
    end
  end

  describe "卡片菜单的键盘操作" do
    test "Esc 关闭菜单并把焦点还给触发按钮" do
      util = File.read!("priv/web/colony/util.js")

      # 回归：卡片「更多」菜单以前只有全局 click 能关，键盘用户按 Esc 无反应。
      assert util =~ "document.addEventListener(\"keydown\", (event) => {"
      assert util =~ "pop.parentElement && pop.parentElement.querySelector(\".card-more\")"
      assert util =~ "if (trigger) trigger.focus();"
      assert util =~ "btn.focus({preventScroll: true});"
      assert util =~ "const opening = !pop.classList.toggle(\"hidden\");"
      assert util =~ "const viewportWidth = document.documentElement.clientWidth || innerWidth;"
      assert util =~ "pop.style.left = `${margin - wrapRect.left}px`;"
      assert util =~ "if (pop.contains(event.target) || trigger?.contains(event.target)) return;"
      assert util =~ "document.body.contains(trigger)"
    end
  end

  describe "复制到剪贴板" do
    test "统一走 copyToClipboard，失败如实反馈" do
      app = File.read!("priv/web/app.js")
      cutil = File.read!("priv/web/colony/util.js")
      md = File.read!("priv/web/colony/md.js")
      forms = File.read!("priv/web/colony/forms.js")

      # 回归：以前 8 处复制各自调 navigator.clipboard，无 catch、无不安全上下文兜底，
      # 失败也显示「已复制」（有的连 execCommand 都不试）。
      assert app =~ "function copyToClipboard(text)"
      assert app =~ "function copyWithFeedback(btn, text, label)"
      assert cutil =~ "export async function copyToClipboard(text)"
      assert md =~ "copyToClipboard(code).then((ok) => {"
      assert forms =~ "const ok = await copyToClipboard(input.value);"
      refute md =~ ".then(done, done)"
      refute app =~ "navigator.clipboard.writeText(raw)"
      refute app =~ "navigator.clipboard.writeText(fileViewer.content)"
    end
  end

  describe "动作失败要可见" do
    test "菜单与直接按钮都把错误提示出来，而不是只进控制台" do
      util = File.read!("priv/web/colony/util.js")
      taskcard = File.read!("priv/web/colony/taskcard.js")
      workflow = File.read!("priv/web/colony/workflow.js")

      # 回归：cardMenu 的 catch 只 console.error；workflow 的 act / 答复并继续、
      # taskcard 的 我来处理 / 提交成果 / 继续 都不走 guard → 失败时界面毫无反应。
      assert util =~ "toast(error.message || \"操作失败，请重试\", true)"
      assert workflow =~ "async function act(t, action, attrs = {}) {"
      assert workflow =~ "guard(() => rpc('colony.work.continue'"
      assert workflow =~ "if (t.owner_kind !== 'human' && ['executing','integrating'].includes(w.phase)"
      assert workflow =~ "立即中止"
      assert workflow =~ "name:'reason',label:'停止原因',multiline:true,required:true"
      assert workflow =~ "已请求中止这项工作，等待执行器确认"
      assert taskcard =~ "guard(() => rpc('colony.task.transition'"
      assert taskcard =~ "guard(() => rpc('colony.work.submit'"
      assert taskcard =~ "guard(() => rpc('colony.work.continue'"
      assert taskcard =~ "if (task.approval_required || task.status === 'blocked')"
      assert taskcard =~ "if (task.status !== 'pending_review') actions.append(action('提交成果'"
      assert taskcard =~ "name:'reason', label:'停止原因', multiline:true, required:true"
      assert taskcard =~ "已请求中止这项工作，等待执行器确认"
    end
  end

  describe "验收条的键盘流" do
    test "键盘激活去验收后，焦点交给通过按钮" do
      composer = File.read!("priv/web/colony/composer.js")

      # 回归：切换标签后焦点落到 body，键盘用户要从页首 Tab 二十多次才够得到「通过」。
      assert composer =~ "const fromKeyboard = !event || event.detail === 0;"
      assert composer =~ "const accept = document.querySelector(\".btn-allow\");"
      assert composer =~ "if (++tries < 12) setTimeout(grab, 120);"
    end
  end

  describe "跳转后的焦点管理" do
    test "路由变化且焦点落空时交给主区域" do
      app = File.read!("priv/web/colony/app.js")

      # 回归：面包屑/标签/任务卡跳转后焦点掉到 body，键盘用户接着 Tab 得从页首重来。
      assert app =~ "function focusMainRegion() {"
      assert app =~ "if (!sameRoute && lastRoute !== null) focusMainRegion();"
      assert app =~ "main.focus({ preventScroll: true });"
      # 不能抢正在操作的控件：只有焦点已落空/节点已被替换才动
      assert app =~ "if (inDoc) return;"
    end
  end

  describe "成员层级的「＋新任务」" do
    test "走群聊 @点名，而不是把话发进 1:1（那里建不了群任务）" do
      app = File.read!("priv/web/colony/app.js")

      # 回归：按钮承诺「直接派给它」，但成员层级里 colony.say 走 1:1 通道会被拒。
      # 真正能派给指定 Bee 的路径是群聊 @点名（服务端按 @ 直投）。
      assert app =~ "prefill(bee ? `@${bee.display} 建个任务：` : \"建个任务：\");"
      assert app =~ "state.groupTab = \"messages\";"
      assert app =~ "resetToChat();"
    end
  end

  describe "手机端 @ 候选与卡片菜单行高" do
    test "≤768px 时加到 44px，桌面保持 36px" do
      css = File.read!("priv/web/colony/colony.css")

      # 回归：@ 候选行与卡片菜单项 36px，手机上是手指点的列表项，误触率高。
      assert css =~ ".colony-home :is(.card-menu-item, .mention-item) { height: 44px; min-height: 44px; }"
      assert css =~ "box-sizing: border-box; height: 36px; min-height: 36px; padding: 0 10px;"
    end
  end

  describe "任务深钻里的成果" do
    test "按 task_id 补出成果卡（含验收按钮），并按轨迹去重" do
      chat = File.read!("priv/web/colony/chat.js")
      drill = File.read!("priv/web/colony/drill.js")

      # 回归：人的提交（colony.work.submit）不一定写任务级 Trace，深钻只渲染 Trace，
      # 于是「已提交、待验收」的任务在详情里显示「还没有工作记录」，也验收不了。
      assert chat =~ "export function honeyNode(t, ctx) {"
      assert drill =~ "import { traceNode, honeyNode } from \"./chat.js\";"
      assert drill =~ "filter((h) => h.task_id === task.id)"
      assert drill =~ "if (tracedHoneyIds.has(h.id)) continue;"
      # 提交/验收各写一条成果事件，而卡片渲染的是「当前」状态：不按 honey_id 去重
      # 就会出现两张一模一样、状态相同的卡。
      assert drill =~ "const seenHoneyCards = new Set();"
      # 群聊时间线同理：同一成果的多条事件只留最后一条，否则两张同状态的卡。
      assert chat =~ "const timelineTrace = [];"
      assert chat =~ "for (const group of groupTrace(timelineTrace)) {"
      assert drill =~ "if (hid && seenHoneyCards.has(hid)) return false;"
      assert drill =~ "成果见上方成果卡"
    end
  end

  describe "任务深钻首屏滚动" do
    test "进入深钻先显示任务头卡，不被长轨迹推到底" do
      app = File.read!("priv/web/colony/app.js")

      assert app =~ "const startAtTop = state.view === 'drill' || overview;"
      assert app =~ "if (!sameRoute) transcript.scrollTop = startAtTop ? 0 : transcript.scrollHeight;"
      assert app =~ "else if (wasNearBottom && !startAtTop) scrollBottom();"
    end
  end

  describe "工具卡详情" do
    test "未枚举的字段也兜底展示（出错时点开能看到原因）" do
      chat = File.read!("priv/web/colony/chat.js")

      # 回归：以前 detailText 只认固定几个键，工具报错/输出落在别的键上时
      # 「工具执行出错」点开是空的，用户看不到原因。
      assert chat =~ "for (const [k, v] of Object.entries(d)) {"
      assert chat =~ "bits.join(\"\\n\").slice(0, 2000)"
    end
  end

  describe "「恢复任务」的反馈" do
    test "蜂群整体仍暂停时不谎报「已恢复」" do
      js = File.read!("priv/web/colony/workflow.js")
      composer = File.read!("priv/web/colony/composer.js")

      # 回归：scope=work 恢复成功，但蜂群级还暂停着时任务其实没跑起来，
      # 以前照样 toast「已恢复这项工作」，用户以为在跑了。
      assert js =~ "但蜂群整体仍在暂停，请先恢复全群"
      assert js =~ "const stillPaused = !!(fresh && fresh.control_state && fresh.control_state !== 'running');"
      assert js =~ "if (t.control_state === 'pausing') return '正在暂停，等待确认';"

      assert composer =~
               "const settled = running ? state.data?.control_state === 'paused' : state.data?.control_state === 'running';"

      assert composer =~ "已请求暂停全群 AI，等待执行器确认（人仍可发言）"
      assert composer =~ "已请求恢复全群 AI，等待执行器确认"
      assert js =~ "retry_member:'已提交补充说明，正在重试'"
      assert js =~ "if (success) toast(success);"
    end
  end

  describe "终态任务的隔离工作区清理" do
    test "前端有确认对话框并调用 Queen 专属清理 RPC" do
      forms = File.read!("priv/web/colony/forms.js")
      taskcard = File.read!("priv/web/colony/taskcard.js")
      workflow = File.read!("priv/web/colony/workflow.js")
      api = File.read!("lib/newbee/web/colony_api.ex")

      engine = File.read!("lib/newbee/colony/engine.ex")

      assert forms =~ "export function confirmAction(title, message, confirmLabel = '确认')"
      assert taskcard =~ "if (!yes) return;"
      assert taskcard =~ "rpc('colony.workspace.cleanup'"
      assert workflow =~ "if (!yes) return;"
      assert workflow =~ "rpc('colony.workspace.cleanup'"
      assert api =~ "colony.workspace.cleanup"
      assert engine =~ "只有已结束任务才能清理工作区"
    end
  end

  describe "对话框关闭焦点" do
    test "form、确认框和侧栏选择框都恢复触发控件" do
      forms = File.read!("priv/web/colony/forms.js")
      app = File.read!("priv/web/colony/app.js")
      sidebar = File.read!("priv/web/colony/sidebar.js")

      assert forms =~ "export function restoreFocus(previousFocus)"
      assert forms =~ "node.noValidate = true;"
      assert forms =~ "dialog.remove(); restoreFocus(previousFocus);"
      assert sidebar =~ "import { form, confirmAction, restoreFocus } from './forms.js';"
      assert sidebar =~ "dialog.remove(); restoreFocus(previousFocus);"
      assert forms =~ "const menuTrigger = previousFocus.closest?.('.card-menu-wrap')?.querySelector('.card-more');"

      assert forms =~
               "const target = focusable(previousFocus) ? previousFocus : focusable(menuTrigger) ? menuTrigger : main;"

      assert forms =~ "setTimeout(() => {"
      assert forms =~ "  }, 50);"

      assert app =~ "if (document.querySelector('dialog[open]')) return;"
      assert app =~ "let dialogEscape = false;"
      assert app =~ "dialogEscape = true;"
      assert app =~ "if (dialogEscape || e.target?.closest?.('dialog')) return;"
      assert app =~ "frame.focus({ preventScroll: true });"
      assert app =~ "lastRoute = route;"
      assert app =~ "const input = frame.contentDocument?.getElementById(\"input\");"
      assert app =~ "if (input) input.focus({ preventScroll: true });"
      assert app =~ "frame.addEventListener(\"load\", focusEmbed, { once: true });"
    end
  end

  describe "Bee 对话返回焦点" do
    test "从执行过程列表返回蜂群时接管 transcript 焦点" do
      breadcrumbs = File.read!("priv/web/colony/breadcrumbs.js")

      assert breadcrumbs =~ "function focusChatRegion()"
      assert breadcrumbs =~ "await exitBeeMode();"
      assert breadcrumbs =~ "setTimeout(focusChatRegion, 0);"
    end
  end

  describe "一次性邀请码错误恢复" do
    test "已使用邀请码清掉 hash 后回到可用蜂群界面" do
      js = File.read!("priv/web/colony/manage.js")

      assert js =~ "if (error.code !== 'invalid_invite') throw error;"
      assert js =~ "history.replaceState(null, '', location.pathname);"
      assert js =~ "邀请码已使用或过期，请让邀请方重新生成"
      assert js =~ "await selectColony(result.colony.id);"
    end
  end

  describe "成员令牌失效隔离" do
    test "无效成员令牌不被清掉并清空旧蜂群视图" do
      api = File.read!("priv/web/colony/api.js")
      store = File.read!("priv/web/colony/store.js")
      manage = File.read!("priv/web/colony/manage.js")
      shell = File.read!("priv/web/colony/shell.js")
      app = File.read!("priv/web/colony/app.js")
      sidebar = File.read!("priv/web/colony/sidebar.js")

      assert api =~ "const MEMBER_TOKEN_KEY = \"newbee.member_token\";"
      assert api =~ "sessionStorage.getItem(MEMBER_TOKEN_KEY)"
      assert api =~ "if (member) return member;"
      assert api =~ "result.error.code === \"unauthorized\" && !isMemberSession()"
      assert api =~ "if (method === \"auth.status\")"
      assert api =~ "markMemberSession(t);"
      assert manage =~ "markMemberSession(result.token);"
      refute manage =~ "localStorage.setItem('newbee.token', result.token);"
      assert store =~ "invalidateMemberSession();"
      assert store =~ "成员凭据已失效，请重新加入蜂群"
      assert shell =~ "forgetAuthToken(); location.assign('/')"
      assert manage =~ "state.lastError = '已退出蜂群';"
      assert manage =~ "emit();"
      assert manage =~ "toast('已退出蜂群，可用新的邀请链接重新加入')"
      assert app =~ "const memberExpired = state.lastError === '成员凭据已失效，请重新加入蜂群'"
      assert app =~ "const left = state.lastError === '已退出蜂群'"
      assert app =~ "if (!memberExpired && !left)"
      assert sidebar =~ "成员凭据已失效，请使用新的邀请链接重新加入蜂群"
      assert sidebar =~ "已退出蜂群，可使用新的邀请链接重新加入蜂群"
    end
  end

  describe "工作流折叠状态" do
    test "重绘后保留用户打开的工作详情" do
      workflow = File.read!("priv/web/colony/workflow.js")

      assert workflow =~ "const openFolds = new Set();"
      assert workflow =~ "folded.addEventListener('toggle'"
      assert workflow =~ "folded.open = openFolds.has(t.id);"
      assert workflow =~ "const openDetails = new Set();"
      assert workflow =~ "function rememberDetails(details, taskId, key)"
      assert workflow =~ "rememberDetails(details, t.id, key);"
      assert workflow =~ "rememberDetails(history, t.id, 'history');"
    end
  end

  describe "思考强度菜单焦点" do
    test "选择档位或按 Escape 后把焦点还给按钮" do
      app = File.read!("priv/web/app.js")

      assert app =~ "const closeEffort = (focus = false) =>"
      assert app =~ "if (focus) effortBtn.focus({ preventScroll: true });"
      assert app =~ "closeEffort(true);"
    end
  end

  describe "嵌入 Mission Control 焦点" do
    test "面板开关在宿主与 iframe 间交接焦点" do
      app = File.read!("priv/web/app.js")

      assert app =~ "const focusTarget = $(\"mc-collapse\");"
      assert app =~ "if (focusTarget) focusTarget.focus({ preventScroll: true });"
      assert app =~ "window.parent.document.getElementById(\"mc-expand\")"
      assert app =~ "focusTarget.focus({ preventScroll: true });"
    end
  end

  describe "工作流超时确认" do
    test "超时后给出结果可能已处理提示并主动刷新" do
      api = File.read!("priv/web/colony/api.js")
      workflow = File.read!("priv/web/colony/workflow.js")

      assert api =~ "timeout.code = 'timeout';"
      assert workflow =~ "if (e?.code === 'timeout')"
      assert workflow =~ "void refresh();"
      assert workflow =~ "请求超时；结果可能已处理，正在刷新工作卡"
    end
  end
end
