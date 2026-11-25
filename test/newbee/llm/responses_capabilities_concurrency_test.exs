defmodule Newbee.LLM.ResponsesCapabilitiesConcurrencyTest do
  use ExUnit.Case, async: false

  test "concurrent updates do not lose capabilities" do
    root = Path.join(System.tmp_dir!(), "newbee-caps-" <> Integer.to_string(System.unique_integer([:positive])))
    previous = System.get_env("NEWBEE_HOME")
    System.put_env("NEWBEE_HOME", root)

    on_exit(fn ->
      if previous, do: System.put_env("NEWBEE_HOME", previous), else: System.delete_env("NEWBEE_HOME")
      File.rm_rf!(root)
    end)

    1..20
    |> Task.async_stream(fn i -> Newbee.LLM.ResponsesCapabilities.put({"route", "model"}, :stream, rem(i, 2) == 0) end,
      max_concurrency: 8
    )

    1..20
    |> Task.async_stream(fn i -> Newbee.LLM.ResponsesCapabilities.put({"route", "model"}, :stream, rem(i, 2) == 0) end,
      max_concurrency: 8,
      timeout: 30_000
    )
    |> Enum.to_list()

    caps = Newbee.LLM.ResponsesCapabilities.load({"route", "model"})
    assert is_boolean(caps.stream)
    assert File.regular?(Newbee.LLM.ResponsesCapabilities.path())
  end
end
