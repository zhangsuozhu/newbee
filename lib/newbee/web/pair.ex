defmodule Newbee.Web.Pair do
  @moduledoc """
  扫码授权登录（DESIGN 外新增，自建"手机扫码替电脑盖章"）。

  核心思路：一台没指纹的电脑要登录时，出示一个二维码；已登录的手机扫码后
  点"允许"，服务端就给这台电脑发一把登录令牌（复用 `Newbee.Web.Auth` 的 token）。

  ## 安全设计

  - **配对码烘焙进手机授权链接，不上二维码、不经 RPC 回传。** 二维码里只有
    服务器基址。手机扫码打开 `GET /pair?c=<code>`，服务端渲染授权页时才从
    ETS 取码核对。配对码是 128bit 随机、一次性、TTL 90s，永不出现在任何
    可被轮询/抓包读到的接口响应里——攻击者拿不到码，就无法伪造授权。
  - **手机必须在已登录会话里授权**：授权页 JS 校验 `state.token`（本机已有
    登录）且 `host.describe.auth_required == true`，否则拒绝。这把"已登录
    手机"当成 root of trust。
  - **限流防暴破**：status / phone_status / confirm 走 `Auth.check_rate` +
    `record_fail`（复用登录的指数退避锁定）。
  - **来源展示**：授权页显示电脑端浏览器/IP/发起时间，防"远程钓鱼码"。
  - 配对码消费即焚：手机一旦读到配对页（GET /pair），该码即从 ETS 删除，
    不能再被第二台设备用。

  ## 状态机

      pending → scanned → approved → done
          ↓         ↓         ↓
        expired   expired   expired / denied

  ## 存储

  纯 ETS（`:newbee_web_pair`），与 `Newbee.Web.Auth` 同风格。表由
  `create_table/0` 幂等创建（Router 启动时调）。
  """

  require Logger

  @table :newbee_web_pair
  @code_bytes 16
  @ttl_ms 90_000
  @poll_max_ms 60_000

  # ── 表 ──

  @doc "幂等创建配对 ETS 表（Router 启动时调用）。"
  def create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])

      _ ->
        @table
    end
  end

  # ── 电脑端 ──

  @doc "生成一个 pending 配对。返回 pairing_id（电脑轮询用，非配对码）。"
  def create(meta \\ %{}) do
    pairing_id = rand_b64url(@code_bytes)
    code = rand_b64url(@code_bytes)
    now = System.system_time(:millisecond)

    put({:pair, pairing_id}, %{
      pairing_id: pairing_id,
      code: code,
      status: "pending",
      token: nil,
      created: now,
      expires: now + @ttl_ms,
      # 电脑端来源信息（供手机授权页展示，防钓鱼）
      ua: Map.get(meta, :ua, ""),
      ip: Map.get(meta, :ip, ""),
      scanned_by: nil
    })

    {:ok, %{pairing_id: pairing_id, code: code}}
  end

  @doc """
  电脑端轮询。返回配对当前状态。

  安全：`pending`/`scanned` 态**不**回配对码，也永不回 token；只有
  `approved` 态才回一次性 token（且读到即清，防二次取走）。
  """
  def status(pairing_id) do
    case get_pair(pairing_id) do
      nil ->
        {:error, "not_found", "配对不存在或已过期，请刷新二维码"}

      p ->
        cond do
          expired?(p) ->
            delete({:pair, pairing_id})
            {:ok, %{status: "expired"}}

          p.status == "approved" ->
            # token 一次性：读出即焚
            token = p.token
            delete({:pair, pairing_id})
            {:ok, %{status: "approved", token: token}}

          p.status == "denied" ->
            delete({:pair, pairing_id})
            {:ok, %{status: "denied"}}

          true ->
            {:ok, %{status: p.status}}
        end
    end
  end

  # ── 手机端 ──

  @doc """
  手机扫码打开配对页时核对配对码。配对码匹配且未过期 → 返回展示数据并
  把状态推进到 `scanned`；同时**立即消费配对码**（一次性）。

  返回 `{:ok, pair}` | `{:error, code, msg}`。
  """
  def consume_code(code) when is_binary(code) do
    case find_by_code(code) do
      nil ->
        {:error, "not_found", "二维码已过期或无效，请让电脑刷新后重新扫码"}

      p ->
        cond do
          expired?(p) ->
            delete({:pair, p.pairing_id})
            {:error, "expired", "二维码已过期，请让电脑刷新后重新扫码"}

          p.status != "pending" ->
            {:error, "used", "该二维码已被使用"}

          true ->
            now = System.system_time(:millisecond)
            scanned = %{p | status: "scanned", code: nil}
            put({:pair, p.pairing_id}, scanned)

            {:ok,
             %{
               pairing_id: p.pairing_id,
               ua: p.ua,
               ip: p.ip,
               created: p.created,
               remaining_ms: max(p.expires - now, 0)
             }}
        end
    end
  end

  def consume_code(_), do: {:error, "bad_request", "缺少配对码"}

  @doc "手机端进入授权页后，按 pairing_id 复核配对是否仍有效（供 confirm 前置校验）。"
  def phone_status(pairing_id) do
    case get_pair(pairing_id) do
      nil -> {:error, "not_found", "配对不存在或已过期"}
      p ->
        if expired?(p) do
          delete({:pair, pairing_id})
          {:error, "expired", "二维码已过期"}
        else
          {:ok, %{status: p.status, ua: p.ua, ip: p.ip, created: p.created}}
        end
    end
  end

  @doc """
  手机端点"允许"：为这台电脑签发登录令牌。

  仅当配对处于 `scanned`（手机已核对过码）且未过期时才签发。令牌由
  `Auth.issue_token/0` 生成，写入配对后状态置 `approved`，等电脑轮询取走。
  """
  def confirm(pairing_id, phone_meta \\ %{}) do
    case get_pair(pairing_id) do
      nil ->
        {:error, "not_found", "配对不存在或已过期，请重新扫码"}

      p ->
        cond do
          expired?(p) ->
            delete({:pair, pairing_id})
            {:error, "expired", "二维码已过期，请重新扫码"}

          p.status != "scanned" ->
            {:error, "bad_state", "配对状态异常，请重新扫码"}

          true ->
            {:ok, token} = Newbee.Web.Auth.issue_token()

            put({:pair, pairing_id}, %{
              p
              | status: "approved",
                token: token,
                scanned_by: Map.get(phone_meta, :ua, "")
            })

            Logger.info("[newbee.web] 扫码授权成功：ip=#{p.ip} ua=#{p.ua}")
            {:ok, %{approved: true}}
        end
    end
  end

  @doc "手机端点\"拒绝\"：标记 denied，电脑端轮询到后提示并换新码。"
  def deny(pairing_id) do
    case get_pair(pairing_id) do
      nil ->
        {:error, "not_found", "配对不存在"}

      p ->
        put({:pair, pairing_id}, %{p | status: "denied", token: nil, code: nil})
        {:ok, %{denied: true}}
    end
  end

  # ── 内部 ──

  defp find_by_code(code) do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn
      {{:pair, _pid}, %{code: c} = p} when c == code and is_binary(c) -> p
      _ -> nil
    end)
  end

  defp get_pair(pairing_id) do
    create_table()

    case :ets.lookup(@table, {:pair, pairing_id}) do
      [{{:pair, _}, p}] -> p
      _ -> nil
    end
  end

  defp expired?(p), do: System.system_time(:millisecond) > p.expires

  defp rand_b64url(n) do
    n |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp put(key, val) do
    create_table()
    :ets.insert(@table, {key, val})
    val
  end

  defp delete(key) do
    create_table()
    :ets.delete(@table, key)
    :ok
  end

  @doc "配对存活上限（供前端设定轮询超时）。"
  def ttl_ms, do: @ttl_ms

  @doc "电脑端轮询建议上限。"
  def poll_max_ms, do: @poll_max_ms
end
