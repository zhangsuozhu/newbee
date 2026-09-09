defmodule Newbee.Collaboration.CrossHost.Group do
  @moduledoc "项目协作群域模型：一个群绑定一个项目；口令至少8位默认16位随机，正确口令直接加入；口令只做接入，执行靠设备独立凭据。"

  @digest :sha256
  @iterations 160_000
  @key_len 32
  @salt_bytes 16
  @min_len 8
  @gen_len 16
  @gen_chars "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"

  @weak ["12345678", "password", "qwerty123", "11111111", "00000000", "abcdefgh", "abcd1234", "1234abcd", "admin123", "letmein1"]

  @type t :: map()

  @doc "创建群。opts: password | :auto。返回 {:ok, group, plain}，plain 仅返回一次。"
  @spec create(String.t(), String.t(), keyword()) :: {:ok, t(), String.t()} | {:error, String.t(), String.t()}
  def create(name, project_id, opts \\ []) do
    with :ok <- check_name(name),
         :ok <- check_project(project_id) do
      pw_opt = Keyword.get(opts, :password, :auto)
      pw = if pw_opt == :auto, do: generate_password(), else: pw_opt
      case check_password(pw) do
        :ok ->
          salt = :crypto.strong_rand_bytes(@salt_bytes)
          hash = pbkdf(pw, salt, @iterations)
          group = %{
            "id" => gen_id(),
            "name" => String.trim(name),
            "project_id" => String.trim(project_id),
            "password" => %{
              "algo" => "pbkdf2-sha256",
              "iterations" => @iterations,
              "salt" => Base.encode64(salt),
              "hash" => Base.encode64(hash),
              "version" => 1
            },
            "epoch" => 0,
            "member_epoch" => 0,
            "default_role" => "developer",
            "created_at" => System.system_time(:millisecond)
          }
          {:ok, group, pw}
        {:error, _, _} = err -> err
      end
    end
  end

  @doc "校验口令（常数时间比较）。"
  @spec verify_password(t(), String.t()) :: boolean()
  def verify_password(%{"password" => %{"salt" => s, "hash" => h, "iterations" => it}}, pw) when is_binary(pw) do
    with {:ok, salt} <- Base.decode64(s),
         {:ok, expected} <- Base.decode64(h),
         it when is_integer(it) <- it do
      Plug.Crypto.secure_compare(pbkdf(pw, salt, it), expected)
    else
      _ -> false
    end
  end
  def verify_password(_, _), do: false

  @doc "改口令：阻止旧口令继续加入，已登记设备凭据不受影响，需单独撤销。"
  @spec change_password(t(), String.t()) :: {:ok, t()} | {:error, String.t(), String.t()}
  def change_password(group, new_pw) when is_map(group) and is_binary(new_pw) do
    case check_password(new_pw) do
      :ok ->
        salt = :crypto.strong_rand_bytes(@salt_bytes)
        hash = pbkdf(new_pw, salt, @iterations)
        old = Map.get(group, "password", %{})
        ver = Map.get(old, "version", 1)
        npw = %{"algo" => "pbkdf2-sha256", "iterations" => @iterations, "salt" => Base.encode64(salt), "hash" => Base.encode64(hash), "version" => ver + 1}
        {:ok, Map.put(group, "password", npw)}
      {:error, _, _} = err -> err
    end
  end
  def change_password(_, _), do: {:error, "invalid_password", "新口令无效"}

  @doc "生成16位随机口令。"
  @spec generate_password() :: String.t()
  def generate_password do
    chars = String.graphemes(@gen_chars)
    n = length(chars)
    1..@gen_len |> Enum.map(fn _ -> Enum.at(chars, :rand.uniform(n) - 1) end) |> Enum.join()
  end

  defp check_name(name) when is_binary(name) do
    if String.trim(name) == "", do: {:error, "invalid_name", "群名称不能为空"}, else: :ok
  end
  defp check_name(_), do: {:error, "invalid_name", "群名称不能为空"}

  defp check_project(pid) when is_binary(pid) do
    if String.trim(pid) == "", do: {:error, "invalid_project", "必须绑定一个项目"}, else: :ok
  end
  defp check_project(_), do: {:error, "invalid_project", "必须绑定一个项目"}

  defp check_password(pw) when is_binary(pw) do
    t = String.trim(pw)
    cond do
      String.length(t) < @min_len -> {:error, "weak_password", "口令至少8位"}
      String.downcase(t) in @weak -> {:error, "weak_password", "口令过于常见"}
      same_char?(t) -> {:error, "weak_password", "口令过于简单"}
      true -> :ok
    end
  end
  defp check_password(_), do: {:error, "weak_password", "口令至少8位"}

  defp same_char?(s) do
    case String.graphemes(s) do
      [] -> true
      [h | rest] -> Enum.all?(rest, fn c -> c == h end)
    end
  end

  defp pbkdf(pw, salt, it), do: :crypto.pbkdf2_hmac(@digest, pw, salt, it, @key_len)

  defp gen_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
