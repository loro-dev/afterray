# T1/T2 卡片质量改进计划

状态：进行中
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
6. **run 合并**：同 target 之间夹短暂跳出（< 60s）的段落合并。
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
   "prompt 输入 ∪ 工具返回"，对不上的丢弃并降 confidence。
4. **prompt 重写**：内联地图瘦身（目标 ~5k 字符），工具指令与现实一致，输出契约改为新 schema。
5. **语言**：设置值优先；`auto` → daemon 读 `AppleLanguages`（不再读 `LANG`，
   不做内容语言探测）。
6. UI 最小改动：day panel 渲染 threads（替代 bullets）；完整 Skysight 式渲染与 T3 后续做。

### Phase 3 — after eval + 对比报告

同一批 slot、同一模型重跑，对比 baseline。报告进 `docs/evals/t2-cards/`。

## 指标（脚本自动计算 + 人工核读）

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
