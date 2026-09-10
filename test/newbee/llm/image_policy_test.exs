defmodule Newbee.LLM.ImagePolicyTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.ImagePolicy

  defp data_url(payload), do: "data:image/png;base64," <> Base.encode64(payload)

  defp image_part(url), do: %{"type" => "image_url", "image_url" => %{"url" => url}}

  defp user_with_images(urls, text \\ "看这些图") do
    %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => text} | Enum.map(urls, &image_part/1)]
    }
  end

  defp parts(message), do: message["content"]

  defp texts(message) do
    for(%{"type" => "text", "text" => text} <- parts(message), do: text)
  end

  defp images(message) do
    for(%{"type" => "image_url"} = part <- parts(message), do: part)
  end

  defp omissions(message) do
    message |> texts() |> Enum.filter(&String.starts_with?(&1, "[image omitted:"))
  end

  test "预算内不动消息" do
    message =
      user_with_images([data_url(:binary.copy("a", 16)), data_url(:binary.copy("b", 16))])

    assert {messages, 0} = ImagePolicy.project([message], %ImagePolicy{})
    assert messages == [message]
  end

  test "超出张数上限：最老优先卸载，最新的按原顺序保留" do
    urls = for c <- ["a", "b", "c"], do: data_url(String.duplicate(c, 16))
    message = user_with_images(urls)

    {[projected], 1} = ImagePolicy.project([message], %ImagePolicy{max_images: 2})

    assert images(projected) == Enum.map(tl(urls), &image_part/1)
    assert omissions(projected) == [ImagePolicy.placeholder(hd(urls))]
  end

  test "超出总字节预算：从最老开始停，保留最新的一段" do
    big = data_url(:binary.copy("x", 40))
    small = data_url(:binary.copy("y", 8))
    message = user_with_images([big, small])

    {[projected], 1} = ImagePolicy.project([message], %ImagePolicy{max_request_bytes: 12})

    assert images(projected) == [image_part(small)]
    assert omissions(projected) == [ImagePolicy.placeholder(big)]
  end

  test "单张超过 image_max_bytes 即卸载" do
    message = user_with_images([data_url(:binary.copy("a", 16)), data_url(:binary.copy("b", 16))])

    {[_projected], dropped} = ImagePolicy.project([message], %ImagePolicy{image_max_bytes: 8})
    assert dropped == 2
  end

  test "vision: false 时全部卸载为文本" do
    message = user_with_images([data_url(:binary.copy("a", 16))])

    {[projected], 1} = ImagePolicy.project([message], %ImagePolicy{vision: false})
    assert images(projected) == []
    assert omissions(projected) == [ImagePolicy.placeholder(data_url(:binary.copy("a", 16)))]
  end

  test "投影确定且可重复：对已投影的 messages 再投影不改字节" do
    urls = for c <- ["a", "b", "c"], do: data_url(String.duplicate(c, 16))
    message = user_with_images(urls)
    policy = %ImagePolicy{max_images: 2}

    assert {first, 1} = ImagePolicy.project([message], policy)
    assert {second, 0} = ImagePolicy.project(first, policy)
    assert second == first
    assert ImagePolicy.project([message], policy) == ImagePolicy.project([message], policy)
  end

  test "纯文本消息原样返回" do
    messages = [%{"role" => "system", "content" => "sys"}, %{"role" => "user", "content" => "hi"}]

    assert {^messages, 0} = ImagePolicy.project(messages, %ImagePolicy{vision: false})
  end

  test "atom 形状的 content 保持 atom 键" do
    url = data_url(:binary.copy("a", 16))
    message = %{role: "user", content: [%{type: "text", text: "t"}, %{type: "image_url", image_url: %{url: url}}]}

    {[projected], 1} = ImagePolicy.project([message], %ImagePolicy{max_images: 0})

    assert Enum.any?(projected.content, fn part ->
             part == %{type: "text", text: ImagePolicy.placeholder(url)}
           end)
  end

  test "占位符带稳定 id/mime/bytes，字节数按 base64 长度精确换算" do
    for size <- 1..8 do
      url = data_url(:binary.copy("z", size))
      placeholder = ImagePolicy.placeholder(url)

      assert placeholder =~ "bytes=#{size}"
      assert placeholder =~ "mime=image/png"
      assert placeholder =~ ~r/\A\[image omitted: id=[0-9a-f]{8} /
      assert placeholder == ImagePolicy.placeholder(url)
    end
  end

  test "占位符对同一 url 稳定，对不同 url 区分" do
    a = ImagePolicy.placeholder(data_url(:binary.copy("a", 16)))
    b = ImagePolicy.placeholder(data_url(:binary.copy("b", 16)))

    assert a == ImagePolicy.placeholder(data_url(:binary.copy("a", 16)))
    refute a == b
  end

  test "for_client/1 从能力与 vision 字段解析预算" do
    client = %{
      capabilities: %{
        vision: false,
        max_images_per_request: 3,
        max_request_image_bytes: 100,
        image_max_bytes: 50
      },
      vision: true
    }

    policy = ImagePolicy.for_client(client)
    assert policy.vision == false
    assert policy.max_images == 3
    assert policy.max_request_bytes == 100
    assert policy.image_max_bytes == 50
  end

  test "for_client/1 缺省与兜底" do
    assert ImagePolicy.for_client(%{}).image_max_bytes == ImagePolicy.default_image_max_bytes()
    assert ImagePolicy.default_image_max_bytes() == Newbee.LLM.Image.max_bytes()
    assert %ImagePolicy{max_images: 24} = ImagePolicy.for_client(:not_a_client)
    assert ImagePolicy.for_client(%ImagePolicy{max_images: 1}).max_images == 1
  end

  test "project_for/2 等价于 project(messages, for_client(client))" do
    message = user_with_images([data_url(:binary.copy("a", 16))])
    client = %{capabilities: %{vision: false}}

    assert ImagePolicy.project_for(client, [message]) ==
             ImagePolicy.project([message], ImagePolicy.for_client(client))
  end
end
