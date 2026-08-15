# 本地模型 T2 实跑（Ollama qwen3.6:latest）

走产品推理路径：`ModelQueue` → `LlmRouterAdapter` → Ollama。
输入为 17:00–17:30 真实槽的 T1 卡片（171 帧，prompt ≈26.8KB）。

复现：

```sh
cargo run -p afterrayd --example t2_eval -- \
    --at-ms 1786698000000 --provider ollama --model qwen3.6:latest --language "简体中文"
```

| | 第 1 轮 English | 第 2 轮 简体中文 |
|---|---|---|
| 延迟 | 51.8 s | 78.9 s |
| JSON 解析 | ✓ | ✓ |
| JSON 字段 | 无 artifacts（已移除） | 同 |
| category | `other`（错，应为 coding） | `coding` ✓ |
| 专名 | `Loly`（错拼 Lody） | `Lody` ✓ |

第 2 轮在 system prompt 加入 LANGUAGE 段之后产出：

```json
{
  "artifacts": ["127.0.0.1:5175", "loro-dev/lody/pull/3309", "mactop", "#features"],
  "title": "官网预览迭代与 Lody 自动摘要推演",
  "bullets": [
    "本地站页（127.0.0.1:5175）界面视觉与功能区块的反复预览微调，停在首页 #features 区域。",
    "在 Lody 内起草自动工作总结架构（T1/T2 双链路策略）与搜索呈现方案，停留在提示词草稿中。",
    "查阅 loro-dev/lody 仓库 PR 对比页并核对终端资源监控数据，结束于 mactop 性能面板。"
  ],
  "category": "coding",
  "confidence": 0.95
}
```

## 后处理：已全部移除（2026-08-14）

早先的 `artifacts` 字段与接地校验都已删除，不做任何模型输出的后处理。

- `artifacts` 原本的理由是「字段排第一可强制模型先接地再表达」，实测证伪 ——
  模型按字母序输出，排位纯属巧合。
- 随后改成事后从 title/bullets 抽名词校验，同样撤销：静态匹配无法区分
  「没见过的真词」与「编造的词」，实测每张卡 2–4 个误报。做成门禁会误杀好卡片，
  做成告警则是给自己看的噪声。

**结论：直接信任模型输出。** 要提高可靠性应在生成端（约束解码、prompt），
不在输出端做字符串工程。
