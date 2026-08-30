defmodule Newbee.DEE.RulesTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.Rules

  setup do
    file = Path.join(Newbee.GlobalStore.root(), "rules.json")
    backup = if File.exists?(file), do: {:present, File.read!(file)}, else: :missing
    state = :sys.get_state(Rules)
    File.rm(file)
    :sys.replace_state(Rules, fn _ -> %Newbee.DEE.Rules{} end)

    on_exit(fn ->
      case backup do
        {:present, body} -> File.write!(file, body)
        :missing -> File.rm(file)
      end

      :sys.replace_state(Rules, fn _ -> state end)
    end)

    :ok
  end

  test "注册规则并命中检查" do
    :ok = Rules.add("no-io-inspect", "IO\\.inspect", "生产代码路径不要用 IO.inspect 调试", source: :adapter)

    assert [%{id: "no-io-inspect"}] = Rules.check("IO.inspect(x)")
    assert [] = Rules.check("IO.puts(x)")
  end

  test "规则持久化到磁盘（沉睡——不占 prompt）" do
    :ok = Rules.add("persist-test", "danger", "小心")
    file = Path.join(Newbee.GlobalStore.root(), "rules.json")
    assert File.read!(file) =~ "persist-test"
    assert File.read!(file) =~ "小心"
  end

  test "重复 id 覆盖，remove 删除" do
    :ok = Rules.add("x", "a", "v1")
    :ok = Rules.add("x", "a", "v2")
    assert [%{injection: "v2"}] = Rules.check("a")
    Rules.remove("x")
    assert Rules.list() == []
  end

  test "scope 过滤：content 规则只看正文，code 规则只看代码，all 全看" do
    :ok = Rules.add("c-only", "dense", "外", scope: :content)
    :ok = Rules.add("code-only", "def foo", "码", scope: :code)
    :ok = Rules.add("all-rule", "hello", "通", scope: :all)

    # content 上下文：content 规则 + all 规则
    assert [%{id: "c-only"}] = Rules.check("dense", :content)
    assert [%{id: "all-rule"}] = Rules.check("hello", :content)
    # 代码上下文：code 规则 + all 规则
    assert [%{id: "code-only"}] = Rules.check("def foo", :code)
    # 默认 :all 上下文：all 规则
    assert [%{id: "all-rule"}] = Rules.check("hello")
  end

  test "内建 J-Space 规则在 init 时播种（缺则补）" do
    file = Path.join(Newbee.GlobalStore.root(), "rules.json")
    File.rm(file)

    {:ok, pid} = GenServer.start_link(Rules, [])
    rules = :sys.get_state(pid).rules

    assert Enum.any?(rules, &(&1.id == "jspace-outer"))
    assert Enum.any?(rules, &(&1.id == "jspace-checkpoint"))
    # 播种的都是 :content scope（outer 纪律，不误伤思考流）
    assert Enum.all?(rules, fn r -> not String.starts_with?(r.id, "jspace-") or r.scope == :content end)
    GenServer.stop(pid)
  end

  test "J-Space 规则：稠密符号/检查点命中，且 scope 隔离不误伤代码" do
    Rules.add("jspace-outer", "(→|✓\\d{2})", "展开", scope: :content)
    Rules.add("jspace-checkpoint", "(检查点|checkpoint)", "落账", scope: :content)

    assert [%{id: "jspace-outer"}] = Rules.check("结果 ✓01 编译通过", :content)
    assert [%{id: "jspace-outer"}] = Rules.check("A → B", :content)
    assert [%{id: "jspace-checkpoint"}] = Rules.check("设一个检查点", :content)
    # scope 隔离：同样的文本在 :code 上下文不触发 content 规则
    assert Rules.check("A → B", :code) == []
  end
end
