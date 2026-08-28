defmodule Newbee.TestSupport.WebTmpHome do
  @moduledoc """
  Web 测试隔离：把 GlobalStore.root 重定向到临时沙箱，使 auth.json/sessions.json/
  webauthn.json 全部落进沙箱，永不触碰真实 ~/.newbee/web/。
  注意：System.user_home!() 读 BEAM -home 启动参数（env 无效），
  故必须走 :global_root_override 覆盖点而非 System.put_env("HOME")。
  """

  @tmp_root "/tmp/newbee_web_test_homes"

  def enter(test_tag) do
    File.mkdir_p!(@tmp_root)
    dir = Path.join(@tmp_root, test_tag <> "-" <> Integer.to_string(:erlang.unique_integer([:positive])))
    File.mkdir_p!(Path.join(dir, "web"))
    orig = Application.get_env(:newbee, :global_root_override)
    Application.put_env(:newbee, :global_root_override, dir)
    {dir, orig}
  end

  def restore({dir, orig}) do
    case orig do
      nil -> Application.delete_env(:newbee, :global_root_override)
      p -> Application.put_env(:newbee, :global_root_override, p)
    end

    File.rm_rf!(dir)
    :ok
  end
end
