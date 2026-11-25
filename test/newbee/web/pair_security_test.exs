defmodule Newbee.Web.PairSecurityTest do
  use ExUnit.Case, async: false
  alias Newbee.Web.{Auth, Pair, Router}

  setup do
    sandbox = Newbee.TestSupport.WebTmpHome.enter("pair_security")
    on_exit(fn -> Newbee.TestSupport.WebTmpHome.restore(sandbox) end)
    Pair.create_table()
    Auth.create_table()
    if :ets.whereis(:newbee_web_pair) != :undefined, do: :ets.delete_all_objects(:newbee_web_pair)
    if :ets.whereis(:newbee_web_auth) != :undefined, do: :ets.delete_all_objects(:newbee_web_auth)
    on_exit(fn -> Router.set_bind_ip({127, 0, 0, 1}) end)
    :ok
  end

  defp scanned_pair do
    {:ok, %{pairing_id: id, code: code}} = Pair.create()
    {:ok, _} = Pair.consume_code(code)
    id
  end

  test "confirmation requires a valid phone login token" do
    id = scanned_pair()
    assert {:error, "unauthorized", _} = Pair.confirm(id)
    assert {:error, "unauthorized", _} = Pair.confirm(id, %{token: "bogus"})
    assert {:ok, %{status: "scanned"}} = Pair.status(id)
  end

  test "authenticated confirmation issues exactly one usable token" do
    id = scanned_pair()
    {:ok, phone_token} = Auth.issue_token()
    assert {:ok, %{approved: true}} = Pair.confirm(id, %{token: phone_token})
    assert {:ok, %{token: token}} = Pair.status(id)
    assert :ok = Auth.check_token(token)
    assert {:error, "not_found", _} = Pair.status(id)
    Auth.revoke_token(token)
  end

  test "concurrent status consumers cannot both receive the token" do
    id = scanned_pair()
    {:ok, phone_token} = Auth.issue_token()
    Pair.confirm(id, %{token: phone_token})

    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn -> send(parent, {:result, Pair.status(id)}) end)
      end

    results =
      for _task <- tasks,
          do:
            (receive do
               {:result, result} -> result
             after
               2000 -> flunk("status stalled")
             end)

    assert Enum.count(results, &match?({:ok, %{token: _}}, &1)) == 1
  end
end
