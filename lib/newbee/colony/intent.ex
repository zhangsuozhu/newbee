defmodule Newbee.Colony.Intent do
  @moduledoc """
  意图解析：把自然语言（中文为主）转成蜂群操作。

  设计原则（附录 G/J）：单一对话框是唯一入口；意图规则少量、确定、可测；
  解析不出来时不报错，而是当作群聊消息。

  规则顺序（先匹配先赢）：
    help > progress > dissolve > leave > remove_bee > add_bee > decompose >
    accept > reject > switch > dispatch > chat
  """

  @type intent :: %{required(atom) => term}

  @doc "解析文本。返回 {:ok, intent} | {:error, :unknown}。"
  @spec parse(term) :: {:ok, intent} | {:error, :unknown}
  def parse(text) when is_binary(text) do
    t = text |> String.trim()

    cond do
      t == "" ->
        {:error, :unknown}

      Regex.match?(~r/^(你会做什么|你能做什么|你能干嘛|能干嘛|能做什么|帮助|功能|help|what can you do)/iu, t) ->
        {:ok, %{kind: :help}}

      Regex.match?(~r/(进展|进度|怎么样了|做到哪|状态如何|progress|status)/iu, t) ->
        {:ok, %{kind: :progress}}

      match =
          Regex.run(~r/(?<![打开])(?:建|创建|新建|开)(?:一个|个)?(?:新)?群(?:做|干|叫|名为)?\s*([^\s,，。;；]*)/u, t) ->
        [_, name] = match
        {:ok, %{kind: :create_colony, name: String.trim(name)}}

      Regex.match?(~r/(解散|删除|关掉|取消)(这个|该)?(群|蜂群)/u, t) ->
        {:ok, %{kind: :dissolve}}

      # 「我退出，让 bob 当 Queen」优先于普通退出
      match =
          Regex.run(
            ~r/(?:我)?(?:要)?(?:退出|离开|退)(?:这个|该)?(?:群|蜂群)?[，,。\s]*(?:请)?(?:让|把|由)\s*([^，,。\s]+?)\s*(?:当|做|成为)\s*(?:新)?(?:Queen|queen|蜂后|群主)/u,
            t
          ) ->
        [_, who] = match
        {:ok, %{kind: :leave, handover_to: who}}

      match = Regex.run(~r/(?:我|我们)(?:要)?(?:退出|离开)(?:这个|该)?(?:群|蜂群)?/u, t) ->
        _ = match
        {:ok, %{kind: :leave}}

      match =
          Regex.run(~r/(?:让|请|由)\s*([^，,。\s]+?)\s*(?:当|做|成为)\s*(?:新)?(?:Queen|queen|蜂后|群主)/u, t) ->
        [_, who] = match
        {:ok, %{kind: :handover, to: String.trim(who)}}

      match = Regex.run(~r/(?:把|将)?\s*([^，,。\s]+?)\s*(?:移出|踢出|移除|赶出)(?:这个|该)?(?:群|蜂群)?/u, t) ->
        [_, who] = match
        {:ok, %{kind: :remove_bee, who: String.trim(who)}}

      match = Regex.run(~r/(?:把|拉|加|邀请)\s*([^，,。\s]+?)\s*(?:拉进来|加进来|邀请进来|进来|加入|进群)/u, t) ->
        [_, who] = match
        {:ok, %{kind: :add_bee, who: String.trim(who)}}

      match = Regex.run(~r/(?:拆出|拆分|分成|拆成|拆为)(?:子任务)?[：:，,\s]*(.+)/u, t) ->
        [_, list] = match
        {:ok, %{kind: :decompose, children: split_children(list)}}

      Regex.match?(~r/^(通过|可以|验收通过|接受|approve|accept|ok|✓)[！!。.\s]*$/iu, t) ->
        {:ok, %{kind: :accept}}

      match = Regex.run(~r/(打回|重做|不通过|驳回|重来|reject)/u, t) ->
        _ = match
        {:ok, %{kind: :reject}}

      match = Regex.run(~r/(?:切换到|打开|看看|切到)\s*([^，,。\s]+?)(?:那个)?(?:群|蜂群)/u, t) ->
        [_, name] = match
        {:ok, %{kind: :switch, to: String.trim(name)}}

      match = Regex.run(~r/(?:让|叫|请|派)\s*([^，,。\s]{1,24})\s*(?:去|来|帮忙)?[，,]?\s*(?!当)(.+)/u, t) ->
        [_, who, what] = match
        {:ok, %{kind: :dispatch, assignee: String.trim(who), title: String.trim(what)}}

      match =
          Regex.run(
            ~r/^(?:帮我|给我|请|去|我想|我要|帮忙)?\s*((?:做|写|改|修|重构|优化|实现|调研|整理|测试|部署|设计|补|加|查|跑|验证|清理|梳理)\s*.+)$/u,
            t
          ) ->
        [_, what] = match
        {:ok, %{kind: :dispatch, assignee: nil, title: String.trim(what)}}

      true ->
        {:error, :unknown}
    end
  end

  def parse(_), do: {:error, :unknown}

  @doc "能力自述（L3）：每条都是可直接执行的一句指令。"
  def capabilities do
    [
      %{"group" => "做事", "icon" => "📋", "examples" => ["帮我重构登录模块", "让 auth-bot 补测试"]},
      %{"group" => "了解", "icon" => "🔍", "examples" => ["进展如何", "auth-bot 在干嘛"]},
      %{"group" => "拉人", "icon" => "👥", "examples" => ["加 bob 进来", "找一个会测试的 AI 加入"]},
      %{"group" => "验收", "icon" => "✅", "examples" => ["通过", "打回重做"]},
      %{"group" => "分群", "icon" => "🐝", "examples" => ["建个群做性能压测", "切换到文档群"]},
      %{"group" => "退出", "icon" => "🚪", "examples" => ["把 data-bot 移出这个群", "我退出，让 bob 当 Queen"]}
    ]
  end

  @doc "从一句文本里推断 Bee 类型（用于 add_bee）。"
  def infer_bee_kind(name) when is_binary(name), do: Newbee.Colony.Bee.infer_kind(name)
  def infer_bee_kind(_), do: "human"

  defp split_children(list) when is_binary(list) do
    list
    |> String.split(~r/[、,，;；]|和|以及|加上/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn title -> %{"title" => title} end)
  end
end
