defmodule Newbee.EventLogTest do
  use ExUnit.Case, async: true

  alias Newbee.EventLog

  # 回归：Agent.Loop 会把 client 的裸错误项 emit 成 {:error, e}，其中
  # `%Req.TransportError{}` 是结构体（map 但不是 Enumerable）。EventLog 以前用
  # Map.new/2 展平 map，遇到结构体直接抛 Protocol.UndefinedError 把自己打挂。
  test "结构体错误项（Req.TransportError）可编码" do
    encoded =
      %Req.TransportError{reason: {:tls_alert, :bad_certificate}}
      |> EventLog.jsonable()
      |> Jason.encode!()

    assert encoded =~ "Req.TransportError"
    assert encoded =~ "tls_alert"
    assert encoded =~ "bad_certificate"
  end

  test "元组与嵌套 map 仍按原约定编码（原子由 Jason 转字符串）" do
    assert EventLog.jsonable({:goal_start, "目标"}) == [:goal_start, "目标"]
    assert EventLog.jsonable({:audit, :ok, %{actor: "a"}}) == [:audit, :ok, %{actor: "a"}]
  end
end
