# 模型可见工具开发合同

> 状态：强制执行。`Newbee.Environment.ToolContract` 是机器事实；本文解释原因与开发流程。

## 1. 适用范围

以下来源开发的工具全部遵守同一合同：

- 人工提交的 builtin 工具；
- Worker/Adapter 根据 `need` 自动生成的工具；
- JIT 从 prompt/rule 晋升的 L3 工具；
- 从项目 store、远端或历史 release 恢复的工具。

不存在“模型自动生成所以先放行”的旁路。动态工具在 Adapter 提案、PluginContract 编译、PluginManager static 和 Verifier static 阶段都会校验；builtin 在应用启动时校验。

## 2. 先决定是否应该新增工具

新增前依次检查：

1. 已有高层工具能否完成；能完成就扩展原工具，不新增同义入口。
2. 是否只是一个默认参数别名或纯转发；是则不要新增公开函数。
3. 是否只服务某个外部项目；项目特例留在该项目，不进入 newbee 通用工具。
4. 是否能明确写出 `when_to_use` 与 `avoid_when`；写不清边界就不应激活。
5. helper 必须用 `defp`；RPC 内部入口用 `@doc false`，不能混入模型 API。

## 3. 动态工具必填合同

工具模块仍实现 `Newbee.Environment.PluginContract` 静态 callbacks，并在 `describe/0` 返回：

```elixir
%{
  kind: :tool,
  summary: "一行用途，最多 120 字符",
  when_to_use: "什么场景选它",
  avoid_when: "什么场景选已有工具",
  capabilities: [:fs],
  effects: [:write],
  error_contract: %{recoverable: :error_tuple, unexpected: :raise},
  api: [
    %{
      name: :run,
      arity: 1,
      returns: "{:ok, value} | {:error, reason}",
      errors: "可恢复错误作为值返回"
    }
  ],
  examples: ["Newbee.Plugins.MyTool.run(input)"]
}
```

`api` 必须与排除 PluginContract callbacks 后的真实公开导出完全一致。每个 API 必须在模块 `@moduledoc` 的“可跑示例”中出现，并有函数 `@doc`。

用以下入口生成最小骨架：

```elixir
Newbee.Environment.ToolContract.template(Newbee.Plugins.MyTool, "tool.my_tool")
```

## 4. 返回值与错误

- 可预见、可恢复失败返回 `{:error, reason}` 或带 `reason/hint` 的错误 map。
- 带 `!` 的函数保留 Elixir 抛异常语义。
- 不要同时提供 tuple/map 两套成功结果。
- 不要为同一操作提供多个名称；默认参数足以表达的场景不加别名。
- 返回结构变更时，同步 `@doc`、示例、Reader 测试和调用方。

## 5. 模型提示三层预算

1. `Codec.tools/0` 常驻 function schema：≤1.5KB。
2. `Plugins.prompt_section/1` 常驻能力索引：≤1.8KB，每项只写“何时用”。
3. `tool://` 按需说明：单模块≤3.5KB；模块用途/边界/示例 + 编译器真实签名，只出现一次函数表。

源码 `@moduledoc` 可保留函数清单供 ExDoc/开发者阅读，但 `tool://` 会去掉该重复段，再以 `Code.fetch_docs` 输出真实签名。

## 6. 激活门

动态 tool release 必须通过：

```text
Adapter proposal_to_release
  -> PluginContract.validate_source(source, :tool)
  -> ToolContract.validate_module(module, envelope, source)
  -> PluginManager.static_validate(release)
  -> Verifier.static_layer(release)
  -> candidate activation
```

builtin 工具在 `Newbee.Application.start/2` 调用 `ToolContract.validate_builtins/0`；不合格时应用拒绝启动。

## 7. 提交前最低验证

```bash
mix format --check-formatted
mix compile
mix test test/newbee/environment/tool_contract_test.exs
mix test test/newbee/environment/tool_governance_integration_test.exs
mix test test/newbee/tools/tool_documentation_contract_test.exs
```

API 有副作用时再加隔离的行为测试。工具说明或示例变化时同步 `DESIGN.md`、README 和相关 `tool://` 断言。
