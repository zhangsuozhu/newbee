# 压缩召回评测

离线脚手架，用来比较 Newbee 现有的压缩路径会不会丢掉还能答对的事实。它不调用 Jev，也不调用写作模型。合成夹具只证明手臂和判决接得上真实的 `Policy` / `Projection`，**不是测量结果**。

## 对照臂

| 臂 | 上下文 |
|---|---|
| `full` | 原始转录。天花板。 |
| `legacy` | 夹具里的 Archive 式摘要，加最近若干条。不在这里调用摘要模型。 |
| `recency` | 从最旧的工具结果开始删，直到 token 估计不高于 Jev 投影，不留地址。 |
| `jev` | cassette 分数经过 `Policy.decide/3` 和 `Projection.apply/3`。 |
| `jev_read` | 与 `jev` 同一上下文。每题最多一次 `spill://` 读回，由脚本答案代表。 |
| `wording` | 与 `legacy` 同一上下文的第二套答案，用来量措辞噪声。 |

闭卷“仍在上下文”是诊断，不是判决指标。判决看脚本答案里的标准答案是否出现。标准答案必须是可核对的短事实。

## 写死的判决

`Newbee.Evals.CompactionRecall.judge/1` 只有下面全部成立才返回 `:keep`：

- 不是合成夹具，且可答题至少 60。
- `Projection.validate/3` 没有失败。全文臂至少答对 90%，否则 `:invalid`，不要调阈值。
- 有 wording 对照。
- Jev 投影的 token 估计不高于 legacy。
- Jev 闭卷答对率不低于 legacy 三个百分点，或者一次读回追平 legacy。
- 工具事实的一次读回答对比闭卷多。地址没有被用到，就不能算赢。
- Jev 对 recency 的净胜至少 8 题，并且大于 wording 摆动。

合成会话永远带 `:synthetic_fixture`，不能 keep。

## 真实会话

放到 `evals/compaction_recall/private/`。这个目录被 gitignore，不要提交转录。JSON 形状与 `Newbee.Evals.CompactionRecall.synthetic_session/0` 相同：`messages`、`scores`、`legacy_summary`、`questions`、`answers`。`synthetic` 必须是 `false`。`scores` 是已经发生的 Jev cassette，不要在评测进程里重新打分。

```bash
mix run -e 'IO.puts(Newbee.Evals.CompactionRecall.run_file!("evals/compaction_recall/private/session.json").scorecard)'
```

评分卡只打印计数。它不应该出现标准答案或工具原文。
