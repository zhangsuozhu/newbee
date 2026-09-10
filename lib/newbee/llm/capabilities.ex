defmodule Newbee.LLM.Capabilities do
  @moduledoc """
  模型能力：把"这个模型能做什么"变成一份可声明、可门控的路由事实。

  ## 为什么

  同一个 provider 下的模型能力并不一致（能不能读图、是否接受任意位置的 system 消息）。
  把这类判断散成 if，路由行为就不可观测、不可配置、不可测试。这里统一成模型能力声明：

  - `providers.<name>.capabilities` —— 该 provider 下所有模型的默认能力
  - `providers.<name>.modelCapabilities.<model-id>` —— 按模型的覆盖
  - `roles.<role>.vision` —— 角色级 `vision` 覆盖（兼容既有配置）

  运行期由 `Newbee.LLM.Config.client_for/2` 折进 `Newbee.LLM.Client.capabilities`，
  供 `Newbee.LLM.ImagePolicy` 等消费方读取。未识别的键会被丢弃，不静默透传。

  ## 识别的能力键

  | 配置键 | 类型 | 含义 |
  |---|---|---|
  | `vision` | boolean | 模型是否接受图片输入；false 时请求投影把图片卸载为文本 |
  | `systemPromptUpdate` | `"in-history"` | 声明模型把任意位置的最新 system 消息当作完整有效提示词。当前只作为路由事实声明并上报，agent loop 尚未消费（供后续"追加而非改写提示词"使用） |
  | `imageMaxBytes` | positive integer | 单张请求图片的字节上限 |
  | `maxImagesPerRequest` | positive integer | 单次请求保留的图片张数上限 |
  | `maxRequestImageBytes` | positive integer | 单次请求保留图片的总字节上限 |

  ## 可跑示例

      Newbee.LLM.Capabilities.normalize(%{"vision" => false, "maxImagesPerRequest" => 8})
      #=> %{vision: false, max_images_per_request: 8}

      Newbee.LLM.Capabilities.sanitize(%{"systemPromptUpdate" => "in-history"})
      #=> %{"systemPromptUpdate" => "in-history"}
  """

  @type t :: %{
          optional(:vision) => boolean(),
          optional(:system_prompt_update) => :in_history,
          optional(:image_max_bytes) => pos_integer(),
          optional(:max_images_per_request) => pos_integer(),
          optional(:max_request_image_bytes) => pos_integer()
        }

  @fields [
    :vision,
    :system_prompt_update,
    :image_max_bytes,
    :max_images_per_request,
    :max_request_image_bytes
  ]

  @doc "识别的能力字段（运行时原子键）。"
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  规范化能力 map：键名收敛到运行时原子键，非法值与未识别的键一并丢弃。

      iex> Newbee.LLM.Capabilities.normalize(%{"maxImagesPerRequest" => "8", "nope" => 1})
      %{max_images_per_request: 8}
  """
  @spec normalize(term()) :: t()
  def normalize(nil), do: %{}

  def normalize(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc -> put(acc, key, value) end)
  end

  def normalize(_), do: %{}

  @doc "配置文件形状（字符串键）的能力 map：`normalize/1` 后再还原成配置形状。"
  @spec sanitize(term()) :: %{optional(String.t()) => term()}
  def sanitize(map), do: map |> normalize() |> to_config()

  @doc "运行时能力 map → 配置文件形状（写盘、上报用）。"
  @spec to_config(term()) :: %{optional(String.t()) => term()}
  def to_config(caps) when is_map(caps) do
    Enum.reduce(caps, %{}, fn {key, value}, acc ->
      case config_key(key) do
        nil -> acc
        config_key -> Map.put(acc, config_key, config_value(key, value))
      end
    end)
  end

  def to_config(_), do: %{}

  @doc "合并两层能力（后者覆盖前者）；两层都先规范化。"
  @spec merge(term(), term()) :: t()
  def merge(base, override), do: Map.merge(normalize(base), normalize(override))

  @doc "把 `vision` 覆盖折进能力 map；`nil` 表示不改，非法值忽略。"
  @spec put_vision(t(), term()) :: t()
  def put_vision(caps, nil), do: caps

  def put_vision(caps, value) when is_map(caps) do
    case coerce(:vision, value) do
      {:ok, vision} -> Map.put(caps, :vision, vision)
      :error -> caps
    end
  end

  # ── internals ──

  defp put(acc, key, value) do
    case field(key) do
      nil ->
        acc

      field ->
        case coerce(field, value) do
          {:ok, coerced} -> Map.put(acc, field, coerced)
          :error -> acc
        end
    end
  end

  defp field(key) when key in [:vision, "vision"], do: :vision

  defp field(key) when key in [:system_prompt_update, "systemPromptUpdate"],
    do: :system_prompt_update

  defp field(key) when key in [:image_max_bytes, "imageMaxBytes"], do: :image_max_bytes

  defp field(key) when key in [:max_images_per_request, "maxImagesPerRequest"],
    do: :max_images_per_request

  defp field(key) when key in [:max_request_image_bytes, "maxRequestImageBytes"],
    do: :max_request_image_bytes

  defp field(_), do: nil

  defp config_key(:vision), do: "vision"
  defp config_key(:system_prompt_update), do: "systemPromptUpdate"
  defp config_key(:image_max_bytes), do: "imageMaxBytes"
  defp config_key(:max_images_per_request), do: "maxImagesPerRequest"
  defp config_key(:max_request_image_bytes), do: "maxRequestImageBytes"
  defp config_key(_), do: nil

  defp config_value(:system_prompt_update, _value), do: "in-history"
  defp config_value(_key, value), do: value

  defp coerce(:vision, value) when is_boolean(value), do: {:ok, value}
  defp coerce(:vision, "true"), do: {:ok, true}
  defp coerce(:vision, "false"), do: {:ok, false}
  defp coerce(:vision, _), do: :error

  defp coerce(:system_prompt_update, value) when value in ["in-history", :in_history],
    do: {:ok, :in_history}

  defp coerce(:system_prompt_update, _), do: :error

  defp coerce(:image_max_bytes, value), do: positive(value)
  defp coerce(:max_images_per_request, value), do: positive(value)
  defp coerce(:max_request_image_bytes, value), do: positive(value)

  defp positive(value) do
    case positive_integer(value) do
      nil -> :error
      n -> {:ok, n}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp positive_integer(_), do: nil
end
