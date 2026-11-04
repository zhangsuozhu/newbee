defmodule Newbee.Web.SourceApi do
  @moduledoc "Host-only source configuration. External senders only use signature-checked webhook routes."
  alias Newbee.Colony.{Membership, Source, Store}

  def dispatch("conversation.source." <> action, p) do
    with {:ok, _actor, :owner} <- Membership.actor(p) do
      run(action, p)
    else
      {:ok, _, _} -> {:error, "forbidden", "来源策略只能由宿主管理员配置"}
      error -> error
    end
    |> normalize()
  end

  defp run("list", _), do: {:ok, %{"sources" => Source.list()}}

  defp run("events", p),
    do:
      {:ok,
       %{
         "events" => Source.events(p["sourceId"]),
         "replies" =>
           Store.all("source_outbox")
           |> Enum.filter(&(&1["source_id"] == p["sourceId"]))
           |> Enum.map(&Map.take(&1, ~w(id task_id status attempts last_error next_at receipt)))
       }}

  defp run("configure", p) do
    sid = p["sessionId"]
    attrs = p["config"]

    if is_binary(sid) and Regex.match?(~r/\A[0-9A-Za-z._-]{1,96}\z/, sid) and Newbee.Session.exists?(sid) and
         is_map(attrs) do
      with {:ok, config} <- Source.configure(Map.put(attrs, "root", Newbee.Session.cwd(sid))) do
        {:ok, %{"source" => config}}
      end
    else
      {:error, "bad_request", "请先选择项目对话，来源项目由该对话目录决定"}
    end
  end

  defp run("ingest", p) do
    with {:ok, %{"kind" => "local"}} <- Store.get("source_instances", p["sourceId"]),
         {:ok, event} <- Source.ingest(p["sourceId"], p["event"]) do
      {:ok, %{"event" => event}}
    else
      {:ok, _} -> {:error, "forbidden", "外部来源请使用签名 Webhook"}
      error -> error
    end
  end

  defp run("replay", p) do
    with {:ok, event} <- Source.replay(p["sourceId"], p["eventId"]), do: {:ok, %{"event" => event}}
  end

  defp run(_, _), do: {:error, "unknown_method", "未知来源操作"}
  defp normalize({:error, :not_found}), do: {:error, "not_found", "来源不存在"}
  defp normalize({:error, reason}), do: {:error, "operation_failed", inspect(reason)}
  defp normalize(other), do: other
end
