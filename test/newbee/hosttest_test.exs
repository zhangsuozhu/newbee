defmodule Newbee.HostTest do
  use ExUnit.Case, async: true
  alias Newbee.Host

  test "safe_config 脱敏 apiKey" do
    cfg = Host.safe_config()
    providers = cfg["providers"] || %{}
    assert map_size(providers) >= 1

    Enum.each(providers, fn {_name, p} ->
      key = p["apiKey"]
      assert is_binary(key)
      # 要么是占位符，要么是打码形式（首 4 字符 + … + 尾 4 字符，长度远小于明文）
      assert key in ["[未配置]", "[已配置]"] or (String.contains?(key, "…") and byte_size(key) < 16)
    end)
  end

  test "call/4 preserves call/3 semantics while accepting an explicit RPC timeout" do
    assert Host.call(Enum, :sum, [[1, 2, 3]], 1_000) == 6
  end

  test "on_main? 为主 VM 时 true" do
    assert Host.on_main?()
    assert Host.main_node() == Node.self()
  end
end
