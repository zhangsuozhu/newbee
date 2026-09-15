defmodule Newbee.Colony.Conversation do
  @moduledoc "Participant-scoped private conversations; shared work has its own execution session."
  alias Newbee.Colony.{Store, Work, Engine, Id}

  def create(cid, bid, actor) do
    if bid == actor do
      {:error, "self_conversation", "不能和自己对话"}
    else
      create_with(cid, bid, actor)
    end
  end

  defp create_with(cid, bid, actor) do
    with {:ok, _} <- Work.member(cid, actor),
         {:ok, bee} <- Work.member(cid, bid),
         {:ok, colony} <- Store.get_colony(cid) do
      cond do
        bee["kind"] == "human" ->
          id = Id.new(:message)

          conversation = %{
            "id" => id,
            "colony_id" => cid,
            "bee_id" => bid,
            "participants" => Enum.uniq([actor, bid]),
            "visibility" => "private",
            "kind" => "human"
          }

          with :ok <- Store.put("conversations", conversation),
               do: {:ok, %{"conversation" => conversation, "bee" => bee}}

        is_binary(bee["remote_member_id"]) ->
          {:error, "remote_conversation", "请在群里 @ 该成员创建工作，远端执行进展会同步到工作卡。"}

        true ->
          with {:ok, _, sid} <- Newbee.Web.Session.ensure(nil, colony["cwd"]) do
            conversation = %{
              "id" => sid,
              "colony_id" => cid,
              "bee_id" => bid,
              "participants" => [actor, bid],
              "visibility" => "private",
              "kind" => "ai"
            }

            with :ok <- Store.put("conversations", conversation) do
              Store.update(
                "bees",
                bid,
                nil,
                &{:ok, Map.update(&1, "conversations", [sid], fn ids -> Enum.uniq([sid | ids]) end)}
              )

              {:ok, %{"sessionId" => sid, "bee" => bee, "conversation" => conversation}}
            end
          end
      end
    end
  end

  def trail(cid, bid, actor) do
    with {:ok, _} <- Work.member(cid, actor),
         {:ok, _} <- Work.member(cid, bid),
         {:ok, trail} <- Engine.bee_trail(cid, bid) do
      # 工作执行会话也属于 Bee 的处理中上下文，列入会话列表以便用户跟进。
      conversations =
        Store.all("conversations")
        |> Enum.filter(
          &(&1["colony_id"] == cid and &1["bee_id"] == bid and
              actor in (&1["participants"] || []))
        )
        # 已删除的对话不能残留：AI 对话是真实会话，会话没了就不列。
        |> Enum.filter(&conversation_exists?/1)

      ids = Enum.map(conversations, & &1["id"])
      # 条数 / 时间 / 是否当前这些会话侧信息，直接用轨迹里已算好的那份，不再查一遍。
      metas = Map.new(trail["conversations"] || [], &{&1["id"], &1})

      views =
        Enum.map(conversations, fn c ->
          meta = Map.get(metas, c["id"]) || %{}

          %{
            "id" => c["id"],
            "session_id" => c["id"],
            "title" => conversation_title(c),
            "visibility" => c["visibility"],
            "kind" => c["kind"],
            "messages" => meta["messages"] || 0,
            "when" => meta["when"] || "",
            "current" => meta["current"] == true,
            "running" => meta["running"] == true,
            "busy" => meta["busy"] == true
          }
        end)

      trace =
        Enum.filter(
          trail["trace"],
          &(&1["channel"] != "dm" or get_in(&1, ["data", "conversation_id"]) in ids)
        )

      {:ok, Map.merge(trail, %{"conversations" => views, "trace" => trace})}
    end
  end

  # 真人对话是消息线程（没有会话），AI 对话是一条真实会话。
  defp conversation_exists?(%{"kind" => "ai", "id" => id}), do: Newbee.Session.exists?(id)
  defp conversation_exists?(_), do: true

  # 对话标题：改名写的是会话元数据，工作执行会话仍统一显示为「工作执行」。
  defp conversation_title(%{"visibility" => "work"}), do: "工作执行"

  defp conversation_title(c) do
    case Newbee.Session.custom_title(c["id"]) do
      title when is_binary(title) and title != "" -> title
      _ -> "私聊"
    end
  end

  def message(cid, bid, actor, text) do
    with true <- actor != bid,
         {:ok, _} <- Work.member(cid, actor),
         {:ok, bee} <- Work.member(cid, bid) do
      if bee["kind"] == "human" do
        existing =
          Store.all("conversations")
          |> Enum.find(
            &(&1["colony_id"] == cid and &1["kind"] == "human" and
                Enum.sort(&1["participants"] || []) == Enum.sort(Enum.uniq([actor, bid])))
          )

        conversation =
          if existing, do: {:ok, %{"conversation" => existing}}, else: create(cid, bid, actor)

        with {:ok, %{"conversation" => c}} <- conversation do
          Store.append_trace(%{
            "colony_id" => cid,
            "bee_id" => actor,
            "to_bee_id" => bid,
            "type" => "message",
            "channel" => "dm",
            "text" => text,
            "data" => %{"conversation_id" => c["id"]}
          })

          {:ok, %{"reply" => nil, "actions" => []}}
        end
      else
        {:error, "conversation_required", "请打开这位 AI 的对话，在原会话输入框中交流。"}
      end
    else
      false -> {:error, "self_conversation", "不能和自己对话"}
      {:error, code, msg} -> {:error, code, msg}
    end
  end
end
