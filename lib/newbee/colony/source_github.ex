defmodule Newbee.Colony.Source.GitHub do
  @moduledoc "GitHub issue replies reconcile a stable marker after ambiguous network outcomes."

  def deliver(%{"kind" => "local"}, entry), do: {:ok, %{"kind" => "local", "reply_id" => entry["id"]}}

  def deliver(%{"kind" => "github"} = config, entry) do
    token = if is_binary(config["token_env"]), do: System.get_env(config["token_env"]), else: nil

    if is_binary(token) and token != "" do
      marker = "<!-- newbee-reply:" <> entry["id"] <> " -->"
      path = "/repos/" <> config["repository"] <> "/issues/" <> entry["thread"] <> "/comments"
      since = DateTime.from_unix!(max(0, entry["created_at"] - 300_000), :millisecond) |> DateTime.to_iso8601()

      case find_reply(path, token, marker, since, 1) do
        {:found, comment} ->
          {:ok, %{"external_id" => comment["id"], "url" => comment["html_url"], "reconciled" => true}}

        :absent ->
          case request(:post, path, token, json: %{body: entry["body"] <> "\n\n" <> marker}) do
            {:ok, %{status: status, body: body}} when status in [200, 201] ->
              {:ok, %{"external_id" => body["id"], "url" => body["html_url"]}}

            other ->
              failure(other)
          end

        error ->
          error
      end
    else
      {:error, :source_token_missing}
    end
  end

  def deliver(_, _), do: {:error, :unsupported_source}

  defp find_reply(_path, _token, _marker, _since, page) when page > 10, do: {:error, :reconciliation_limit}

  defp find_reply(path, token, marker, since, page) do
    case request(:get, path, token, params: [per_page: 100, page: page, since: since]) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) ->
        case Enum.find(comments, &(is_binary(&1["body"]) and String.contains?(&1["body"], marker))) do
          nil -> if length(comments) == 100, do: find_reply(path, token, marker, since, page + 1), else: :absent
          found -> {:found, found}
        end

      other ->
        failure(other)
    end
  end

  defp request(method, path, token, opts) do
    Req.request(
      Keyword.merge(
        [
          method: method,
          url: "https://api.github.com" <> path,
          headers: [
            {"authorization", "Bearer " <> token},
            {"accept", "application/vnd.github+json"},
            {"x-github-api-version", "2022-11-28"},
            {"user-agent", "newbee-source"}
          ],
          redirect: false,
          retry: false,
          receive_timeout: 10_000,
          connect_options: [timeout: 5_000]
        ],
        opts
      )
    )
  rescue
    _ -> {:error, :transport_failure}
  end

  defp failure({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp failure(_), do: {:error, :transport_failure}
end
