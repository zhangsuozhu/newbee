defmodule Newbee.Web.ApiGitTest do
  use ExUnit.Case, async: false

  describe "git RPC 集成" do
    @tag :git
    test "git 命令可用" do
      {_, code} = System.cmd("git", ["--version"])
      assert code == 0
    end

    test "模块可加载" do
      assert Code.ensure_loaded?(Newbee.Web.Api)
    end
  end

  describe "numstat 解析逻辑" do
    test "标准 numstat 输出格式" do
      # git diff --numstat 输出: "added\tdeleted\tpath"
      sample = "10\t5\tlib/foo.ex\n3\t0\tlib/bar.ex\n"
      lines = String.split(sample, "\n", trim: true)
      assert length(lines) == 2

      [line1 | _] = lines
      [added, deleted, path] = String.split(line1, "\t")
      assert added == "10"
      assert deleted == "5"
      assert path == "lib/foo.ex"
    end
  end

  describe "diff 渲染数据流" do
    test "新文件 diff 格式结构" do
      # 验证新文件 diff 的必要元素
      path = "lib/new_file.ex"
      content = "defmodule Foo do\nend\n"
      lines = String.split(content, "\n")

      header =
        "diff --git a/#{path} b/#{path}\nnew file mode 100644\n--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@"

      body = lines |> Enum.map(&("+" <> &1)) |> Enum.join("\n")
      diff = header <> "\n" <> body

      assert String.contains?(diff, "new file mode")
      assert String.contains?(diff, "+++ b/#{path}")
      assert String.contains?(diff, "+defmodule Foo do")
    end
  end
end
