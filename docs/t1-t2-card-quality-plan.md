# T1/T2 卡片质量改进计划

> **状态（2026-08-20 更新）：历史计划，以代码为准。**
> 当前行为：T1 选行打分见 `crates/afterray-store/src/infoscore.rs`；卡片形状、持久化与搜索见 [crates/afterray-store/AGENTS.md](../crates/afterray-store/AGENTS.md)。
>
> 已被代码推翻 —— 下文正文保留的是当初的意图：
> - 「状态：进行中」→ 已完结。**Phase 1 全部落地**：跨 slot DF 表（`text_df` / `text_df_meta`，`crates/afterray-store/src/lib.rs:1840`）、词元级 IDF、次模贪心预算选择（`crates/afterray-store/src/infoscore.rs:284`）、MinHash 近重复（`:175`）、G² keyness（`:433`）、facts 补发 `top_windows`（`crates/afterray-store/src/slot.rs:339`）。
> - **Phase 2 是以卡片 v2 落地的，而 v2 已经在另一份文档里被 v3 取代** —— [event-capture-v2-plan.md](./event-capture-v2-plan.md) §5。本文"目标格式"一节的 `threads` / `entities` / `decisions` / `category` / `confidence` 全部不再存在；今天写盘的是 `T2CardV3 { title, description, details, low_trust }`，`crates/afterray-store/src/slot.rs:807`。
> - Phase 2 第 3 项「实体校验（代码侧）」→ v3 没有 entities 可校验。同一位置的代码侧守卫改成了**引用接地**：把卡片里不属于本 slot 的 `afterray://moment/<id>` 剥掉并计数，`crates/afterray-store/src/slot.rs:1114`。
> - Phase 1 第 6 项「run 合并（同 target 之间夹 < 60s 短暂跳出）」→ **没有按本文实现**。T1 的帧 run 至今是 `target_key` 一变就断（`crates/afterray-store/src/slot.rs:1890`）；"短暂跳出折回"这个语义只存在于 acts 事件流里，且阈值是 2 个事件**或** 15 秒，不是 60 秒（`crates/afterray-store/src/acts.rs:373`、`:782`）。
> - Phase 1 第 3 项里的「OCR 几何先验（`layout_json` 的框）」→ 未落地；`infoscore.rs` 的打分不读任何版面几何。
> - Phase 2 第 5 项「语言：`auto` 读 `AppleLanguages`」→ 已实现，走 `CFLocaleCopyPreferredLanguages`，`crates/afterray-platform-macos/src/locale.rs:18`。
>
> **未修复的缺陷 —— `scripts/t2-eval.py` 对当前 daemon 是失灵的，这就是 WS7（语料回归）至今没做的原因：**
> - `card_text`（`scripts/t2-eval.py:102`）读 `title` / `bullets` / `threads[].name,prose` / `entities[].text` / `decisions`，全是 v1 与 v2 的字段。daemon 的 `slot_summarize` 响应里 `card` 就是序列化后的 `T2CardV3`（`crates/afterrayd/src/main.rs:3342`），只有 `title` / `description` / `details` / `low_trust`。**交集只剩 `title` 一项** —— 于是实体保真率、编造数、`han_ratio` 全都只在一张卡的**一行字**上计算，然后报出一个看起来很像回事的数字。
> - `entities_dropped_by_daemon`（`scripts/t2-eval.py:270`）读 `verification.entities_dropped`；v3 的 `T2GroundingReport` 只有 `citations_dropped` 一个字段（`crates/afterray-store/src/slot.rs:1103`），所以这个计数器**永远是 0**，无论 daemon 丢掉了多少东西。
>
> **一对无人认领的矛盾结论。** [`docs/evals/t1-t2-2026-08-14/local-model/README.md:37-48`](./evals/t1-t2-2026-08-14/local-model/README.md) 断言后处理「已全部移除……直接信任模型输出」，理由是静态匹配分不清"没见过的真词"和"编造的词"；**一天之后**的 [`docs/evals/t2-cards/REPORT.md:32-36`](./evals/t2-cards/REPORT.md) 记录代码侧实体校验把 27b 的硬编造从 5 压到 0。两份文档互不引用，也没有第三份裁决。今天的代码站在后者一边：生成之后仍有代码侧接地在剥掉接不上的引用（`ground_t2_details`，`crates/afterray-store/src/slot.rs:1114`）。

状态：进行中 **[已完结，见上方状态块]**
日期：2026-08-15
评测模型：本地 Ollama `qwen3.5:4b` 与 `qwen3.8:27b-mlx`（都走 daemon 现有
OpenAI-compatible 调用路径）。评测矩阵 2 模型 × 2 管线版本（baseline / after），
最终报告给出四格前后对比表——4b 看改进对小模型的拉动，27b 看管线上限。

## 诊断（改进针对的具体缺陷）

对 2026-08-15 真实 vault 的 5 张 `done` 卡片和 01:00 slot 的完整渲染 prompt 做了检查：

1. **Prompt 承诺了工具，运行时没有工具。** `T2_SYSTEM_PROMPT` 三处指示模型"用 OCR 工具取
   more_chars / 用 moment 工具读 transcript"，但 `run_slot_t2` 是一次性 `ModelInput::Llm`
   提交。01:00 slot 有 79,513 字符（87%）被内联预算裁掉且永远不可达；5 个 slot 全部
   `has_audio=true`，没有一条 bullet 引用过语音。
2. **选行策略挑中噪音。** round-robin 从每个 run 取头部行，而应用界面的头部行是导航。
   实例：一段 13,520 字符的 ChatGPT 对话，进入 prompt 的是 `["New chat","Projects"]`。
   T1 只有去重（`LineDedup`），没有任何信息量打分。
3. **实体编造。** 三张卡片写了 `Qwen 3.8:27b-mlx`，输入证据里是 `qwen3.5:4b` /
   `qwen3.6:35b-mlx`。纯 prompt 约束（"copied exactly"）对小模型不可靠，缺代码侧校验。
4. **标题同质化。** 5 张标题全是 "Refining/Setting up/Deep work" 式活动描述，互相不可
   区分——违背 prompt 第一段的 SEPARATING 要求。缺结构强制（threads/entities/decisions）。
5. **算好的事实没发。** `top_windows` / `top_urls` / `top_documents` / `theme_key` 在
   T1 里算了，`render_t2_prompt` 没有传给模型。`T2Card.artifacts` 字段无人读写。
6. **语言解析失效。** `summary_language=auto` 读 `LANG`，GUI 启动的 daemon 没有该变量，
   永远落到英文。应改为：显式设置优先；`auto` 读 macOS `AppleLanguages`。
7. **run 过碎。** 01:00 slot 30 分钟切出 69 段（均值 26 秒），每段能分到的内联行撑不起
   任何叙述。

## 目标格式

**[已推翻 → `crates/afterray-store/src/slot.rs:807`]** 下面这份字段表是卡片 **v2**；v2 已被 v3 取代（[event-capture-v2-plan.md](./event-capture-v2-plan.md) §5），`threads` / `entities` / `decisions` / `not_captured` / `category` / `confidence` 全部不再存在。每个字段是怎么输掉的，写在 `T2CardV3` 上方的注释里。

参照 Skysight 10 分钟摘要的结构（`~/.codex/memories/extensions/skysight/resources/`），
但把它的"引用文件路径"升级为我们独有的"引用帧"：

- `title` / `description`（frontmatter 对应物）
- `threads[] {name, prose, moment_ids}`（对应它的 per-thread 小节；moment_ids 支持点击跳帧）
- `entities[] {text, kind, moment_id}`（对应 "Important non-obvious context"；逐字标识符）
- `decisions[]`（对应 "The clearest decision captured…"）
- `not_captured[]`（对应它的诚实缺口声明）
- `category` / `confidence` 保留；`bullets` / `artifacts` 废弃（读取侧兼容 v1）

## 阶段

### Phase 0 — eval 基建 + baseline（先于一切改动）

- `scripts/t2-eval.py`：unix socket NDJSON 客户端。
  1. 快照当前 day payloads（eval 会覆盖存储卡片，先保底）；
  2. 把 daemon 的 llm_model 切到 `qwen3.5:4b`；
  3. 对选定 slot 逐个 `slot_prompt`（存精确输入）+ `slot_summarize`（走 daemon 全路径，
     含解析与持久化，latency 可比）；
  4. 产出 `docs/evals/t2-cards/baseline.json` + 摘要表。
- Slot 选取：昨晚 00:30–02:00 + 今晨 08:00 起，`moment_count ≥ 20`，共 6–8 个。
- baseline = 当前 HEAD 管线 + qwen3.5:4b。运行中的 daemon 即当前管线，无需重启。

### Phase 1 — T1 信息密度（确定性，无模型参与）

1. **跨 slot DF 表** `line_df(dedup_key, slot_count, last_seen_ms)`：slot 关闭时增量更新；
   首次使用时从既有历史回填。行级 IDF 杀 chrome（"New chat" 的 df 会趋于 slot 总数）。
2. **词元级 IDF**：ASCII 按词、CJK 按字符 2-gram 的混合切分，token DF 同表存储
   （`kind` 列区分），未见过的新行按 token IDF 之和打分。
3. **行打分** = token-IDF 和（长度次线性阻尼）
   + 实体模式加成（路径/URL/命令/错误串/版本号 regex）
   + OCR 几何先验（`layout_json` 的框：height 帧内百分位、位置、confidence 阈值）
   + 帧内持续性 × 跨 slot 稀有度 2×2（持续+稀有=正在编辑的文档，最高权；持续+常见=chrome，丢）。
4. **预算选择**：次模贪心（token 覆盖目标，边际增益/字符成本排序）替换 round-robin；
   保留 per-run 保底一行与 per-run cap。冗余由覆盖函数天然抑制。
5. **近重复**：字符 3-gram MinHash（64 perm）补 `dedup_key` 抓不住的滚动错位。
6. **run 合并**：同 target 之间夹短暂跳出（< 60s）的段落合并。 **[未实现（2026-08-20 核对）→ `crates/afterray-store/src/slot.rs:1890`；折回语义只在 acts 流里，阈值 2 事件 / 15 秒，`crates/afterray-store/src/acts.rs:373`]**
7. **G² keyness**（slot vs 背景语料）产出 `theme_key` 与实体候选列表，进 T1 卡。
8. facts 视图补发 `top_windows` / `top_urls` / `top_documents`。

### Phase 2 — T2 agent 循环 + 新 schema

1. **工具循环**：复用 TOOL/ARGS 协议与 agent 循环骨架，slot 域 ToolHost：
   `get_run_text(id, offset)`（分页，单次 ≤3k 字符）、`get_transcript(from,to)`、
   `get_ocr(moment_id)`、`get_prev_cards(n)`。
   transcript **append-only**（KV prefix cache 前提，Ollama 前缀复用 / MLX worker #283
   同样受益），不做中途裁剪，轮数 ≤8 封顶。
2. **新 schema**（见"目标格式"）+ 解析兼容 v1；`slot_summaries` 表迁移。
3. **实体校验（代码侧）**：卡片生成后，entities 与 threads 文本里的标识符逐字回查
   "prompt 输入 ∪ 工具返回"，对不上的丢弃并降 confidence。 **[已推翻 → `crates/afterray-store/src/slot.rs:1114`：v3 无 entities，改为剥掉不属于本 slot 的 `afterray://moment/<id>` 引用]**
4. **prompt 重写**：内联地图瘦身（目标 ~5k 字符），工具指令与现实一致，输出契约改为新 schema。
5. **语言**：设置值优先；`auto` → daemon 读 `AppleLanguages`（不再读 `LANG`，
   不做内容语言探测）。
6. UI 最小改动：day panel 渲染 threads（替代 bullets）；完整 Skysight 式渲染与 T3 后续做。

### Phase 3 — after eval + 对比报告

同一批 slot、同一模型重跑，对比 baseline。报告进 `docs/evals/t2-cards/`。

## 指标（脚本自动计算 + 人工核读）

**[脚本已对不上当前 daemon（2026-08-20 核对）]** `scripts/t2-eval.py:102` 的 `card_text` 读的是 v1/v2 字段，与 `T2CardV3` 的交集只有 `title`，下表中「实体保真率」「标题区分度」等自动指标因此只在一行字上计算；`entities_dropped_by_daemon`（`:270`）读的字段 v3 不发，恒为 0。详见顶部状态块。

| 指标 | 定义 | 期望方向 |
| --- | --- | --- |
| 实体保真率 | 输出中标识符样 token（版本/路径/命令/model tag/反引号段）逐字存在于输入证据的比例 | ↑（编造数应为 0） |
| chrome 占比 | 内联 prompt 字符中，行 df ≥ 阈值者占比（DF 表建成后对 baseline prompt 回算） | ↓ |
| 标题区分度 | 相邻 slot 标题两两字符 bigram Jaccard | ↓ |
| JSON 有效率 | 输出可解析为合 schema 卡片的比例 | ↑ |
| prompt 规模 / latency | 内联字符数；端到端毫秒（含工具轮次） | 内联↓；latency 允许适度↑ |
| 覆盖 | facts 中 ≥5min 的线索是否在卡片中出现（人工） | ↑ |
| 语言正确 | 输出语言 == 设置语言 | 修复后 100% |

## 风险与注意

- **4b 模型的工具协议遵循**：TOOL/ARGS 是文本协议，qwen3.5:4b 可能格式漂移；解析已有
  容错（首个 JSON 对象提取），eval 里单独记录工具轮格式错误率。若不可用，降级预案是
  单轮 + 更大内联预算（Phase 1 的选行改进独立于工具循环成立）。
- **eval 会覆盖真实卡片**：先快照；最终管线重跑本就会写入更好的卡片。
- **after 条件需要重启 daemon**（加载新管线）；打断录制几秒，dev 实例可接受。
- **DF 表冷启动**：历史不足时打分退化，保留现有 `is_chrome_noise` 规则作下限。
- KV cache 复用在 Ollama 侧依赖 runner 不被打断，eval 时避免并发聊天请求。
