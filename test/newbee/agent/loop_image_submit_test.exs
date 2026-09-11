defmodule Newbee.Agent.LoopImageSubmitTest do
  use ExUnit.Case, async: false

  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator
  alias Newbee.LLM.Client

  @png_data_url "data:image/png;base64," <> Base.encode64("fake-png-bytes")

  defp struct_client(capabilities) do
    %Client{
      provider: "test",
      model: "fake",
      api_key: "fake",
      base_url: "http://fake",
      api: "openai-completions",
      vision: true,
      capabilities: capabilities,
      context_window: 8000
    }
  end

  defp start_kernel(client, test_pid) do
    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: client,
        evaluator: ev,
        session: false,
        client_fun: fn messages, _on_text, _on_reasoning ->
          send(test_pid, {:request, messages})
          {:ok, %{"role" => "assistant", "content" => "seen", "tool_calls" => []}, %{}}
        end
      )

    {kernel, ev}
  end

  defp stop_kernel({kernel, ev}) do
    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "submit_images 用结构体 client 不崩溃，图片进入请求" do
    client = struct_client(%{vision: true, image_max_bytes: 4096})
    {kernel, ev} = start_kernel(client, self())

    assert {:text, "seen"} = Loop.submit_images(kernel, [@png_data_url], "看看这张图")

    assert_receive {:request, messages}
    user = Enum.find(messages, &(&1["role"] == "user"))
    assert %{"content" => parts} = user
    assert Enum.any?(parts, &match?(%{"type" => "text", "text" => "看看这张图"}, &1))
    assert Enum.any?(parts, &match?(%{"type" => "image_url"}, &1))

    stop_kernel({kernel, ev})
  end

  test "submit_image 走本地文件路径同样不崩溃" do
    client = struct_client(%{vision: true})
    {kernel, ev} = start_kernel(client, self())

    path = Path.join(System.tmp_dir!(), "nb-loop-image-#{System.unique_integer([:positive])}.png")
    File.write!(path, "fake-png-bytes")
    on_exit(fn -> File.rm(path) end)

    assert {:text, "seen"} = Loop.submit_image(kernel, path, "读一下")

    assert_receive {:request, messages}
    user = Enum.find(messages, &(&1["role"] == "user"))
    assert Enum.any?(user["content"], &match?(%{"type" => "image_url"}, &1))

    stop_kernel({kernel, ev})
  end

  test "capabilities.image_max_bytes 经 image_opts 生效" do
    client = struct_client(%{vision: true, image_max_bytes: 16})
    {kernel, ev} = start_kernel(client, self())

    big = "data:image/png;base64," <> Base.encode64(:binary.copy("x", 32))
    assert {:error, {:image, {:image_too_large, 16}}} = Loop.submit_images(kernel, [big], "太大")

    stop_kernel({kernel, ev})
  end
end
