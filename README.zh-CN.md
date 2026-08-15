<p align="center">
  <img src="apps/AfterRay/Resources/AppIcon.png" width="180" height="180" alt="AfterRay 应用图标">
</p>

<h1 align="center">AfterRay</h1>

<p align="center">
  <strong>你 Mac 上私密的、可搜索的记忆。</strong><br>
  回溯你看到的、听到的、做过的一切 —— 然后让 Agent 只查询你选择分享的历史。
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

<p align="center">
  <a href="https://afterray.com">官网</a> ·
  <a href="https://afterray.com/download/latest">下载 macOS 版</a> ·
  <a href="#供-agent-使用的-cli">供 Agent 使用的 CLI</a>
</p>

AfterRay 是一款本地优先的 macOS 电脑历史记录应用。它会录制你的屏幕，并在开启时
录制系统与麦克风音频和前台应用的辅助功能（Accessibility）上下文，将它们变成一条
可搜索、可回溯的时间线。AfterRay 采集和索引的一切都保留在你的 Mac 上。

从 [afterray.com/download/latest](https://afterray.com/download/latest)
下载公开的签名版。无需自己构建 AfterRay，也不需要执行额外的首次启动命令。

你可以选择本地模型，例如自己的 Ollama，或任何提供 OpenAI 兼容 API 的 AI provider。

## 有什么酷的

- **回溯你的工作。** 在原生时间线上回到某个时刻的屏幕、文字、应用上下文和音频。
- **找到正确的时刻。** 按精确文字或语义搜索 OCR、转写、窗口标题和辅助功能上下文，
  然后直接跳到匹配结果。
- **带着证据提问。** 内置助手根据你的历史回答，并标注它使用过的时刻。
- **在本地总结工作。** 本地模型会把你的活动变成工作日志，让一天的回顾不再是原始
  时间线。
- **把历史变成更好的工作流（WIP）。** 随着历史积累，模型将帮助你改进流程，并沉淀出
  可供 Agent 使用的可复用 Skill。

## 供 Agent 使用的 CLI

AfterRay 可在**设置 → 高级 → CLI for agents**中安装 `afterray` CLI。Claude Code、
Codex 等工具可以借此查询你选择分享的历史。本仓库也在
[`skills/afterray`](skills/afterray/SKILL.md) 附带了一个供支持 Skills 的 Agent 使用的
Skill。

## 许可证

AfterRay 是源码可见（source-available）软件，目前不是 OSI 定义的开源软件。除非
文件另有说明，否则它基于 [FSL-1.1-ALv2](LICENSE) 许可：可以为许可允许的目的
查看、构建、运行、修改和再分发它，但不得将其作为有竞争关系的商业产品或服务
提供。每个版本在发布两年后转为 Apache-2.0。
[`afterray-protocol`](crates/afterray-protocol/LICENSE) 今天即为 Apache-2.0，
以便客户端实现集成边界。本许可证不授予任何对 AfterRay 名称、徽标或商标的权利。

---

<p align="center">
  <a href="https://lody.ai">
    <img src="https://lody.ai/_docs-assets/logo-96.png" width="32" height="32" alt="Lody">
  </a>
  <br>
  使用 <a href="https://lody.ai"><strong>Lody</strong></a> 开发 —— 一个并行运行
  AI 编程 Agent 的团队工作空间，每个 Agent 都在独立的 Git worktree 中工作。
</p>
