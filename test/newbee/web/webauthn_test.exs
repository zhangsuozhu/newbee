defmodule Newbee.Web.WebAuthnTest do
  use ExUnit.Case, async: false

  alias Newbee.Web.WebAuthn

  setup do
    # HOME 隔离：webauthn.json 写进临时目录，绝不触碰真实 ~/.newbee/web/
    # （历史事故：File.rm 曾删掉用户真实通行密钥）。
    sandbox = Newbee.TestSupport.WebTmpHome.enter("webauthn_test")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)

    # 清空 ETS 与配置文件
    if :ets.whereis(:newbee_web_authn) != :undefined do
      :ets.delete_all_objects(:newbee_web_authn)
    end

    webauthn_path = Path.join(Newbee.Web.Cert.dir(), "webauthn.json")
    File.rm(webauthn_path)

    # 设置测试 origin
    WebAuthn.set_origin("https://test.example.com")

    :ok
  end

  describe "凭据管理" do
    test "初始无凭据" do
      refute WebAuthn.has_credentials?()
      assert WebAuthn.credentials_count() == 0
      assert WebAuthn.list_credentials() == []
    end
  end

  describe "注册挑战" do
    test "生成注册挑战" do
      {:ok, opts} = WebAuthn.registration_challenge("测试设备")

      assert is_binary(opts.challenge_id)
      assert is_binary(opts.challenge)
      assert opts.rp.name == "newbee"
      assert opts.rp.id == "test.example.com"
      assert opts.user.name == "newbee"
      assert length(opts.pub_key_cred_params) == 2
      assert opts.attestation == "none"
    end

    test "挑战存储在 ETS 且可弹出" do
      {:ok, opts} = WebAuthn.registration_challenge("测试设备")
      challenge_id = opts.challenge_id

      # 挑战存在
      assert :ets.lookup(:newbee_web_authn, {:challenge, challenge_id}) != []
    end
  end

  describe "登录挑战" do
    test "无凭据时 allow_credentials 为空" do
      {:ok, opts} = WebAuthn.authentication_challenge()

      assert is_binary(opts.challenge_id)
      assert is_binary(opts.challenge)
      assert opts.rp_id == "test.example.com"
      assert opts.allow_credentials == []
      assert opts.user_verification == "preferred"
    end
  end

  describe "挑战过期" do
    test "过期挑战弹出失败" do
      {:ok, opts} = WebAuthn.registration_challenge("测试设备")
      challenge_id = opts.challenge_id

      # 手动把挑战过期时间改到过去
      [{{:challenge, ^challenge_id}, data}] = :ets.lookup(:newbee_web_authn, {:challenge, challenge_id})
      expired_data = %{data | expires: System.system_time(:millisecond) - 1000}
      :ets.insert(:newbee_web_authn, {{:challenge, challenge_id}, expired_data})

      # 尝试使用过期挑战
      assert {:error, "bad_challenge", _} = WebAuthn.register(challenge_id, "invalid", "invalid", "invalid")
    end
  end

  describe "origin 推导" do
    test "默认 origin 是 localhost" do
      # 清空进程字典
      Process.delete({Newbee.Web.WebAuthn, :origin})

      {:ok, opts} = WebAuthn.registration_challenge()
      assert opts.rp.id == "localhost"
    end

    test "set_origin 生效" do
      WebAuthn.set_origin("https://custom.example.com")
      {:ok, opts} = WebAuthn.registration_challenge()
      assert opts.rp.id == "custom.example.com"
    end
  end
  describe "挑战表跨进程存活（回归：表随请求进程销毁的 bug）" do
    test "短命进程存入的挑战，进程退出后仍可取出" do
      parent = self()

      pid =
        spawn(fn ->
          {:ok, %{challenge_id: cid}} = WebAuthn.registration_challenge("跨进程设备")
          send(parent, {:challenge_id, cid})
        end)

      cid =
        receive do
          {:challenge_id, c} -> c
        after
          2000 -> flunk("未收到 challenge_id")
        end

      # 等进程彻底退出
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
      Process.sleep(20)

      # 表必须还活着
      assert :ets.whereis(:newbee_web_authn) != :undefined

      # pop_challenge 应成功取出（register/authenticate 内部用它）
      assert {:ok, {_challenge, {:register, "跨进程设备"}}} =
               WebAuthn.pop_challenge_for_test(cid)
    end
  end
end
