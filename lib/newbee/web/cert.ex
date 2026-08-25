defmodule Newbee.Web.Cert do
  @moduledoc """
  WebUI HTTPS 自签证书（RSA 2048，OTP 原生 :public_key，零依赖）。

  证书/私钥存 `~/.newbee/web/{cert,key}.pem`，首启自动生成（私钥 chmod 600）。
  用 RSA 而非 ed25519：OpenSSL/浏览器/反代全版本兼容，无需额外的
  signature_algs 协商。编码照搬 OTP `erl_make_certs` 的成熟路径：
  AlgorithmIdentifier NULL 参数用原子 'NULL'，签名 OID = sha256WithRSAEncryption。

  远程暴露时配合 `--https`（或反代终止 TLS）使用。
  """

  require Logger

  @rsa_encryption {1, 2, 840, 113549, 1, 1, 1}
  @sha256_with_rsa {1, 2, 840, 113549, 1, 1, 11}
  @ext_basic_constraints {2, 5, 29, 19}
  @ext_key_usage {2, 5, 29, 15}
  @ext_ext_key_usage {2, 5, 29, 37}
  @ext_san {2, 5, 29, 17}
  @eku_server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @cn_oid {2, 5, 4, 3}
  @validity_days 3650
  @rsa_bits 2048
  @rsa_exp 65537

  def dir, do: Path.join(Newbee.GlobalStore.root(), "web")
  def cert_path, do: Path.join(dir(), "cert.pem")
  def key_path, do: Path.join(dir(), "key.pem")

  @doc "确保证书存在；返回 {:ok, %{cert: path, key_der: der}}（key_der 供内存喂 :ssl）。"
  def ensure do
    if File.regular?(cert_path()) and File.regular?(key_path()) do
      load()
    else
      generate_and_write()
    end
  end

  @doc "读入已有证书路径 + 私钥 DER。"
  def load do
    with {:ok, pem} <- File.read(key_path()),
         {:ok, der} <- decode_rsa_key(pem),
         true <- File.regular?(cert_path()) do
      {:ok, %{cert: cert_path(), key_der: der}}
    else
      {:error, r} -> {:error, r}
      false -> {:error, :cert_missing}
    end
  end

  defp decode_rsa_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:RSAPrivateKey, der, :not_encrypted} | _] -> {:ok, der}
      _ -> {:error, :no_rsa_key_in_pem}
    end
  rescue
    _ -> {:error, :bad_key_pem}
  end

  defp generate_and_write do
    try do
      key = :public_key.generate_key({:rsa, @rsa_bits, @rsa_exp})
      cert_der = build_self_signed(key)
      key_der = :public_key.der_encode(:RSAPrivateKey, key)

      File.mkdir_p!(dir())
      File.write!(cert_path(), :public_key.pem_encode([{:Certificate, cert_der, :not_encrypted}]))
      File.write!(key_path(), :public_key.pem_encode([{:RSAPrivateKey, key_der, :not_encrypted}]))
      File.chmod(key_path(), 0o600)
      File.chmod(cert_path(), 0o644)
      Logger.info("[newbee.web] 生成自签 HTTPS 证书: #{cert_path()}")
      {:ok, %{cert: cert_path(), key_der: key_der}}
    rescue
      e -> {:error, {:cert_gen_failed, Exception.message(e)}}
    end
  end

  # 自签 v3 RSA 证书
  defp build_self_signed(key) do
    {:RSAPrivateKey, :"two-prime", mod, pub_exp, _priv, _p, _q, _e1, _e2, _c, _oth} = key
    pub = {:RSAPublicKey, mod, pub_exp}

    sig_alg = {:AlgorithmIdentifier, @sha256_with_rsa, {:asn1_OPENTYPE, <<5, 0>>}}
    key_alg = {:AlgorithmIdentifier, @rsa_encryption, {:asn1_OPENTYPE, <<5, 0>>}}
    name = {:rdnSequence, [[{:AttributeTypeAndValue, @cn_oid, {:utf8String, ~c"newbee.local"}}]]}
    now = DateTime.utc_now() |> DateTime.to_unix()

    spki = {:SubjectPublicKeyInfo, key_alg, :public_key.der_encode(:RSAPublicKey, pub)}

    extensions = [
      ext(@ext_basic_constraints, true, :public_key.der_encode(:BasicConstraints, {:BasicConstraints, false, :asn1_NOVALUE})),
      ext(@ext_key_usage, true, :public_key.der_encode(:KeyUsage, [:digitalSignature, :keyEncipherment])),
      ext(@ext_ext_key_usage, :asn1_DEFAULT, :public_key.der_encode(:ExtKeyUsageSyntax, [@eku_server_auth])),
      ext(@ext_san, :asn1_DEFAULT, :public_key.der_encode(:SubjectAltName, [dNSName: "newbee.local", dNSName: "localhost", iPAddress: <<127, 0, 0, 1>>]))
    ]

    tbs =
      {:TBSCertificate, :v3, :rand.uniform(0xFFFFFFFFFFFF), sig_alg, name,
       {:Validity, utc(now - 60), utc(now + @validity_days * 86400)}, name, spki,
       :asn1_NOVALUE, :asn1_NOVALUE, extensions}

    tbs_der = :public_key.der_encode(:TBSCertificate, tbs)
    sig = :public_key.sign(tbs_der, :sha256, key)
    :public_key.der_encode(:OTPCertificate, {:OTPCertificate, tbs, sig_alg, sig})
  end

  defp ext(oid, critical, der), do: {:Extension, oid, critical, der}
  defp utc(ts), do: {:utcTime, ts |> DateTime.from_unix!() |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}

end
