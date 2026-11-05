defmodule Newbee.Tools.ErrorContractsTest do
  use ExUnit.Case, async: false
  alias Newbee.Tools.{Fs, Http, Json, Run, Search, Structural}

  test "Search.grep 非法正则返回结构化错误" do
    assert {:error, %{reason: :invalid_regex, hint: hint}} = Search.grep("([", "lib")
    assert is_binary(hint)
  end

  test "Search.grep 不存在的目录不再静默返回空列表" do
    assert {:error, %{reason: :no_such_dir, hint: hint}} = Search.grep("defmodule", "/no/such/dir/here")
    assert hint =~ "/no/such/dir/here"
    assert {:error, %{reason: :no_such_dir}} = Search.find("fs.ex", "/no/such/dir/here")
  end

  test "Search.grep 把选项放在目录位置时给出可读错误而不是 ArgumentError" do
    assert {:error, %{reason: :bad_arguments, hint: hint}} = Search.grep("defmodule", path: "lib")
    assert hint =~ "third"
  end

  test "Json.decode 非法 JSON 返回行列位置" do
    assert {:error, %{reason: :decode_failed, line: 3, column: column, position: position}} =
             Json.decode("{\n  \"a\": 1,\n  invalid\n}")

    assert column > 0
    assert position > 0
  end

  test "Json.decode 行列按 Jason 字节位置计算" do
    assert {:error, %{reason: :decode_failed, line: 2, column: column}} =
             Json.decode("{\n  \"中文\": invalid\n}")

    assert column > 8
  end

  test "Structural.insert_function 拒绝语法错误且不改文件" do
    path = Path.join(System.tmp_dir!(), "struct_contract_#{System.unique_integer([:positive])}.ex")
    source = "defmodule Contract.Target do\nend\n"
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert {:error, %{reason: :syntax_error, hint: hint}} =
             Structural.insert_function(path, Contract.Target, "def broken(")

    assert is_binary(hint)
    assert File.read!(path) == source
  end

  test "Fs 非 bang 操作返回 out_of_bounds，bang 操作仍抛异常" do
    outside = Path.join(System.tmp_dir!(), "newbee_contract_#{System.unique_integer([:positive])}")
    assert {:error, %{reason: :out_of_bounds, hint: hint}} = Fs.guard_path(outside)
    assert hint =~ "Out-of-tree"
    assert {:error, %{reason: :out_of_bounds}} = Fs.write(outside, "x")
    assert {:error, %{reason: :out_of_bounds}} = Fs.rm(outside)
    assert {:error, %{reason: :out_of_bounds}} = Fs.rm_rf(outside)
    assert_raise ArgumentError, ~r/Out-of-tree/, fn -> Fs.write!(outside, "x") end
  end

  test "Run.sh 同时提供 exit 与 exit_code 并保留执行环境" do
    result = Run.sh("printf '%s|%s' \"$PWD\" \"$MIX_ENV\"")
    assert result.exit == 0
    assert result.exit_code == result.exit
    assert result.output == File.cwd!() <> "|" <> System.get_env("MIX_ENV", "")
  end

  test "Run.sh 的 cd 只作用于本次调用，且不存在的目录会失败" do
    before = Run.sh("pwd").output |> String.trim()

    inside = Run.sh("pwd", cd: System.tmp_dir!())
    assert inside.exit == 0
    assert inside.output |> String.trim() == Path.expand(System.tmp_dir!())

    # 上一次的 cd 不得泄漏到下一次
    assert Run.sh("pwd").output |> String.trim() == before

    missing = Run.sh("pwd", cd: "/no/such/dir/here")
    assert missing.exit == :bad_dir
    assert missing.output =~ "not a directory"
  end

  test "Run.mix_format/2 接受与 mix_compile 相同的选项" do
    # The baseline repo is not fully formatted, so assert the shape only: the call
    # must accept opts and return the documented tuple instead of raising.
    assert {tag, _out} = Run.mix_format([], timeout: 120_000)
    assert tag in [:ok, :error]

    assert {:error, _} = Run.mix_format(["no_such_file.ex"], timeout: 120_000)
  end

  test "Http 在发请求前返回 URL 格式错误" do
    assert {:error, %{reason: :invalid_url, hint: hint}} = Http.get("not-a-url")
    assert hint =~ "scheme"
    assert {:error, %{reason: :invalid_url}} = Http.get("http://")
    assert {:error, %{reason: :invalid_url}} = Http.get("ftp://example.com")
  end
end
