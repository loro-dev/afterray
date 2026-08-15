# T1/T2 卡片质量改进 — 前后对比报告

日期：2026-08-15
方法：见 `docs/t1-t2-card-quality-plan.md`。8 个真实 slot（昨夜 00:30–02:00 与今晨
08:00–10:30），2 个本地模型。**baseline** = 改进前管线（git worktree 钉在
`2c202fa`，`slot_cards --json` 渲染 prompt + 直连 Ollama，不经 daemon）；
**after** = 改进后管线（`4ebc269` T1 信息密度打分 + `8df4dd2` T2 工具循环/v2
schema/实体校验，经 daemon 全路径）。原始运行数据在本目录的 JSON（不入库，
含屏幕原文）。

## 总表（2 管线 × 3 模型）

| 管线 | 模型 | 出卡 | 有依据标识符/卡 | 硬编造（重拼/无中生有） | 斜杠合成词* | 均延迟 |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | qwen3.5:4b | 8/8 | 1.1 | 1 | 1 | 83 s |
| baseline | qwen3.5:9b | 8/8 | 1.1 | 0 | 7 | 111 s |
| baseline | qwen3.8:27b-mlx | 8/8 | 3.8 | **5** | 4 | 61 s |
| after | qwen3.5:4b | 7/8 | 2.7 | 1 | 4 | 49 s |
| after | qwen3.5:9b | **8/8** | 2.5 | **0** | **1** | 96 s |
| after | qwen3.8:27b-mlx | 8/8 | **6.6** | **0** | 6 | 215 s |

\* `X/Twitter`、`GPU/CPU` 这类 prose 里的并列写法，指标扫描器按标识符形状命中，
不是真编造，单列。

汇总表里的 fidelity 比值（baseline 4b 0.786 vs after 4b 0.678）有分母陷阱：
baseline 卡片几乎不点名具体对象（每卡 1.1 个标识符——说得少错得少），after 卡片
携带完整 entities 列表（每卡多 2.4–4.8 个有依据的具体名字）。**该看的是每卡有依
据的具体声明数量和硬编造的绝对数**。

## 核心结论

1. **硬编造：27b 从 5 → 0。** baseline 27b 发明了两个不存在的文件路径
   （`site/src/i18n.tsx`、`afterray-protocol/lib.rs`——目录结构真假参半的
   "合理拼接"）和一个错误版本号（`v0.32.11`）。after 27b 八张卡零硬编造——
   实体校验（逐字回查 + 丢弃）与 prompt 内 `entity_candidates` 共同作用。
   当初立项的 `Qwen 3.8:27b-mlx` 式错误在该配置下已复现不出来。
2. **信息密度：after 27b 每卡 6.6 个有依据标识符**（git SHA、PR 号、模型
   tag、URL、文件名），全部 80 个 entities 都带 `moment_id` 帧引用，27 个
   threads 全部带帧引用——点击跳帧的数据链路已经成立。baseline 没有这个
   结构。
3. **decisions / not_captured 是真实好用的**。after 27b 抓到了
   "idle gate 120s→30s"、"用 load 检测替代 idle 阈值" 这类当天真实决定
   （21 条 not_captured 也诚实指出 push 结果没出现在屏幕上等缺口）。
4. **工具循环被真实使用**（27b：5 次调用——有录音的 slot 主动
   `get_transcript`，截断的核心 run 主动 `get_run_text`）。4b 从不调工具，
   但仍受益于打分后的内联选行。
5. **4b 的残余弱点**：1/8 解析失败（输出非法 JSON，可加"重试一次"缓解）；
   prose 里的重拼（`kill-ali-slop`）校验器管不到（它只裁 entities 列表）。
   4b 适合"能出卡、基本可信"，27b 才达到"值得当档案"的质量。
6. **延迟代价**：after 27b 均 215 s/卡（工具轮 + 长输出 + 大 prefill），
   峰值 497 s。对空闲时段后台任务可接受；prefix cache（Ollama 复用 / MLX
   worker #283）是继续压低它的正路。
7. **标题区分度的 Jaccard 略升**（0.19→0.24）不构成退化证据：after 标题共享
   的是真实工作对象名（同一天确实反复在弄 landing page 和 auto-summary），
   语义上更可区分（见下例）。

## 同 slot 标题实例（10:00）

- baseline/4b: *Designing automatic work summaries via 30-min cycle tracking system*
- after/4b: *Designing AfterRay Auto-Summary and Optimizing Timeline Performance*
- baseline/27b: *AfterRay auto-summary idle fix, history panel build, and Qwen MLX local model path*
- after/27b: *Tuning Auto-Summary Scheduler Gates, Evaluating Qwen Models, and Scoping the History Summary Panel*
  - 附带 decisions: idle gate 120s→30s；load 0.7/core 为主判据；否决 qwen3.5:4b
    作核心 agent 模型；复用已取消的 worktree 继续 MLX 接入。

## qwen3.5:9b 补测（候选出货配置）

9B 是 MLX persistent worker 计划的目标模型，补入矩阵后是**扫单档位的甜点**：

- **可靠性全场最佳**：8/8 出卡（4b 有 1 次解析失败）、零硬编造、逐字保真率
  0.978（全场最高）、斜杠合成词也最少（1 个）。decisions 干净具体
  （"800px demo box"、"移除 Opus 对比文案"），没有 4b 的 "Yes" 式垃圾。
- **密度在 4b 档**（2.5/卡 vs 27b 的 6.6），且与 4b 一样从不主动调工具——
  有音频的 slot 仍然只有 27b 会去读转写。
- **96 s/卡**：4b 的两倍、27b 的 45%。
- 管线增益跨模型成立的最好证据：同一个 9B 在 baseline 管线下和 4b 一样空泛
  （1.1/卡）且斜杠成词最多（7 个）；换到新管线后变为零编造 + 2.5/卡。
  **质量提升来自管线，不是模型。**

**部署建议**：9B 做 sweep 默认；有音频/高 moment 数/用户收藏的 slot 及将来的
T3 日级汇总升级用 27b；4b 仅作低配回退。

## 已知问题与后续

- 4b 解析失败 1/8：给 FINAL 非法 JSON 加一次格式重试。
- prose 内标识符不在校验范围：可选做"prose 扫描 + 置信度惩罚"（不改写模型文本）。
- 输出语言为英文：`summary_language=auto` 现在正确读 AppleLanguages，但本机首选
  语言是 `en-CN`——要中文卡片需在设置里显式选中文。
- 27b 延迟：等 MLX persistent worker 落地后复测；届时 append-only transcript
  的 KV 复用收益才真正兑现。
- 环境提示：dev.sh watcher 会把工作树随时构建部署为生产 daemon，eval 期间需要
  钉 worktree 或暂停 watcher。
