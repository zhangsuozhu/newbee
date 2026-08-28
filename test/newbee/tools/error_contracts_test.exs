defmodule Newbee.Tools.ErrorContractsTest do
  use ExUnit.Case, async: false
  alias Newbee.Tools.{Fs, Http, Json, Run, Search, Structural}

  test "Search.grep 非法正则返回结构化错误" do
    assert {:error, %{reason: :invalid_regex, hint: hint}} = Search.grep("([", "lib")
    assert is_binary(hint)
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
    assert hint =~ "工程树外"
    assert {:error, %{reason: :out_of_bounds}} = Fs.write(outside, "x")
    assert {:error, %{reason: :out_of_bounds}} = Fs.rm(outside)
    assert {:error, %{reason: :out_of_bounds}} = Fs.rm_rf(outside)
    assert_raise ArgumentError, ~r/工程树外/, fn -> Fs.write!(outside, "x") end
  end

  test "Run.sh 同时提供 exit 与 exit_code 并保留执行环境" do
    result = Run.sh("printf '%s|%s' \"$PWD\" \"$MIX_ENV\"")
    assert result.exit == 0
    assert result.exit_code == result.exit
    assert result.output == File.cwd!() <> "|test"
  end

  test "Http 在发请求前返回 URL 格式错误" do
    assert {:error, %{reason: :invalid_url, hint: hint}} = Http.get("not-a-url")
    assert hint =~ "scheme"
    assert {:error, %{reason: :invalid_url}} = Http.get("http://")
    assert {:error, %{reason: :invalid_url}} = Http.get("ftp://example.com")
  end
end
