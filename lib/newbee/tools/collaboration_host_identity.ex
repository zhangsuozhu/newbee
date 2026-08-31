defmodule Newbee.Tools.Collaboration.HostIdentity do
  @moduledoc """
  Stable fallback identity for direct host calls.

  The launch directory is the project boundary when `NEWBEE_CWD` is set.
  Otherwise linked Git worktrees share the main worktree root resolved from
  the Git common directory.
  """

  @doc "Return the stable host session id for the current directory."
  def session_id, do: session_id(File.cwd!())

  @doc "Return the stable host session id for a directory."
  def session_id(cwd) when is_binary(cwd) do
    root = project_root(cwd)
    hash = :erlang.phash2(root) |> Integer.to_string(36)
    "host:" <> hash
  end

  @doc "Return the stable project root for the current directory."
  def project_root, do: project_root(File.cwd!())

  @doc "Return the stable project root for a directory."
  def project_root(cwd) when is_binary(cwd) do
    case launch_root() do
      {:ok, root} -> root
      :error -> git_project_root(cwd) || Path.expand(cwd)
    end
  end

  @doc "Whether two directories belong to the same project."
  def same_project?(left, right) when is_binary(left) and is_binary(right) do
    project_root(left) == project_root(right)
  end

  defp launch_root do
    case System.get_env("NEWBEE_CWD") do
      root when is_binary(root) and root != "" ->
        root = Path.expand(root)
        if File.dir?(root), do: {:ok, root}, else: :error

      _ ->
        :error
    end
  end

  defp git_project_root(cwd) do
    case git_common_dir(cwd) do
      {:ok, common_dir} -> Path.dirname(common_dir)
      :error -> nil
    end
  end

  defp git_common_dir(cwd) do
    case System.cmd("git", ["rev-parse", "--git-common-dir"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        common_dir = output |> String.trim() |> Path.expand(cwd)
        if Path.basename(common_dir) == ".git", do: {:ok, common_dir}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
