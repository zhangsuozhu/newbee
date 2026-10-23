defmodule Newbee.LLM.Tls do
  @moduledoc "厂家级 LLM 网关 TLS 信任（model.json 的 providers.<id>.tls）。字段、语义与限制见 docs/model-catalog.md。"

  require Logger

  @known ~w(caFile insecureSkipVerify pinnedSha256)
  @default_ca_key {__MODULE__, :default_ca_certs}

  @typedoc "已解析的厂家 TLS 配置。"
  @type t :: %{
          mode: :ca | :insecure | :pin,
          ca_file: String.t() | nil,
          pin: String.t() | nil,
          transport_opts: keyword(),
          pool_tag: atom(),
          summary: String.t()
        }

  # ── 公开入口 ──

  @doc "规范化 model.json 的 tls 对象（形状校验 + 取值规范化）；nil 或空对象表示不配置。"
  @spec normalize(term()) :: {:ok, map() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(raw) when is_map(raw) do
    if map_size(raw) == 0 do
      {:ok, nil}
    else
      with :ok <- known_keys(raw),
           {:ok, ca_file} <- ca_file(raw["caFile"]),
           {:ok, insecure} <- boolean(raw["insecureSkipVerify"], "insecureSkipVerify"),
           {:ok, pin} <- pin(raw["pinnedSha256"]),
           :ok <- exclusive(ca_file, insecure, pin) do
        {:ok, canonical(ca_file, insecure, pin)}
      end
    end
  end

  def normalize(_), do: {:error, "tls 必须是对象"}

  @doc "规范化并解析出 Req/Finch 可直接使用的传输选项；caFile 不可读时返回错误。"
  @spec resolve(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def resolve(raw) do
    with {:ok, normalized} <- normalize(raw) do
      build(normalized)
    end
  end

  @doc "同 resolve/1，配置非法时抛出可读异常（客户机构建期使用）。"
  @spec resolve!(term()) :: t() | nil
  def resolve!(raw) do
    case resolve(raw) do
      {:ok, tls} -> tls
      {:error, message} -> raise ArgumentError, "model.json tls 配置无效：" <> message
    end
  end

  @doc "人类可读的一句话摘要；未配置返回 nil。"
  @spec summary(t() | nil) :: String.t() | nil
  def summary(nil), do: nil
  def summary(%{summary: summary}), do: summary

  # ── 规范化 ──

  defp known_keys(raw) do
    case Enum.reject(Map.keys(raw), &(&1 in @known)) do
      [] -> :ok
      [key | _] -> {:error, "tls 不支持的字段 " <> inspect(key) <> "（支持：" <> Enum.join(@known, "、") <> "）"}
    end
  end

  defp ca_file(nil), do: {:ok, nil}

  defp ca_file(raw) when is_binary(raw) do
    path = String.trim(raw)

    cond do
      path == "" -> {:ok, nil}
      String.contains?(path, ["\n", "\r", <<0>>]) -> {:error, "tls.caFile 必须是单行文件路径"}
      true -> {:ok, path}
    end
  end

  defp ca_file(_), do: {:error, "tls.caFile 必须是 PEM 证书文件路径"}

  defp boolean(nil, _name), do: {:ok, nil}
  defp boolean(true, _name), do: {:ok, true}
  defp boolean(false, _name), do: {:ok, false}
  defp boolean("true", _name), do: {:ok, true}
  defp boolean("false", _name), do: {:ok, false}
  defp boolean(_, name), do: {:error, "tls." <> name <> " 必须是布尔值"}

  defp pin(nil), do: {:ok, nil}

  defp pin(raw) when is_binary(raw) do
    hex =
      raw
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("sha256:", "")
      |> String.replace(":", "")

    cond do
      hex == "" -> {:ok, nil}
      Regex.match?(~r/^[0-9a-f]{64}$/, hex) -> {:ok, hex}
      true -> {:error, pin_message()}
    end
  end

  defp pin(_), do: {:error, pin_message()}

  defp pin_message, do: "tls.pinnedSha256 必须是证书 SHA-256（64 位十六进制，可带 sha256: 前缀）"

  defp exclusive(ca_file, insecure, pin) do
    if ca_file != nil and (insecure == true or pin != nil) do
      {:error, "tls.caFile 与 insecureSkipVerify / pinnedSha256 互斥：caFile 做链校验，另外两个跳过链校验"}
    else
      :ok
    end
  end

  # 只有「显式 false」这类空配置规范化为 nil，调用方拿到的永远是 nil | 非空对象。
  defp canonical(ca_file, insecure, pin) do
    tls =
      %{}
      |> maybe_put("caFile", ca_file)
      |> maybe_put("insecureSkipVerify", insecure == true)
      |> maybe_put("pinnedSha256", pin)

    if tls == %{}, do: nil, else: tls
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── 解析 ──

  defp build(nil), do: {:ok, nil}

  defp build(%{"caFile" => path}) do
    case ca_ders(path) do
      {:ok, ders} ->
        {:ok, resolved(:ca, [cacerts: ders ++ default_ca_certs()], path, nil, "私有 CA 校验（" <> path <> "）")}

      error ->
        error
    end
  end

  defp build(%{"pinnedSha256" => pin}) do
    {:ok,
     resolved(
       :pin,
       [verify: :verify_none, verify_fun: {pin_verify_fun(pin), nil}],
       nil,
       pin,
       "跳过链校验 + 钉指纹 sha256:" <> pin
     )}
  end

  defp build(%{"insecureSkipVerify" => true}) do
    {:ok, resolved(:insecure, [verify: :verify_none], nil, nil, "跳过证书校验（不安全）")}
  end

  # normalize/1 之后只剩「显式 false」这类空配置。
  defp build(_), do: {:ok, nil}

  defp resolved(mode, transport_opts, ca_file, pin, summary) do
    %{
      mode: mode,
      ca_file: ca_file,
      pin: pin,
      transport_opts: transport_opts,
      pool_tag: pool_tag(mode, ca_file, pin),
      summary: summary
    }
  end

  # Finch 池按 {scheme, host, port, pool_tag} 复用，conn_opts 只在建池时生效。
  # 不同 TLS 配置必须落在不同 tag 上，否则先建池的一方会把校验策略带给另一方。
  defp pool_tag(mode, ca_file, pin) do
    digest =
      :erlang.term_to_binary({mode, ca_file, pin})
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    String.to_atom("newbee_tls_" <> Atom.to_string(mode) <> "_" <> digest)
  end

  defp ca_ders(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, pem} -> ca_ders_from_pem(pem, expanded)
      {:error, reason} -> {:error, "tls.caFile 读取失败（" <> to_string(:file.format_error(reason)) <> "）：" <> expanded}
    end
  end

  defp ca_ders_from_pem(pem, path) do
    ders = for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der

    if ders == [] do
      {:error, "tls.caFile 中没有可用的 PEM 证书：" <> path}
    else
      {:ok, ders}
    end
  rescue
    _ -> {:error, "tls.caFile 解析失败（需要 PEM 证书）：" <> path}
  end

  # Mint 默认用系统信任库（:public_key.cacerts_get/0），失败才回退 castore。
  # 我们显式传 cacerts 时要把这份默认清单并进去，否则配了 caFile 就会顺带丢掉公开 CA。
  defp default_ca_certs do
    case :persistent_term.get(@default_ca_key, nil) do
      nil ->
        certs = os_ca_certs()
        :persistent_term.put(@default_ca_key, certs)
        certs

      certs ->
        certs
    end
  end

  # 本工程不依赖 castore，系统信任库不可用时只保留用户 CA（Mint 自身的回退同样不可用）。
  defp os_ca_certs do
    case :public_key.cacerts_get() do
      certs when is_list(certs) and certs != [] -> certs
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # 钉指纹：以 verify_none 建连，但在接受之前核对证书 SHA-256。
  # critical 扩展照 :ssl 在 verify_none 下的语义放行，非 critical 扩展不表态，
  # 其余事件（:valid_peer / {:bad_cert, _}）只认指纹，不匹配就失败。
  defp pin_verify_fun(pin) do
    fn cert, event, state ->
      case event do
        {:extension, {:Extension, _oid, true, _value}} -> {:valid, state}
        {:extension, _} -> {:unknown, state}
        :valid -> {:valid, state}
        other -> pin_check(cert, other, pin, state)
      end
    end
  end

  defp pin_check(cert, event, pin, state) do
    case cert_der(cert) do
      {:ok, der} ->
        actual = :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

        if actual == pin do
          {:valid, state}
        else
          Logger.warning("[newbee.llm] TLS 指纹不匹配 event=" <> inspect(event) <> " actual=sha256:" <> actual)
          {:fail, {:pin_mismatch, actual}}
        end

      :error ->
        {:fail, :unknown_certificate_encoding}
    end
  end

  defp cert_der({:OTPCertificate, _, _, _} = cert) do
    {:ok, :public_key.pkix_encode(:OTPCertificate, cert, :otp)}
  rescue
    _ -> :error
  end

  defp cert_der(der) when is_binary(der), do: {:ok, der}
  defp cert_der({:cert, der, _}) when is_binary(der), do: {:ok, der}
  defp cert_der(_), do: :error
end
