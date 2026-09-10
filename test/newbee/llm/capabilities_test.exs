defmodule Newbee.LLM.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.Capabilities

  test "normalize/1 收敛到运行时原子键，字符串布尔与数字都能识别" do
    assert Capabilities.normalize(%{
             "vision" => "false",
             "systemPromptUpdate" => "in-history",
             "imageMaxBytes" => "1024",
             "maxImagesPerRequest" => 8,
             "maxRequestImageBytes" => 2_048
           }) == %{
             vision: false,
             system_prompt_update: :in_history,
             image_max_bytes: 1024,
             max_images_per_request: 8,
             max_request_image_bytes: 2_048
           }
  end

  test "normalize/1 丢弃未识别键与非法值" do
    assert Capabilities.normalize(%{
             "vision" => "yes",
             "systemPromptUpdate" => "at-head",
             "imageMaxBytes" => 0,
             "maxImagesPerRequest" => -1,
             "maxRequestImageBytes" => "abc",
             "unknown" => 1
           }) == %{}

    assert Capabilities.normalize(nil) == %{}
    assert Capabilities.normalize([]) == %{}
  end

  test "sanitize/1 与 to_config/1 是 normalize 的配置形状往返" do
    config = %{"vision" => false, "maxImagesPerRequest" => 4}
    assert Capabilities.sanitize(config) == config
    assert Capabilities.sanitize(%{"vision" => false}) |> Capabilities.normalize() == %{vision: false}
    assert Capabilities.to_config(%{system_prompt_update: :in_history}) == %{"systemPromptUpdate" => "in-history"}
    assert Capabilities.to_config(%{nope: 1}) == %{}
  end

  test "merge/2 后者覆盖前者，两层都先规范化" do
    base = %{"vision" => true, "maxImagesPerRequest" => 8}
    override = %{"vision" => false}

    assert Capabilities.merge(base, override) == %{vision: false, max_images_per_request: 8}
    assert Capabilities.merge(base, %{"nope" => 1}) == %{vision: true, max_images_per_request: 8}
  end

  test "put_vision/2 只改 vision，nil 与非法值不动原 map" do
    caps = %{max_images_per_request: 2}
    assert Capabilities.put_vision(caps, false) == %{max_images_per_request: 2, vision: false}
    assert Capabilities.put_vision(caps, "true") == %{max_images_per_request: 2, vision: true}
    assert Capabilities.put_vision(caps, nil) == caps
    assert Capabilities.put_vision(caps, "maybe") == caps
  end

  test "fields/0 列出全部识别字段" do
    assert Capabilities.fields() == [
             :vision,
             :system_prompt_update,
             :image_max_bytes,
             :max_images_per_request,
             :max_request_image_bytes
           ]
  end
end
