# 输入事件与 T1 acts 重组计划

> 状态：已批准（2026-08-17 拍板）；阶段 0–4 已落地（PR #41）。**部分被 [`event-capture-v2-plan.md`](./event-capture-v2-plan.md) 取代（2026-08-18）**：R3 边沿快照被 keyframe 策略吸收；acts 的 typing 布尔方案被 `text_input.value` 取代；CAP-005 击键禁令在本地信任模型下取消。
> 关系：修订 [`slot-summaries-and-ax-pipeline.md`](./slot-summaries-and-ax-pipeline.md) §7 的若干"已决定"条目（本文为准，修订处已回改）；实现落点见文末阶段表。
> 起因：IM 类应用（飞书等）的 T1 卡片把侧边栏噪音当成用户行为 —— 实测 2026-08-17 15:20 slot 的 prompt 预算 67% 花在用户从未触碰的会话列表上，T2 卡片写成 "multi-group scan"，真实的 1:1 对话一字未提。

## 原则

**两条独立事实流 —— 屏幕状态（AX 树 / OCR，"能看到什么"）与输入事件（"做了什么"）—— 按时间与树位置 join。T1 只做 join，永不推断。**

每一次失败的尝试都是在从"屏幕上有什么"推断"用户在做什么"：几何启发式（换 app 就错）、占位符解析（过拟合）、churn（度量"有事发生"而非"用户做了事"，群聊实测指反方向）、把树丢给模型自己判断（模型层级依赖）。推断消失后，app 知识没有存在的位置，模型强弱不再影响事实层。

## 实验依据（2026-08-17，真实 vault，3 模型 × 2 场景）

场景 A：飞书 1:1（赵亮）；场景 B：飞书群聊（Lody Team，3 人）。问题：识别用户真正参与的会话。

| 表示 | 体积 | Haiku | qwen3.6:35b | qwen3.5:4b |
|---|---|---|---|---|
| 现行 T1（树序扁平行 + IDF 选行） | ~4 KB | ✗✗ | ✗✗ | ✗✗ |
| 剪枝树（保结构+坐标） | 21–28 KB | ✓✓ | ✗✓ | ✗— |
| 通用分区表示，无能动性断言 | ~4.7 KB | ✗✓ | ✓✓ | ✗✗ |
| **通用分区 + 能动性断言**（差异仅三行字） | ~4.8 KB | ✓✓ | ✓✓ | ✓✗ |

能动性断言（"输入落在区域 1，其它区域无输入"）是唯一稳定翻转结果的因素，其诚实来源只有输入事件。本地耗时（qwen3.6:35b-mlx，M 系）：~4.8KB 表示 5s/slot 内。

## 已拍板的决定

1. **Return / Tab / Esc 归命令键**，可存时刻 —— 不携带字符内容，语义是"提交/执行"（聊天=发送、终端=执行），且是区分"读 vs 写"的关键。
2. **鼠标/滚动事件在事件时刻现场解析为 AX 元素**：存元素身份（role / label / rect / 祖先链），坐标解析后即弃。rect 是 UI 几何（树里本就整棵存着），不是指针轨迹。
3. **typing burst = {起止时刻, 计数, 结束键}**，不含 keycode —— 比 §7.1 原表"slot 粒度计数"细，但无法还原明文，CAP-005 的原始理由（keycode 序列≡明文）不适用。
4. **按键归属**：焦点元素够细则用焦点；不够细（实测 Electron 给 AXWebArea、Zed 给 AXWindow）则归到最近一次点击的元素。
5. **run 切分改为 engaged-scope 变化 + 滞回**（新 scope 需 ≥2 事件或 ≥15s 成段）；快速交替（triage）归并为单 run，由点击目标 label 列表呈现。
6. **engaged 范围 = 落点 LCA 向上扩到 ≥窗口面积 10% 的祖先** —— 全系统唯一旋钮，真实语料钉死。
7. **T1 封口时物化 acts 进 facts_json** —— 事件 48h 物理删除，T1 又是惰性计算，不物化则两天后 acts 蒸发。
8. **无信号时诚实说 unknown**，永不回退到猜；tap 活性用 `seconds_since_user_input()` 对账（系统有输入而 tap 无事件 = tap 死了，标 `input-signal-unavailable`，绝不能把"信号断了"读成"用户没干活"）。

## 采集节奏（R1 / R2 / R3）

**原则：树捕获频率跟随上下文切换频率，不跟随交互强度。** 交互强度只影响事件流（每条几十字节）。

| | 触发 | 走多少 | 保留 |
|---|---|---|---|
| R1 配对心跳 | 10s 不变（配对不变量 + 均匀节奏隐私论证 + 兜底） | 整窗；已做降本：跳过 AXMenuBar 子树（原生 app 80–90% 节点是菜单）+ 100ms/次 messaging timeout + 500ms 走树预算 | 长期（现状） |
| R2 事件解析 | 每 click / burst 一次 | 单元素路径 ~30 次属性读，**不是抓树** | 事件表 48h |
| R3 边沿快照 | 确认成段的 scope 切换 + settle ~500ms + 令牌桶（≥5s 间隔，≤6/min） | 只走新 engaged 子树，AX-only 无截图 | **48h，与事件同寿** |

R3 补的是心跳唯一会整段错过内容的洞（切进会话看 8s 就走）。48h 同寿闭环了时序泄漏：事件删了而事件驱动的帧长存，会在事件过期后仍暴露交互时刻。降级顺序：负载高/电池低先砍 R3，心跳最后死。已知盲区：纯键盘导航（⌘K、j/k）检测不到 → 心跳兜底，接受，不加启发式。

R3 需要"无 moment 的 AX artifact"的导入落点（现状 AX 挂在 screen 建的 moment 上），是真实管道改动。

## T1 卡片重组

- 每 run 头部 `acts` 块（确定性）：submit 时刻、keys≈N、click/scroll 计数与目标 label。
- 文本预算按 **provenance** 排序：engaged 子树全文吃满预算 → 无 act 区域压成一行标签 + 行数（`not_engaged`，实验中把弱模型掰过来的关键字段）。IDF 降级为桶内去 chrome。
- `facts.apps[]` 加 acts 汇总（`Zed 22m, 340 keys, 3 ⌘S` vs `Zed 22m, 0 keys`）；`idle_ratio` 拆成 `not_recording_ratio`（诚实改名 —— 现值实为"录制暂停比例"）+ `no_input_ratio`（新，真的）。
- `revisits` / `theme_key` 从落点区域派生（现状按 url/document，IM 上恒定 → 永久失效；实测 theme_key 取到头像 `native-resource://…`）。
- 存储层永存原始 events + trees；折叠只在渲染层，可重渲染，不污染 vault。

## 明确不做（有实验依据）

| 不做 | 理由 |
|---|---|
| churn 作能动性信号 | 群聊实测指反方向（engaged 区 0 新增、侧边栏 40） |
| shape 行距启发式 | 实测无法区分列表与散文 |
| outcome diff（命令前后区域文本增量）作一等字段 | "前"不可得：帧间隔 ~10.7s，delta 混着自己打的字/别人发来的/UI 异步刷新，无法归因。降级为有条件字段：仅当两帧紧夹事件（各 ≤2s）才允许 attribution |
| 事件驱动截图 | 时序泄漏（事件 48h 删、帧长存）+ §7.1 心跳论证 |
| 分区算法作判据、label 阶梯作 thread 身份 | 落点 LCA 天然给出范围；thread 名由模型从 engaged 文本自得（实验 6/6） |

## 阶段

| # | 内容 | 状态 |
|---|---|---|
| 0 | shim 走树降本（菜单跳过 + 时间盒） | ✅ 2026-08-17 |
| 1 | shim 事件流：listen-only tap、burst/命令键/点击/滚动 coalesce、现场元素解析、活性对账 | ✅ 2026-08-17（运行时行为待签名 dev 实例验证） |
| 2 | store：`input_events` 表（48h、`delete_history` 级联）+ daemon 持久化。物化移入阶段 3（acts 的形状在那里才定义） | ✅ 2026-08-17 |
| 3 | T1 重组：acts / run 切分 / engaged-peripheral / not_engaged / 封口物化 | ✅ 2026-08-17（代码落点见 [acts-join](../context/acts-join.md)；fail-open 逐字节钉死，未在真实 vault 上跑过回归语料——那是阶段 5） |
| 4 | R3 边沿快照 | ✅ 2026-08-18（偏差见下；shim 运行时行为待签名 dev 实例验证） |
| 5 | 回归：≥20 slot（IM 1:1 / 群 / triage / 编辑器 / 终端），指标 = thread 命中率、幻觉会话数、focus precision（基线 33%） | |
| 独立 | theme_key/target_key 噪音修复、anchor 帧改选（首帧实测是噪音最集中的一帧） | |

## 实现契约

实现者注意：改前读根到叶的每个 `AGENTS.md`；T1 保持纯函数（无模型、无网络、固定输入 → 固定输出）；`Vault` 只能经 `afterrayd` 的 `run_store` 从异步侧调用。

### 阶段 2 — events 持久化（afterray-store + afterrayd）

- `SCHEMA_VERSION` +1，新增 `migrate` 步骤（落地时为 22 → 23：main 的 slot 时长设置先占了 22）：

  ```sql
  CREATE TABLE IF NOT EXISTS input_events (
    id INTEGER PRIMARY KEY,
    at_ms INTEGER NOT NULL,
    end_ms INTEGER,              -- burst/scroll 的结束时刻；点事件为 NULL
    kind TEXT NOT NULL,          -- burst | command | click | scroll
    count INTEGER,
    ended_with TEXT,
    command TEXT,
    bundle_identifier TEXT,
    target_json TEXT             -- 平台层 InputTargetRef 原样 JSON；本阶段不解读
  );
  CREATE INDEX IF NOT EXISTS input_events_at ON input_events(at_ms);
  ALTER TABLE slot_summaries ADD COLUMN acts_json TEXT;  -- 阶段 3 消费，此处一并迁移
  ```

- Vault API：`insert_input_events(&[InputEventRow])`（单事务，写连接）；`input_events_between(from_ms, to_ms)`（reader 池，按 at_ms 排序，`[at_ms, end_ms]` 与窗口重叠即命中，end_ms NULL 视为点）；`prune_input_events(now_ms)`（`INPUT_EVENT_RETENTION_MS = 48h`）。
- **`delete_history` 必须级联删除重叠的 `input_events`**（与 `slot_summaries` 同一隐私不变量）。
- daemon：`CaptureEvent::InputEvents` 分支从 log-only 改为 `run_store` 批量入库（target 序列化为 JSON）；`prune` 挂在既有 retention 执行点，单一 call site。
- `SharedReadOnlyVault` 本阶段**不**暴露 events（agent 工具面不变）。
- 测试：插入/查询往返（含重叠语义与未知 kind 容忍）、prune 边界、`delete_history` 级联、自 v21 的迁移、并发（写入批量时 reader 并发查询）——新并发测试须 `make test-repeat N=10 TEST=<name>` ≥5 连绿。

### 阶段 3 — T1 acts join（afterray-store/slot.rs + lib.rs + afterrayd sweeper）

- join：对封口 slot 取 `input_events_between(bounds)`；在 `slot_card()` 既有的逐帧 AX 解密循环里，把事件的 `target.frame` rect 对该帧树做包含命中（最深包含节点，几何同 `docs` 实测原型）；engaged 范围 = 落点集合的 LCA 向上扩到 ≥ 窗口面积 10% 的祖先（常量 `ENGAGED_MIN_WINDOW_AREA_RATIO = 0.10`，全系统唯一旋钮）。
- run 切分：事件按 scope key 分段，滞回 = 新 scope ≥2 事件或 ≥15s 才成段；快速交替归并为单 run（triage 呈现为点击目标 label 列表）。
- acts 聚合（per run，进 prompt 与物化，形状固定）：

  ```json
  {"keys": 180, "submits": [{"at_ms": 0, "kind": "return"}], 
   "clicks": [{"label": "0817.log", "count": 1}], "scrolls": 2,
   "signal": "ok"}
  ```

  `signal`: `ok | unavailable`（窗口内出现 `input_tap_stalled`/tap 缺失 → `unavailable`，此时**不得**输出 engaged 断言）。
- 文本预算：engaged 行吃满现有预算；peripheral 压至 ≤200 字符 + `N lines not shown`；卡片级 `not_engaged`（可见但全程无输入的区域 label + 行数）。IDF 只在桶内去 chrome。
- **fail-open 不变量（测试钉死）**：slot 内零事件 → 输出与现行为逐字节一致。
- facts 增量：`no_input_ratio: Option<f32>`（事件覆盖内无输入时长占比；无事件为 None）；`idle_ratio` 本阶段不改名不改义（UI 兼容）。
- 物化：既有 5-min sweeper 对封口且 `acts_json IS NULL` 的 slot 写入 acts JSON；`slot_card()` 在事件已过期时读取物化值。
- 协议/渲染：`render_t2_prompt` 的 run 对象加 `acts`，system prompt 措辞改为"acts 是用户做的事，text 是屏幕上有的东西，peripheral 可见但未被操作"。

#### 阶段 3 实现偏差（2026-08-17 落地时的实际取舍）

1. **timeline 的行仍按 `target_key` 切**，没有改成按 engaged scope 重切。滞回切分（`split_act_runs`）实现了并有测试，acts 按 act-run 粒度归属到 timeline 行（最大时间重叠），triage 归并因此在 acts 里可见；但重切 timeline 会牵动 `moment_id` 锚点、gaps、revisits 与既有测试，留给后续。
2. **只改了 `T2_SYSTEM_PROMPT_V2`**；v1 常量按"仅兼容读"保持原样。
3. **未做**（不在本阶段的验收清单里）：`facts.apps[]` 的 acts 汇总、`revisits`/`theme_key` 改从落点区域派生、`idle_ratio` 改名。
4. 额外收紧了两处（测试逼出来的）：partition 的开关是**事件流本身**而非调用方是否清空 `ax_join`；`signal: unavailable` 连**文本 partition 也一起抑制**——把文本分成"操作过"和"只是可见"本身就是一次能动性断言。
5. 物化只恢复 acts，**不恢复 partition**：partition 是对已删除的 rect 做命中得来的。

### 阶段 4 — R3 边沿快照（shim + afterrayd + afterray-store）

- **触发（shim `InputEventMonitor` worker）**：候选 = 前台 bundle 变化，或 click 事件。settle 去抖 500ms（新输入到达则重新计时——绝不在交互中走树）；令牌桶 ≥5s 间隔、≤6/min。v1 简化两处（记为偏差）：① 走树范围 = 触发元素所在的 **AXWindow**（focused window 兜底），不是 engaged 子树——窗口是其超集，shim 侧无需几何逻辑，菜单跳过 + 时间盒照常生效；② 负载/电池降级暂不做 shim 侧开关，令牌桶已把上界钉死（≤6/min × ~窗口级树），降级钩子留给后续。
- **发射**：`ArtifactKind` 新增 `accessibility_edge`（Swift + Rust 两侧），照常走 artifact 事件；**绝不触发截图**（事件驱动截图的时序泄漏论证仍然成立）。
- **daemon 导入**：exclusion 判定与 accessibility 分支完全一致（解析不了 → 删文件，fail-closed）；通过后存为 purpose `edge-ax` 的加密 artifact + 新表 `edge_snapshots(id, captured_at_ms, artifact_id)` 一行。**不建 moment、不出缩略图、不跑 OCR。**
- **store**：`SCHEMA_VERSION` +1（落地时 23 → 24）（`edge_snapshots` 表 + 索引）。保留期 **48h 与事件同寿**（`prune_input_events` 同点执行，连带删除 artifact 文件）；`delete_history` 级联（隐私不变量第四层）。`slot_card()` 的 acts join 把落在 slot 内的 edge 树作为**额外帧**参与 engaged/peripheral partition 与文本抽取——仅此而已，不参与 anchor/缩略图/OCR 证据。
- **测试**：导入路径（exclusion fail-closed / 正常入库）、48h prune 连带 artifact 删除、级联、join 纳入 edge 帧；IO 测试过 `make test-repeat N=10` ≥5 连绿。shim 侧去抖/令牌桶逻辑提成可单测的纯函数为佳，做不到则如实报告未验证面。

#### 阶段 4 实现偏差（2026-08-18 落地时的实际取舍）

计划里已记的两处 v1 简化照原样落地（走树范围 = 触发元素所在 AXWindow，focused window 兜底；不做负载/电池降级开关）。此外：

1. **已知浏览器一律不取边沿快照**。心跳路径的隐私浏览判定要一次 async automation 探针（osascript，1s 超时）加一次 chrome-only 预走树；两者都塞不进 1 秒一跳的 worker tick。取"不拍"而不是"少判一步"——浏览器仍有心跳覆盖。落点：`captureEdgeSnapshot` 的 `isKnownBrowser` 早退。
2. **导入侧比 accessibility 分支更严一格**：`edge_snapshot_identity` 对"能解析但没写 bundle identifier"的快照也判为不可入库。exclusion 列表按 bundle 键，没写就无从判断；心跳分支有一张已落盘的截图要处置，边沿快照丢了不亏——下一个触发只隔一次交互。
3. **artifact 没有 purpose 列**，`edge-ax` 因此挂在 content type 的参数上（`EDGE_SNAPSHOT_CONTENT_TYPE`，常量而非从事件抄来的值——AAD 绑 content type，存读不同拼法即无法解密）。
4. **edge 帧不回写事件的 scope**：run 切分按 scope 分段，R3 的职责是把某个 run 展示的文本补全，不是重切 run。落在采集空洞（capture gap）里的 edge 树不属于任何 run，直接丢弃——挂到最近的 run 上等于声称那扇窗在没有采集的那段时间在屏幕上。
5. **edge 帧不进 `not_engaged`**：卡片级"可见但全程无输入的区域"仍只由心跳帧的 join 得出。
6. edge 帧的文本**不过** `AX_TEXT_MIN_CHARS` 门槛（那道门是在一帧的 AX 文本与 OCR 之间做选择，edge 树没有 OCR 可选）；一个 run 内的顺序是"先本 run 的帧、再 edge 树"，跨 run 的时序不变。
7. **shim 侧去抖/令牌桶已提成可单测纯函数**（`EdgeSnapshotPacing`，在 `AfterRayCapturePolicy` 目标里，6 个 XCTest）。真正未验证面：tap 触发到落盘的整条运行时链路，需签名 dev 实例。

### 独立修复 — T1 噪音（afterray-store/slot.rs）

- `target_key` / `place_label` / `theme_key` / `top_documents` 的候选一律过 `is_chrome_noise` + `is_opaque_id`，并新增：`file://` 路径含 `.app/`（应用包内资源）判为 app 资源而非用户文档。实测靶子：`file:///Applications/Lark.app/…/en-US.html` 不得成为 target 身份或 top_documents；`native-resource://sdk/avatar?…` 不得成为 theme_key。全部候选皆噪音时退化为 app-only key。
- `anchor_moment_id`：从"slot 首帧"改为"最长 run 的中间帧"——实测首帧承载一次性侧边栏倾倒（1399 字符噪音），真实增量都在后续帧。纯函数，测试钉死。

## 开放 PoC

- ~~listen-only tap 是否在"系统设置 → 输入监控"留痕~~ **已解决（2026-08-18 实测）：不留痕** —— tap 在真实捕获击键时，输入监控面板无 AfterRay 条目。注意意义已随 CAP-005 取消而反转：原本这是"可验证未监听"的卖点，现在它意味着**系统不会替用户指出 AfterRay 在观察输入**，透明披露的义务完全在应用自身（onboarding/权限页明示）。原 §7.3 "移除 Permission Center 输入监控项"的建议应重新评估。
- Electron 上事件时刻现场元素解析质量（fallback：对已存树做几何命中，已验证 depth 21–39）。
- LCA 10% 旋钮跨 app 表现；engaged 子树从点击元素哪级祖先起走。
- 500ms 走树预算在大型 Chrome 页面（20k 节点上限）上的命中率。
