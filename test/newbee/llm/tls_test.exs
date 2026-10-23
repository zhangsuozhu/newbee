defmodule Newbee.LLM.TlsTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.{Client, Tls}

  # ── 证书夹具：纯 OTP 生成，不依赖 openssl / mkcert ──
  #
  # 自签单证书与「CA 签发的 leaf + CA 链」两种服务端形态都要覆盖：
  # OTP 的 :ssl 只对后者做信任库查询（见 Tls 模块文档）。

  @sha256_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @oid_cn {2, 5, 4, 3}
  @oid_basic_constraints {2, 5, 29, 19}
  @oid_key_usage {2, 5, 29, 15}
  @oid_ext_key_usage {2, 5, 29, 37}
  @oid_san {2, 5, 29, 17}
  @eku_server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}

  setup_all do
    Newbee.Host.Shell.ensure_finch!()
    {:ok, _} = Application.ensure_all_started(:ssl)

    dir = Path.join(System.tmp_dir!(), "newbee-tls-test-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(dir)

    ca_key = gen_key()
    ca_der = cert(ca_key, ~c"newbee-test-ca", ca_key, ca_extensions())
    leaf_key = gen_key()

    leaf_der =
      cert(leaf_key, ~c"localhost", ca_key, [
        ext(
          @oid_basic_constraints,
          true,
          :public_key.der_encode(:BasicConstraints, {:BasicConstraints, false, :asn1_NOVALUE})
        ),
        ext(@oid_key_usage, true, :public_key.der_encode(:KeyUsage, [:digitalSignature, :keyEncipherment])),
        ext(@oid_ext_key_usage, :asn1_DEFAULT, :public_key.der_encode(:ExtKeyUsageSyntax, [@eku_server_auth])),
        ext(
          @oid_san,
          :asn1_DEFAULT,
          :public_key.der_encode(:SubjectAltName, dNSName: ~c"localhost", iPAddress: <<127, 0, 0, 1>>)
        )
      ])

    other_ca_key = gen_key()
    other_ca_der = cert(other_ca_key, ~c"other-ca", other_ca_key, ca_extensions())
    self_key = gen_key()
    self_der = cert(self_key, ~c"localhost", self_key, ca_extensions())

    paths = %{
      ca: Path.join(dir, "ca.pem"),
      other_ca: Path.join(dir, "other-ca.pem"),
      chain: Path.join(dir, "chain.pem"),
      leaf_key: Path.join(dir, "leaf.key"),
      self: Path.join(dir, "self.pem"),
      self_key: Path.join(dir, "self.key")
    }

    File.write!(paths.ca, pem_cert(ca_der))
    File.write!(paths.other_ca, pem_cert(other_ca_der))
    File.write!(paths.chain, pem_cert(leaf_der) <> pem_cert(ca_der))
    File.write!(paths.leaf_key, pem_key(leaf_key))
    File.write!(paths.self, pem_cert(self_der))
    File.write!(paths.self_key, pem_key(self_key))

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok,
     ca_file: paths.ca,
     other_ca_file: paths.other_ca,
     chain_file: paths.chain,
     leaf_key_file: paths.leaf_key,
     self_file: paths.self,
     self_key_file: paths.self_key,
     self_pin: sha256_hex(self_der)}
  end

  # ── normalize/1 ──

  describe "normalize/1" do
    test "nil 与空对象都表示不配置" do
      assert Tls.normalize(nil) == {:ok, nil}
      assert Tls.normalize(%{}) == {:ok, nil}
      assert Tls.normalize(%{"insecureSkipVerify" => false}) == {:ok, nil}
    end

    test "未知字段直接报错（避免拼错字段悄悄失效）" do
      assert {:error, message} = Tls.normalize(%{"caCert" => "/tmp/x.pem"})
      assert message =~ "caCert"
    end

    test "caFile 与跳过校验类的字段互斥" do
      assert {:error, message} = Tls.normalize(%{"caFile" => "/tmp/ca.pem", "insecureSkipVerify" => true})
      assert message =~ "互斥"

      assert {:error, _} = Tls.normalize(%{"caFile" => "/tmp/ca.pem", "pinnedSha256" => sha(0)})
    end

    test "指纹规范化为 64 位小写十六进制" do
      upper = String.duplicate("AB", 32)
      assert {:ok, %{"pinnedSha256" => pin}} = Tls.normalize(%{"pinnedSha256" => "sha256:" <> upper})
      assert pin == String.downcase(upper)

      assert {:ok, %{"pinnedSha256" => _}} = Tls.normalize(%{"pinnedSha256" => String.duplicate("a", 64)})
      assert {:error, _} = Tls.normalize(%{"pinnedSha256" => "abcd"})
      assert {:error, _} = Tls.normalize(%{"pinnedSha256" => 12_345})
    end

    test "caFile 与布尔值做形状校验" do
      assert Tls.normalize(%{"caFile" => "  /tmp/ca.pem  "}) == {:ok, %{"caFile" => "/tmp/ca.pem"}}
      assert {:error, _} = Tls.normalize(%{"caFile" => "/tmp/a\nb.pem"})
      assert {:error, _} = Tls.normalize(%{"caFile" => 42})
      assert {:error, _} = Tls.normalize(%{"insecureSkipVerify" => "yes"})
      assert {:error, _} = Tls.normalize("caFile")
    end

    test "字符串布尔值按旧 endpoint 习惯接受" do
      assert {:ok, %{"insecureSkipVerify" => true}} = Tls.normalize(%{"insecureSkipVerify" => "true"})
      assert {:ok, nil} = Tls.normalize(%{"insecureSkipVerify" => "false"})
    end
  end

  # ── resolve/1 ──

  describe "resolve/1" do
    test "caFile 合并系统信任库，跳过校验类配置不查文件", %{ca_file: ca_file} do
      assert {:ok, %{mode: :ca} = tls} = Tls.resolve(%{"caFile" => ca_file})
      cacerts = tls.transport_opts[:cacerts]
      assert is_list(cacerts) and length(cacerts) >= 1

      assert {:ok, %{mode: :insecure, transport_opts: [verify: :verify_none]}} =
               Tls.resolve(%{"insecureSkipVerify" => true})
    end

    test "caFile 不存在或没有证书时报错" do
      assert {:error, message} = Tls.resolve(%{"caFile" => "/nonexistent/newbee-ca.pem"})
      assert message =~ "读取失败"

      dir = Path.join(System.tmp_dir!(), "newbee-tls-empty-" <> Integer.to_string(System.unique_integer([:positive])))
      File.mkdir_p!(dir)
      empty = Path.join(dir, "empty.pem")
      File.write!(empty, "not a pem")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, message} = Tls.resolve(%{"caFile" => empty})
      assert message =~ "caFile"
    end

    test "resolve!/1 对非法配置抛出可读异常" do
      assert nil == Tls.resolve!(nil)

      assert_raise ArgumentError, ~r/tls 配置无效/, fn ->
        Tls.resolve!(%{"caFile" => "/nonexistent/newbee-ca.pem"})
      end
    end

    test "三种模式各自生成互不相同的 pool_tag（Finch 池按 tag 隔离）", %{ca_file: ca_file} do
      {:ok, ca} = Tls.resolve(%{"caFile" => ca_file})
      {:ok, insecure} = Tls.resolve(%{"insecureSkipVerify" => true})
      {:ok, pin} = Tls.resolve(%{"pinnedSha256" => sha(1)})

      tags = Enum.map([ca, insecure, pin], & &1.pool_tag)
      assert Enum.uniq(tags) == tags

      # 同一份配置必须稳定（热重载后仍复用同一个池）
      assert {:ok, %{pool_tag: tag}} = Tls.resolve(%{"caFile" => ca_file})
      assert tag == ca.pool_tag
      assert insecure.transport_opts == [verify: :verify_none]
      assert Keyword.has_key?(pin.transport_opts, :verify_fun)
      assert Tls.summary(nil) == nil
      assert Tls.summary(insecure) =~ "跳过"
    end
  end

  # ── 端到端：真实 TLS 服务 + Client ──

  describe "真实网关握手" do
    test "默认严格校验拒绝自签网关", %{self_file: certfile, self_key_file: keyfile} do
      port = start_tls_server(certfile, keyfile)

      assert {:error, %Req.TransportError{reason: {:tls_alert, {:bad_certificate, message}}}} =
               Client.complete(client(port, nil), messages())

      assert to_string(message) =~ "selfsigned_peer"
    end

    test "insecureSkipVerify 接受自签网关", %{self_file: certfile, self_key_file: keyfile} do
      port = start_tls_server(certfile, keyfile)
      assert {:ok, "pong", _usage} = Client.complete(client(port, %{"insecureSkipVerify" => true}), messages())
    end

    test "pinnedSha256 匹配放行、不匹配拒绝并回报实际指纹", %{
      self_file: certfile,
      self_key_file: keyfile,
      self_pin: pin
    } do
      port = start_tls_server(certfile, keyfile)

      assert {:ok, "pong", _usage} =
               Client.complete(client(port, %{"pinnedSha256" => "sha256:" <> pin}), messages())

      port = start_tls_server(certfile, keyfile)

      assert {:error, %Req.TransportError{reason: {:tls_alert, {_alert, message}}}} =
               Client.complete(client(port, %{"pinnedSha256" => sha(0)}), messages())

      assert to_string(message) =~ pin
    end

    test "caFile 接受该 CA 签发的链，拒绝其他 CA", %{
      chain_file: chain_file,
      leaf_key_file: leaf_key_file,
      ca_file: ca_file,
      other_ca_file: other_ca_file
    } do
      port = start_tls_server(chain_file, leaf_key_file)
      assert {:ok, "pong", _usage} = Client.complete(client(port, %{"caFile" => ca_file}), messages())

      port = start_tls_server(chain_file, leaf_key_file)

      assert {:error, %Req.TransportError{reason: {:tls_alert, {:unknown_ca, _}}}} =
               Client.complete(client(port, %{"caFile" => other_ca_file}), messages())
    end
  end

  # ── Client 组装 ──

  describe "Client 传输组装" do
    test "未配置 TLS 时沿用默认 Finch 配置且不带 pool_tag" do
      client = Client.new(base_url: "https://example.test/v1")
      opts = Client.req_transport(client)

      refute Keyword.has_key?(opts, :pool_tag)
      assert opts[:conn_opts][:transport_opts] == [timeout: 30_000]
      assert Client.tls_finch_opt(client) == []
    end

    test "配置 TLS 的厂家拿到自己的 pool_tag 与传输选项", %{ca_file: ca_file} do
      {:ok, tls} = Tls.resolve(%{"caFile" => ca_file})
      client = Client.new(base_url: "https://example.test/v1", tls: tls)
      opts = Client.req_transport(client)

      assert opts[:pool_tag] == tls.pool_tag
      assert [finch: ^opts] = Client.tls_finch_opt(client)
      assert opts[:conn_opts][:transport_opts][:cacerts] |> is_list()
    end

    test "req_options 把 connect_options 折进 finch，并保留连接超时" do
      client =
        Client.new(
          base_url: "https://example.test/v1",
          req_options: [connect_options: [transport_opts: [verify: :verify_none]]]
        )

      opts = Client.req_options(client, url: "https://example.test/v1/chat/completions")

      refute Keyword.has_key?(opts, :connect_options)
      transport = opts[:finch][:conn_opts][:transport_opts]
      assert transport[:verify] == :verify_none
      assert transport[:timeout] == 30_000
    end

    test "format_error 对 TLS 失败给出配置指引，不再声称自动重试" do
      text =
        Client.format_error(%Req.TransportError{
          reason: {:tls_alert, {:bad_certificate, ~c"TLS client: ... selfsigned_peer"}}
        })

      assert text =~ "证书校验失败"
      assert text =~ "caFile"
      assert text =~ "pinnedSha256"
      refute text =~ "自动重试"

      pin_text =
        Client.format_error(%Req.TransportError{
          reason: {:tls_alert, {:handshake_failure, ~c"... {pin_mismatch,<<\"#{String.duplicate("a", 64)}\">>}"}}
        })

      assert pin_text =~ "指纹"
      assert pin_text =~ String.duplicate("a", 64)
    end
  end

  # ── 夹具构造 ──

  defp messages, do: [%{"role" => "user", "content" => "ping"}]

  defp sha(n), do: String.duplicate(Integer.to_string(n), 64)

  # TLS echo 服务：任何请求都返回 OpenAI 兼容的 chat completion。
  defp start_tls_server(certfile, keyfile) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lsock} =
          :ssl.listen(0, [
            :binary,
            packet: :raw,
            active: false,
            reuseaddr: true,
            certfile: String.to_charlist(certfile),
            keyfile: String.to_charlist(keyfile)
          ])

        {:ok, {_, port}} = :ssl.sockname(lsock)
        send(parent, {:tls_port, port})
        accept_loop(lsock)
      end)

    port =
      receive do
        {:tls_port, p} -> p
      after
        5_000 -> flunk("TLS 服务没有起来")
      end

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept_loop(lsock) do
    case :ssl.transport_accept(lsock, 30_000) do
      {:ok, sock} ->
        case :ssl.handshake(sock, 5_000) do
          {:ok, conn} ->
            _ = :ssl.recv(conn, 0, 3_000)
            body = ~s({"choices":[{"message":{"content":"pong"}}],"usage":{}})

            _ =
              :ssl.send(conn, [
                "HTTP/1.1 200 OK\r\n",
                "content-type: application/json\r\n",
                "content-length: ",
                Integer.to_string(byte_size(body)),
                "\r\nconnection: close\r\n\r\n",
                body
              ])

            :ssl.close(conn)

          _ ->
            :ok
        end

        accept_loop(lsock)

      _ ->
        accept_loop(lsock)
    end
  end

  defp client(port, tls_raw) do
    {:ok, tls} = Tls.resolve(tls_raw)
    Client.new(base_url: "https://localhost:" <> Integer.to_string(port), api_key: "test", tls: tls)
  end

  # ── X.509 构造 ──

  defp gen_key, do: :public_key.generate_key({:rsa, 2048, 65_537})

  defp ca_extensions do
    [
      ext(
        @oid_basic_constraints,
        true,
        :public_key.der_encode(:BasicConstraints, {:BasicConstraints, true, :asn1_NOVALUE})
      ),
      ext(@oid_key_usage, true, :public_key.der_encode(:KeyUsage, [:keyCertSign, :cRLSign, :digitalSignature]))
    ]
  end

  defp cert(subject_key, subject_cn, signer_key, extensions) do
    {:RSAPrivateKey, _, mod, pub_exp, _, _, _, _, _, _, _} = subject_key

    sig_alg = {:AlgorithmIdentifier, @sha256_rsa, {:asn1_OPENTYPE, <<5, 0>>}}
    key_alg = {:AlgorithmIdentifier, @rsa_encryption, {:asn1_OPENTYPE, <<5, 0>>}}
    subject = rdn(subject_cn)
    issuer = if signer_key == subject_key, do: subject, else: rdn(~c"newbee-test-ca")
    now = DateTime.utc_now() |> DateTime.to_unix()
    spki = {:SubjectPublicKeyInfo, key_alg, :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, mod, pub_exp})}

    tbs =
      {:TBSCertificate, :v3, :rand.uniform(0xFFFFFFFFFF), sig_alg, issuer, {:Validity, utc(now - 60), utc(now + 3_600)},
       subject, spki, :asn1_NOVALUE, :asn1_NOVALUE, extensions}

    der = :public_key.der_encode(:TBSCertificate, tbs)
    :public_key.der_encode(:OTPCertificate, {:OTPCertificate, tbs, sig_alg, :public_key.sign(der, :sha256, signer_key)})
  end

  defp rdn(cn), do: {:rdnSequence, [[{:AttributeTypeAndValue, @oid_cn, {:utf8String, cn}}]]}
  defp ext(oid, critical, der), do: {:Extension, oid, critical, der}

  defp utc(ts),
    do: {:utcTime, ts |> DateTime.from_unix!() |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp pem_cert(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  defp pem_key(key),
    do: :public_key.pem_encode([{:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key), :not_encrypted}])

  defp sha256_hex(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
end
