defmodule Newbee.CommandsMoreTest do
  use ExUnit.Case, async: false
  alias Newbee.Commands

  setup do
    old = Newbee.Permissions.get()
    on_exit(fn -> Newbee.Permissions.set(old) end)
    :ok
  end

  defp say_collector do
    parent = self()
    {fn line -> send(parent, {:said, line}) end, parent}
  end

  defp said(parent), do: parent

  test "/permissions 显示档位" do
    {say, _parent} = say_collector()
    assert :handled = Commands.handle("/permissions", %{say: say})
    assert_received {:said, msg}
    assert msg =~ "权限档位"
  end

  test "/permissions ask 设置档位" do
    {say, _parent} = say_collector()
    assert :handled = Commands.handle("/permissions ask", %{say: say})
    assert_received {:said, msg}
    assert msg =~ "ask"
    assert Newbee.Permissions.get() == :ask
  end

  test "/compact 无 kernel 提示" do
    {say, _parent} = say_collector()
    assert :handled = Commands.handle("/compact", %{say: say, kernel: nil})
    assert_received {:said, msg}
    assert msg =~ "无 kernel"
  end

  test "/model 无参显示用法" do
    {say, _parent} = say_collector()
    assert :handled = Commands.handle("/model", %{say: say})

    # describe 输出多行，收集后断言含用法提示
    msgs =
      for _ <- 1..9 do
        receive do
          {:said, m} -> m
        after
          500 -> ""
        end
      end

    assert Enum.any?(msgs, &(&1 =~ "用法" or &1 =~ "model" or String.contains?(&1, "autonomy")))
  end

  test "/model 非法 id 不写配置（未知 provider 前缀被拒）" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee-cmdtest-#{System.system_time(:native)}_#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      tmp,
      Jason.encode!(%{
        "providers" => %{},
        "roles" => %{"default" => %{"provider" => "opencode", "model" => "ox-alpha-free"}}
      })
    )

    System.put_env("NEWBEE_MODEL_JSON", tmp)

    on_exit(fn ->
      System.delete_env("NEWBEE_MODEL_JSON")
      File.rm(tmp)
    end)

    {say, _parent} = say_collector()
    assert :handled = Commands.handle("/model nosuchprovider/m1", %{say: say})
    assert_received {:said, msg}
    assert msg =~ "切换失败"
  end

  test "/tools 列出插件库（含 active 状态与价签）" do
    {say, _parent} = say_collector()
    assert :handled = Commands.handle("/tools", %{say: say})
    assert_received {:said, msg}
    assert msg =~ "插件库"
  end

  test "/init 在临时目录生成 NEWBEE.md" do
    tmp =
      Path.join(System.tmp_dir!(), "newbee_init_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    File.cd!(tmp, fn ->
      {say, _parent} = say_collector()
      assert :handled = Commands.handle("/init", %{say: say})
      assert_received {:said, msg}
      assert msg =~ "NEWBEE.md"
      assert File.exists?("NEWBEE.md")
      assert File.read!("NEWBEE.md") =~ "常用命令"
      # 二次调用跳过
      assert :handled = Commands.handle("/init", %{say: say})
      assert_received {:said, msg2}
      assert msg2 =~ "已存在"
      File.rm("NEWBEE.md")
    end)

    File.rmdir(tmp)
  end
end
