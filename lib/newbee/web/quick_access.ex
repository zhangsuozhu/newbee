defmodule Newbee.Web.QuickAccess do
  @moduledoc """
  手机免登录扫码打开（DESIGN 外新增，自建"电脑发码、手机直接进"）。

  与 `Newbee.Web.Pair`（手机替电脑盖章）方向相反：**已登录的电脑**点按钮
  生成一个一次性邀请码，手机扫码打开 `/?qk=<code>`，前端调用
  `api.quick_access.redeem` 把码换成正式登录 token，免密码免验证码直接进入。

  安全设计：
  - 码是 128bit 随机、一次性、TTL 10 分钟，Service 端 ETS 持有；
  - 换取的 token 是标准登录 token（12h 滑动 / 7d 绝对）；
  - redeem/create 都走 `Auth.check_rate` 限流，防暴破；
  - 码只在兑换时核对，绝不出现在任何接口响应里（二维码 URL 里的是码本身，
    扫码即用，一次有效）。
  """

  require Logger

  @table :newbee_web_quick_access
  @code_bytes 16
  @ttl_ms 600_000

  # ── 表 ──

  @doc "幂等创建 ETS 表（Application 启动时调用）。"
  def create_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end

  # ── 电脑端 ──

  @doc "生成一个一次性免登录邀请码。"
  def create(meta \\ %{}) do
    code = rand_b64url(@code_bytes)
    now = System.system_time(:millisecond)

    put({:qk, code}, %{
      code: code,
      status: "pending",      # pending → used
      created: now,
      expires: now + @ttl_ms,
      created_by_ip: Map.get(meta, :ip, "")
    })

    {:ok, %{code: code, ttl_ms: ttl_ms()}}
  end

  @doc """
  手机端兑换：用码换正式登录 token。码一次性：兑换即焚，无论成败。

  返回 `{:ok, token}` | `{:error, code, msg}`。
  """
  def redeem(code) when is_binary(code) do
    case get({:qk, code}) do
      nil ->
        {:error, "not_found", "链接已失效，请在电脑上重新生成二维码"}

      rec ->
        # 一次性：先焚码，后面无论成败都不能再兑
        delete({:qk, code})

        cond do
          expired?(rec) ->
            {:error, "expired", "链接已过期，请在电脑上重新生成二维码"}

          rec.status != "pending" ->
            {:error, "used", "该链接已被使用过，请在电脑上重新生成"}

          true ->
            {:ok, token} = Newbee.Web.Auth.issue_token()
            Logger.info("[newbee.web] 手机扫码免登录进入：ip=#{Map.get(rec, :created_by_ip, "")}")
            {:ok, token}
        end
    end
  end

  def redeem(_), do: {:error, "bad_request", "缺少邀请码"}

  # ── 内部 ──

  defp expired?(rec), do: System.system_time(:millisecond) > rec.expires

  defp rand_b64url(n), do: n |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp get(key) do
    create_table()

    case :ets.lookup(@table, key) do
      [{^key, val}] -> val
      [] -> nil
    end
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

  @doc "邀请码存活上限（前端提示用）。"
  def ttl_ms, do: @ttl_ms
end
