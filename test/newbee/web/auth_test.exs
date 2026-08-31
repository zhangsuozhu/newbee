defmodule Newbee.Web.AuthTest do
  use ExUnit.Case, async: false

  alias Newbee.Web.Auth

  setup do
    # HOME 隔离：auth.json/sessions.json 写进临时目录，绝不触碰真实 ~/.newbee/web/
    # （历史事故：本测试曾把用户真实密码覆盖为测试值）。限流/锁定按独立 IP 隔离。
    sandbox = Newbee.TestSupport.WebTmpHome.enter("auth_test")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)

    Auth.password_set?()

    if :ets.whereis(:newbee_web_auth) != :undefined do
      :ets.delete_all_objects(:newbee_web_auth)
    end

    :ok
  end

  describe "回环门 auth_required?/1" do
    test "回环地址免认证" do
      refute Auth.auth_required?({127, 0, 0, 1})
      refute Auth.auth_required?({127, 0, 0, 5})
      refute Auth.auth_required?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "非回环地址强制认证" do
      assert Auth.auth_required?({0, 0, 0, 0})
      assert Auth.auth_required?({192, 168, 1, 5})
      assert Auth.auth_required?("0.0.0.0")
    end

    test "主机名解析失败按远程（安全默认）" do
      assert Auth.auth_required?("not.an.ip.at.all.")
    end
  end

  describe "密码" do
    test "设置 + 校验" do
      :ok = Auth.set_password("secret123")
      assert Auth.password_set?()
      assert Auth.verify_password("secret123")
      refute Auth.verify_password("wrong")
    end

    test "弱密码拒绝" do
      assert {:error, _} = Auth.set_password("123")
    end
  end

  describe "token" do
    test "签发 + 校验 + 注销" do
      {:ok, tok} = Auth.issue_token()
      assert :ok = Auth.check_token(tok)
      assert {:error, :invalid} = Auth.check_token("bogus")
      Auth.revoke_token(tok)
      assert {:error, :invalid} = Auth.check_token(tok)
    end
  end

  test "token 签发不等待 sessions.json 落盘" do
    writer = Process.whereis(Newbee.Web.Auth.SessionWriter)
    assert is_pid(writer)
    :ok = :sys.suspend(writer)

    on_exit(fn ->
      if Process.alive?(writer), do: :sys.resume(writer)
    end)

    assert {:ok, token} = Auth.issue_token()
    assert Auth.check_token(token) == :ok
    assert {:message_queue_len, queued} = Process.info(writer, :message_queue_len)
    assert queued >= 1
    :ok = :sys.resume(writer)
  end

  describe "图形验证码" do
    test "生成 SVG + 一次性校验" do
      cap = Auth.gen_captcha()
      assert String.starts_with?(cap.svg, "<svg")
      assert cap.id != ""
      assert Auth.verify_captcha(cap.id, cap.text)
    end

    test "错验证码失败且一次性作废" do
      cap = Auth.gen_captcha()
      refute Auth.verify_captcha(cap.id, "xxxx")
      refute Auth.verify_captcha(cap.id, cap.text)
    end

    test "大小写不敏感" do
      cap = Auth.gen_captcha()
      assert Auth.verify_captcha(cap.id, String.upcase(cap.text))
    end
  end

  describe "登录（带验证码）" do
    setup do
      :ok = Auth.set_password("hunter22")
      :ok
    end

    test "正确密码 + 正确验证码 → token" do
      cap = Auth.gen_captcha()

      assert {:ok, token} =
               Auth.login(%{"password" => "hunter22", "captchaId" => cap.id, "captcha" => cap.text}, {10, 0, 0, 1})

      assert is_binary(token)
    end

    test "密码错误 → bad_password" do
      cap = Auth.gen_captcha()

      assert {:error, "bad_password", _} =
               Auth.login(%{"password" => "nope", "captchaId" => cap.id, "captcha" => cap.text}, {10, 0, 0, 2})
    end

    test "验证码错误 → bad_captcha" do
      assert {:error, "bad_captcha", _} =
               Auth.login(%{"password" => "hunter22", "captchaId" => "bogus", "captcha" => "x"}, {10, 0, 0, 3})
    end

    test "连续失败触发锁定（防暴破）" do
      ip = {10, 9, 9, 9}

      codes =
        for _ <- 1..6 do
          cap = Auth.gen_captcha()
          Auth.login(%{"password" => "x", "captchaId" => cap.id, "captcha" => cap.text}, ip)
        end

      assert Enum.at(codes, 4) |> elem(1) == "locked"
      assert Enum.at(codes, 5) |> elem(1) == "locked"
      cap = Auth.gen_captcha()

      assert {:error, "locked", _} =
               Auth.login(%{"password" => "hunter22", "captchaId" => cap.id, "captcha" => cap.text}, ip)
    end
  end

  describe "认证表跨进程存活（回归：表随请求进程销毁导致 token 丢失）" do
    test "短命进程签发的 token，进程退出后仍可校验" do
      parent = self()

      pid =
        spawn(fn ->
          {:ok, tok} = Auth.issue_token()
          send(parent, {:tok, tok})
        end)

      tok =
        receive do
          {:tok, t} -> t
        after
          2000 -> flunk("未收到 token")
        end

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000
      Process.sleep(20)

      # 表必须仍存在且 token 可校验
      assert :ets.whereis(:newbee_web_auth) != :undefined
      assert Auth.check_token(tok) == :ok
    end
  end
end
