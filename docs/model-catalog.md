# 模型配置：厂家 → 凭证分组 → 模型

## 设计依据

厂家表示实际接入服务商，而非模型研发公司。OpenRouter、New API / Sub2API 部署都是接入厂家，旗下可以同时有不同研发公司的模型。一个厂家管理一个 API 根地址；同一家有不同根地址时建立不同接入条目。

分组是本地凭证边界：每组一个 Key 和一份模型列表。不同 Key 的权限、额度、套餐不同，即使模型 ID 相同也不能合并。本地分组名称不会发给服务端，服务端根据 Key 决定实际权限。

参考资料：

- [New API Token](https://github.com/QuantumNous/new-api/blob/main/model/token.go)：`Group`、`ModelLimits`、`ModelLimitsEnabled` 表达令牌的分组和模型权限。
- [New API Channel](https://github.com/QuantumNous/new-api/blob/main/model/channel.go)：渠道维护 `BaseURL`、`Models`、`ModelMapping`、`Group`。Newbee 不复制网关的计费和渠道调度后台。
- [Sub2API](https://github.com/Wei-Shaw/sub2api)：API Key 分发、鉴权、转发由网关处理；README 的 Grok 接入步骤要求创建绑定分组的 API Key，复合分组按请求模型解析具体提供商。

## 配置格式

```json
{
  "schemaVersion": 2,
  "providers": {
    "gateway": {
      "name": "公司模型网关",
      "baseUrl": "https://gateway.example.com/v1",
      "api": "openai-completions",
      "groups": {
        "default": {
          "name": "日常",
          "apiKey": "${GATEWAY_KEY}",
          "models": [
            {"id": "vendor/model-id", "name": "日常助手", "contextWindow": 128000}
          ]
        },
        "premium": {
          "name": "高级套餐",
          "apiKey": "${GATEWAY_PREMIUM_KEY}",
          "models": [
            {
              "id": "vendor/model-id",
              "name": "高级助手",
              "api": "openai-responses",
              "contextWindow": 256000,
              "responsesContinuation": false,
              "capabilities": {"vision": true, "maxImagesPerRequest": 8}
            }
          ]
        }
      }
    }
  },
  "roles": {
    "default": {"provider": "gateway", "group": "default", "model": "vendor/model-id"},
    "worker": {"provider": "gateway", "group": "premium", "model": "vendor/model-id"}
  }
}
```

厂家/分组对象键是稳定 ID，显示名称可修改。ID 不能包含空白、`/`、`~`。模型 ID 可包含 `/`，原样发送给服务端，名称不会改变请求模型。同一分组模型 ID 必须唯一，不同分组可以重复。

模型协议支持 `openai-completions`、`openai-responses`、`anthropic`、`auto`。未设置的属性继承厂家默认值；上下文及能力仍保留已有角色覆盖规则。能力包括图片输入、单张图片大小、图片数量/总字节上限、`systemPromptUpdate: "in-history"` 声明。System 更新声明只记录能力，Agent 尚不据此改变提示策略。

`responsesContinuation` 使用布尔值；旧配置的 `"true"` / `"false"` 会规范化。Key 支持明文、`${ENV_VAR}` 和 `${prime:NAME}`。编辑接口仅返回 `keyConfigured`，不返回密钥或引用原文；Key 留空表示保持当前值，删除分组表示删除凭证。

原厂家扩展字段（如 `promptCacheOptions`）、模型未知属性和角色参数保留。文件中的厂家级 `contextWindow`、`capabilities`、`responsesContinuation` 仍可作为默认值。

## 页面与选用

厂家列表 → 地址/默认协议 → 分组标签/Key → 模型属性卡片。按名称/ID 筛选模型，能力放在折叠区，角色绑定集中配置。切换厂家/分组保留草稿，关闭未保存页面会提示。

“从此分组导入模型”使用该组 Key 请求 `{baseUrl}/models`，只追加未配置 ID，不覆盖名称、协议、窗口和能力。失败明确报错，不拿旧列表冒充成功；接口未提供的能力不猜测。修改 URL/Key 后可以先导入、再保存。

选择器只读已保存模型，不在打开时扫描远程接口；显示厂家/分组和模型名称/ID，搜索匹配名称和 ID。刷新重读配置，在线发现统一在配置页。

运行时保留旧会话、Host 凭证解析和 CLI：默认组路由仍是 `gateway`，其他组是 `gateway~premium`。命令 `/model gateway~premium/vendor/model-id` 区分分组与含斜杠的模型 ID。文件角色绑定明确存储 provider/group/model 三个字段。

保存更新在线会话；生成中的请求保持当前执行，中断作用域不变，下一轮应用更新。删除分组/模型后，相关会话回到有效默认模型。保存必须保留有效的 default 角色。

## 迁移与持久化

旧文件直接可读，打开编辑页不写盘。原 provider 转为厂家和 `default` 分组，Key 移入分组，`modelApis`、`contextWindows`、`modelCapabilities`、`modelResponsesContinuations` 收拢到模型对象。角色及覆盖表引用的型号也补入列表。

首次保存旧文件，在旁边创建一次 `.v1.bak`。临时文件 + rename 原子替换，配置及备份权限 0600。服务内写入共享锁，revision 拒绝过期页面覆盖新配置。旧 `saveProvider/deleteProvider` 接口对已升级文件拒绝写入。

解析顺序不变：`NEWBEE_MODEL_JSON` → 项目 `model.json` → `model.local.json` → `~/.newbee/model.json`。适配由 `Newbee.LLM.Catalog` 负责，内部运行时元数据不写回文件。

## Jev 专用评分模型

Jev 仍归厂家和凭证分组管理，但模型类型为 `kind: "jev"`，协议为 `typesafe-systemone`。它接收 `state/questions` 并返回结构化评分，不使用聊天的 `messages`，不进入聊天选择器、CLI 聊天补全或 default/worker 等聊天角色。

在配置页创建厂家（官方地址可填 `https://api.typesafe.ai` 或 `https://api.typesafe.ai/v1`），添加分组和 Key，点击「＋ Jev 评分模型」，填写 ID（默认 `jev-latest`）。点模型卡片上的「用于上下文压缩」，即可完成用途绑定。也可在「用途绑定 → 上下文压缩」中选择已有 Jev 模型。

```json
{
  "schemaVersion": 2,
  "providers": {
    "typesafe": {
      "name": "TypeSafe",
      "baseUrl": "https://api.typesafe.ai/v1",
      "groups": {
        "scoring": {
          "name": "评分分组",
          "apiKey": "${MY_JEV_KEY}",
          "models": [
            {"id": "jev-latest", "name": "Jev 评分", "kind": "jev", "api": "typesafe-systemone"}
          ]
        }
      }
    }
  },
  "compaction": {
    "mode": "jev",
    "jev": {
      "modelRef": {"provider": "typesafe", "group": "scoring", "model": "jev-latest"},
      "maxStateTokens": 20000,
      "maxRequestTokens": 28000,
      "keepThreshold": 0.5,
      "requestTimeoutMs": 3000,
      "totalTimeoutMs": 6000
    }
  }
}
```

这是添加到现有配置中的 Jev 部分示例；保留原有聊天厂家和有效的 `roles.default`，不能用 Jev 替代聊天默认模型。

- 根地址自动补 `/v1/systemone`；带 API 路径的地址追加 `/systemone`；已包含 `/systemone` 不重复追加。支持独立中转服务的地址。
- `modelRef` 绑定后，Host 只从所选分组读取 Key。旧全局 `TYPESAFE_API_KEY` 不覆盖选中分组；分组本身配置 `${ENV_VAR}` 时仍按该引用读取。
- 未使用 `modelRef` 的旧 `apiKeyEnv` / `apiKeyProvider` 配置继续工作，沿用原有环境变量优先级和官方固定端点。
- 官方 `api.typesafe.ai` 下旧格式、未声明类型的 `jev-*` 条目会在编辑/迁移时识别为 Jev。其他服务不根据显示名称猜测类型。
- Jev 卡片不显示聊天上下文窗口、图片能力或 Responses 续接。状态/请求预算在用途绑定中用 K/M token 输入，属于本地评分预算，不是模型真实上下文上限；现有评分器限制状态 1–25K、请求 2–30K，且状态预算小于请求预算。
- 删除被绑定的模型/分组时，页面会解除绑定并切回常规压缩；手工文件中的失效引用会回退，保存接口拒绝失效引用。
- 保存后空闲会话更新压缩配置；正在生成或启动的会话在安全点应用。换绑定/预算会重置旧评分失败冷却计数。密钥仍只在 Host HTTP worker 内读取，不进入公开配置或请求正文。

Jev 集成测试见 `test/newbee/llm/jev_catalog_test.exs`，覆盖类型隔离、双分组凭证、旧配置识别、实际请求结构、引用校验和会话配置刷新。已有 Jev 的超时、熔断、无密钥回退行为保持。

## 验证

```sh
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test test/newbee/llm/catalog_test.exs \
  test/newbee/llm/configtest_test.exs \
  test/newbee/llm/config_capabilities_test.exs \
  test/newbee/web/model_config_ui_test.exs \
  test/newbee/web/session_model_restore_test.exs
```

浏览器测试使用独立配置和本地鉴权模拟接口，不修改正式配置或产生付费模型调用。覆盖按 Key 导入、属性编辑、跨组草稿、保存重开、模型切换、非法输入、窄屏。截图和测试实例放在工作树 `.newbee/catalog-test/`，不进入版本控制。
