defmodule Newbee.Tools.Collaboration.HostIdentity do
  @moduledoc false
  # host 回退身份：优先取实际 cwd，保证 worktree 隔离下每项目独立 host 域
  def session_id do
    cwd = File.cwd!()
    # 若在 worktree 内，cwd 与 NEWBEE_CWD 不同则以 cwd 为准，否则沿用 cwd
    hash = :erlang.phash2(cwd) |> Integer.to_string(36)
    "host:" <> hash
  end
end
