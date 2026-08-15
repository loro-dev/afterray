# Agent Chat 实现计划

> 状态：进行中，2026-08-14
> 分支基线：`feat/slot-summaries` @ `8485335`
> 目标：把现有半成品的 Ask 入口做成完整的 Agent 对话 —— 全库查询、流式输出、
> 持久化历史、Markdown 渲染的原生聊天界面。

## 已完成（`8485335` 及之前）

| 项 | 位置 |
|---|---|
| 对话持久化（schema 11：`conversations` / `conversation_messages`，级联删除，`tool_log` 列） | `crates/afterray-store/src/lib.rs` |
| 全库查询工具：`list_moments` / `get_transcript` / `get_slot_card` | `crates/afterrayd/src/tools.rs` |
| 工具目录改写为「先宽后窄」引导 | 同上 |
| T1 slot 卡片 + T2 本地模型验证 | `crates/afterray-store/src/slot.rs` |
| 界面语言 / 总结语言双设置（17 选项） | `crates/afterray-protocol/src/lib.rs` |

## 现状诊断

- `Ask` 已经走 `agent::run_readonly_agent`，但**每次提问相互独立**：不带对话历史，
  且预先塞进 10k 字符的种子上下文，模型倾向于直接作答而不追查。
- daemon 的响应协议是**一请求一行 JSON**，没有增量通道。
- `ModelQueue` 的契约是 `submit` → `wait` → 完整输出，适配器不支持流式。
- Swift 侧只有 `ControlModel.ask()` 单问单答，没有会话、气泡、Markdown、历史列表。

---

## 任务拆分

四个任务边界清晰、可并行。**A 与 B 都改 `main.rs`，需串行或分文件**；C、D 独立。

### A. Chat 会话接入 agent loop（Rust）

**产出**：`ChatSend` / `ChatList` / `ChatHistory` / `ChatDelete` 四个协议请求 + daemon 处理。

- `ChatSend { conversation_id: Option<String>, message: String }`
  - `None` 时新建会话，标题先用消息前 24 字，后续可由模型改写
  - 把该会话既往消息按 `role: content` 折进 agent 的 user prompt（超长时保留最近 N 轮 + 首轮）
  - 走 `agent::run_readonly_agent`，system prompt 用新的 `CHAT_SYSTEM_PROMPT`
  - 用户消息与助手回复各落一行；助手行的 `tool_log` 存本轮工具调用的 JSON 数组
- `agent.rs` 需要一个变体，能把每轮工具调用记录出来（现在只返回最终文本）
- **不要**保留 Ask 的 10k 种子预取：chat 的价值就在于按需追查。种子改成极简
  （当前时间、时区、今天的槽概览），其余靠工具

**验收**：CLI 可完成多轮对话且历史生效 ——

```sh
afterray chat send "我今天下午在干嘛"
afterray chat send --conversation <id> "那第三件事的报错具体是什么"   # 第二轮能理解「那」
afterray chat list && afterray chat history <id>
```

### B. 流式输出（Rust）

**产出**：`ChatStream` 请求，以 NDJSON 多行响应推送增量。

事件类型（每行一个 JSON 对象）：

```jsonc
{"kind":"tool_call","name":"get_slot_card","args":{...}}
{"kind":"tool_result","name":"get_slot_card","chars":2480}
{"kind":"token","text":"你今天下午"}      // 若适配器支持逐 token
{"kind":"done","message_id":"…","conversation_id":"…"}
{"kind":"error","message":"…"}
```

- 参考 `write_artifact_response`（`main.rs`）的分帧写法：先写 JSON 行再写负载，
  streaming 版持续写行直到 `done`
- **token 级流式**需要 `LlmRouterAdapter` 支持 `stream: true`：
  - Ollama `/api/chat`：逐行 JSON，取 `message.content`
  - OpenAI 兼容 `/v1/chat/completions`：SSE，取 `choices[0].delta.content`
  - builtin GGUF worker：暂不支持，回落为整段返回
- `ModelQueue` 不改契约；给 `LlmRouterAdapter` 加一个可选的
  `tokio::sync::mpsc::Sender<String>` 出口，chat 路径专用
- **降级要明确**：适配器不支持流式时，只推 `tool_call` / `tool_result` 事件，
  最终答案一次性到达，UI 照常工作

**验收**：`afterray chat stream "…"` 在终端逐步打印事件，Ollama 下可见 token 增量。

### C. Swift 聊天界面

**产出**：可从 Recall 界面唤起的原生对话窗口。

- 会话列表（左侧或下拉）：标题、时间、消息数，可删除
- 消息气泡：用户右对齐、助手左对齐；助手消息用 **Markdown 渲染**
  （SwiftUI 的 `Text(AttributedString(markdown:))` 或 `AttributedString(markdown:options:)`，
  代码块需等宽字体与背景）
- **流式渲染**：随事件增量追加，Markdown 需支持"边流边渲染"——
  未闭合的代码块/列表不能让整段渲染崩掉，建议按行增量解析
- 工具调用以折叠的次要样式展示（"查询了 14:00–14:30 的记录"），点击展开
- 输入框：回车发送、Shift+回车换行、发送中禁用并显示停止按钮
- 会话历史来自 `ChatList` / `ChatHistory`，不在前端另存一份
- `DaemonClient` 需要能读多行响应（现在 `send()` 只读一行）

**验收**：能连续对话、退出重进历史还在、助手输出的 Markdown 正确渲染、
流式过程可见。

### D. 设置界面：语言选择

**产出**：设置页新增语言分区。

- 两个下拉：**界面语言** 与 **总结语言**，互相独立
- 选项由 daemon 的 `Settings` 响应下发（`language_options`：17 项，
  每项含 `code` / `native_name` / `english_name`），**不要在 Swift 里另写一份列表**
- 列表显示 `native_name`（日语用户找的是「日本語」不是「Japanese」），
  `english_name` 作为无障碍标签
- 修改后调 `UpdateSettings { ui_language, summary_language }`
- `auto` 显示为「跟随系统」

**验收**：改完设置后，`afterray settings` 能读到新值；总结语言影响 T2 输出。

### E. 当日总结面板（Rust + Swift）

**产出**：Recall 界面左下、设置按钮上方的一块可折叠面板，展示指针所在那一天的总结。

**数据缺口先补**：T2 产出目前只在内存里跑完就丢，没有落库。本任务负责补上：

- `slot_summaries` 表（schema 12），字段见本文件顶部引用的
  `docs/slot-summaries-and-ax-pipeline.md` §4：`slot_start_ms` 唯一索引、
  `local_day`、`state`、`facts_json`、`title`、`bullets_json`、`category`、
  `confidence`、`generation`、`producer`、`produced_at_ms`
- `DaySummary { day_ms }` 请求：返回那一天所有 slot 的
  `{slot_start_ms, state, facts, title?, bullets?, category?}`，**T2 未跑过的槽
  也要返回**，只是没有 title —— 面板永远有内容是硬要求
- `delete_history` 要级联删除 slot_summaries

**面板要求**：

- 位置：左下角，**设置按钮正上方**，与底部 chrome 条同一竖列
- 内容：指针指向那一天的当日总结 —— 按半小时分段列出，每段一行；
  有 T2 卡片时显示标题，没有时显示确定性事实（应用 + 时长）
- 折叠：设置按钮**旁边**加一个按钮控制展开/收起；收起时只剩那个按钮，
  展开后面板才出现。状态要记住（`@AppStorage` 或等价）
- 拖动时间轴切换到另一天时，面板内容跟着换
- 当前指针所在的那个半小时要有明显高亮
- 视觉：沿用 `RecallGlass` 系列材质与 `RecallGeometry` 的间距常量，
  深色空间 + 暖红高光，不要用默认蓝
- 空态：那一天没有记录时给出明确说明，不要空白面板

**验收**：拖时间轴跨天面板跟随切换；折叠状态重启后保持；
无模型时面板仍显示事实行；`swift test` 与 `cargo test` 全绿。

---

## 约定

- 分支：各自在 `feat/slot-summaries` 上开 worktree，完成后合回
- 每个任务自带测试；`cargo test` 与 `cargo clippy --all-targets` 必须干净
  （工作区 lint 为 pedantic）
- 不要改动本文件列出的既有决定；有异议先在文档里记，别直接改实现
- 屏幕内容是不可信输入：任何进入 prompt 的库内文本都要有明确定界，
  system prompt 里声明其为数据而非指令
