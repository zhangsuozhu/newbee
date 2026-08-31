defmodule Newbee.Web.Workspace do
  @moduledoc """
  项目工作目录域（学习 dsh harness 左侧栏的 workspace 语义）：WebUI 里的
  "工作区" = 会话绑定的项目工作目录。本模块提供服务端目录浏览（一层）、
  新建子目录、路径规整——对应 harness 的 listDirectory / createDirectory RPC 面。

  目录浏览只读、一层、带 hidden 标记（前端默认隐藏，与 harness 的
  "Show hidden files" 客户端开关一致）；mkdir 只允许在已有父目录下建一层子目录。
  """

  @doc """
  列一个目录层。path 为 nil/"" 时列用户主目录（harness 语义：absent path =
  Host home）。返回 {:ok, listing} | {:error, code, message}。

  listing 结构：
      %{
        "path" => 绝对路径, "name" => 显示名(主目录缩写 "~"),
        "parent" => 父目录 | nil,
        "separator" => "/",
        "entries" => [%{"name" => _, "kind" => "dir"|"file", "hidden" => bool}]
      }
  条目排序：目录优先，名称不区分大小写。
  """
  def list_dir(path) do
    dir =
      path
      |> blank_to_nil()
      |> case do
        nil -> System.user_home!()
        p -> Path.expand(p)
      end

    cond do
      not File.dir?(dir) ->
        {:error, "not_a_directory", "不是目录: #{dir}"}

      true ->
        case File.ls(dir) do
          {:ok, names} ->
            entries =
              names
              |> Enum.map(fn name ->
                full = Path.join(dir, name)

                %{
                  "name" => name,
                  "kind" => if(File.dir?(full), do: "dir", else: "file"),
                  "hidden" => String.starts_with?(name, ".")
                }
              end)
              |> Enum.sort_by(&{&1["kind"] != "dir", String.downcase(&1["name"]), &1["name"]})

            {:ok,
             %{
               "path" => dir,
               "name" => display_name(dir),
               "parent" => parent_of(dir),
               "separator" => "/",
               "entries" => entries
             }}

          {:error, reason} ->
            {:error, "list_failed", "#{dir}: #{inspect(reason)}"}
        end
    end
  rescue
    e -> {:error, "list_failed", Exception.message(e)}
  end

  @doc "在 parent 下新建一层子目录，返回 {:ok, 新目录绝对路径}。"
  def mkdir(parent, name) when is_binary(parent) and is_binary(name) do
    base = Path.expand(parent)
    trimmed = String.trim(name)

    cond do
      trimmed == "" or trimmed in [".", ".."] or String.contains?(trimmed, ["/", "\\", "\0"]) ->
        {:error, "bad_name", "非法目录名: #{inspect(name)}"}

      not File.dir?(base) ->
        {:error, "not_a_directory", "父目录不存在: #{base}"}

      true ->
        target = Path.join(base, trimmed)

        case File.mkdir(target) do
          :ok ->
            {:ok, target}

          {:error, :eexist} ->
            if File.dir?(target) do
              {:ok, target}
            else
              {:error, "not_a_directory", "目标已存在但不是目录: #{target}"}
            end

          {:error, reason} ->
            {:error, "mkdir_failed", "#{target}: #{inspect(reason)}"}
        end
    end
  end

  @doc "校验候选工作目录：存在且是目录则返回展开后的绝对路径，否则 :error。"
  def valid_dir?(path) when is_binary(path) do
    case String.trim(path) do
      "" ->
        :error

      trimmed ->
        expanded = Path.expand(trimmed)
        if File.dir?(expanded), do: {:ok, expanded}, else: :error
    end
  end

  # 非字符串输入（nil、前端误传的对象等）一律按无效目录处理，不抛函数子句错误
  def valid_dir?(_), do: :error

  # ── 内部 ──

  defp display_name(dir) do
    home = System.user_home!()

    if dir == home, do: "~", else: Path.basename(dir)
  end

  defp parent_of(dir) do
    parent = Path.dirname(dir)

    if parent == dir, do: nil, else: parent
  end

  defp blank_to_nil(s) when is_binary(s) do
    if String.trim(s) == "", do: nil, else: s
  end

  defp blank_to_nil(_), do: nil
end
