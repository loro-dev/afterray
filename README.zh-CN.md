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
  <a href="#安装">安装</a> ·
  <a href="#使用-afterray">使用 AfterRay</a> ·
  <a href="#隐私">隐私</a> ·
  <a href="docs/development.md">开发文档</a>
</p>

AfterRay 是一个本地优先的 macOS 电脑历史记录应用。它会录制你的屏幕，在开启时
还会录制系统与麦克风音频以及前台应用的辅助功能（Accessibility）上下文。本地的
OCR、语音识别与搜索会把这些录制内容变成一条可以随时返回的时间线：某个时刻前后
精确的屏幕画面、文字、应用与音频。录制内容、索引和保险库密钥都留在你的 Mac 上。

## 你能用它做什么

- **在原生时间线上回溯任意时刻**，并播放当时伴随的音频。
- **按文字或按语义搜索**，覆盖 OCR 文本、语音转写、窗口标题和辅助功能上下文。
  按回车直接跳到最新的匹配，并在画面上原位高亮。
- **提问并获得引用**——内置助手只能读取你的历史记录。
- **留住重要的时刻**——收藏的时刻不会在保留期清理时被删除。
- **排除你不想被看到的应用和网站**。V0 的排除是尽力而为的——在依赖它之前，
  值得先读一遍[排除覆盖什么](#排除覆盖什么)。
- **让你的 Agent 使用它**——Claude Code、Codex 等工具可以通过你显式安装的
  `afterray` CLI 查询历史。

> [!IMPORTANT]
> AfterRay 目前处于开发者 V0 阶段。还没有公开的签名构建，所以现在需要从源码
> 构建安装；随附的 CLI 也还是开发者 CLI，而非公开版本计划中那个受限的只读网关。

## 安装

**系统要求：** Apple Silicon Mac（推荐 M3 或更新）、macOS 15+，以及约 8 GB 空闲
空间用于转写和搜索模型——如果你想要可选的本地助手，还需要额外约 17 GB。

签名版 DMG 之后会上传到
[Releases 页面](https://github.com/loro-dev/afterray/releases)。在那之前，请从
源码构建。你需要 Xcode 及 Command Line Tools，以及 Rust 工具链
（[rustup.rs](https://rustup.rs/)）：

```sh
git clone https://github.com/loro-dev/afterray.git
cd afterray

# 一次性：构建 CLI 并下载本地模型
cargo build -p afterray-cli --release
./scripts/download-models/download.sh

# 构建并启动一个签名开发版 AfterRay.app
make v0
```

`make v0` 在前台运行，用 `Control-C` 停止。源码构建会把录制数据保存在仓库内的
`.afterray/v0-data` 目录。其他所有从源码开发的内容见
[开发文档](docs/development.md)。

## 首次启动

AfterRay 会引导你完成四个步骤：选择打开它的快捷键（默认为 **⇧⌘Space**）、排除
它永远不应看到的应用和网站、可选地为你的编程 Agent 安装 `afterray` CLI，以及
下载设备端模型。

随后 macOS 会分别请求**屏幕与系统音频录制**、**麦克风**和**辅助功能**权限——
最后一项必须在系统设置中开启。权限授予后录制会自动开始，每 10 秒截屏一次。

## 使用 AfterRay

| 操作 | 方式 |
| --- | --- |
| 打开 AfterRay | ⇧⌘Space |
| 在时间中移动 | 左右拖动回溯条 |
| 播放某时刻的音频 | Space |
| 搜索或提问 | 在输入框中输入；Tab 在**搜索**和**提问**之间切换 |
| 跳到匹配结果 | 回车跳到最新匹配；其余结果保留在胶片条中 |
| 保护某个时刻 | 收藏它 |
| 停止录制 | **暂停** |
| 关闭 AfterRay | Esc 或 ⌘W |

每个时刻都带有它的截图、OCR 文本、辅助功能上下文、语音转写，以及（如果存在）
对应的音频片段。

**你的数据**存放在 `~/Library/Application Support/AfterRay`，日志在
`~/Library/Logs/AfterRay`，保险库密钥在 macOS 钥匙串中。元数据存储在加密的
SQLCipher 数据库中，各类产物文件单独加密；UI 从不打开数据库，也不持有密钥。
保险库有 100 GB 的容量预算——可在**设置 → 通用 → 存储**中调整，那里也可以
删除最近一小时、今天或全部数据。

**助手**在**设置 → AI 模型**中选择：内置的本地 Qwen3.6-27B Q4（约 17 GB）、
你本地的 Ollama，或任何兼容 OpenAI 的 `/v1` 端点。不配置任何助手时，录制、OCR
和搜索也都能正常工作。

## 从你的 Agent 中使用

AfterRay 会在引导流程中把 CLI 安装到 `~/.local/bin/afterray`，之后也可以在
**设置 → 高级 → CLI for agents** 中安装。把该目录加入 `PATH` 后，Agent 即可
直接查询历史：

```sh
afterray search 'the pricing table I saw yesterday' --json
afterray moment <moment-id> --json
afterray ask 'what did I decide about the release?'
```

本仓库还在 [`skills/afterray`](skills/afterray/SKILL.md) 附带了一个 Agent
Skill，用来教 Claude Code、Codex 等工具该使用哪些命令。

## 隐私

录制、存储、OCR、转写、向量嵌入和搜索全部在本地完成。只有两种选择会扩展这个
边界，且都是显式的：

| 路径 | 数据可能去向 |
| --- | --- |
| 内置模型 | 提示词和检索到的证据留在 Mac 上 |
| 本地 Ollama | 你配置的 Ollama 端点——通常是一个本地进程 |
| OpenAI 兼容 URL | 你选择的服务商；适用其存储、日志和训练政策 |
| 通过 CLI 的外部 Agent | 该 Agent 的进程以及它使用的任何模型服务商 |

内置助手被刻意设计为非通用电脑 Agent。它可以搜索和读取时刻、活动、记忆、OCR
和辅助功能证据，但没有任何执行 shell 命令、编辑文件、修改设置、控制录制、删除
历史或写入保险库的工具。

任何通过 CLI 返回的内容都会对那个 Agent 可见。V0 的 CLI 是完整的开发者 CLI，
请把它当作可信的本地访问，而不是安全边界。

### 排除覆盖什么

排除一个应用或一个网站是一层真实的过滤，但它不是对屏幕上一切内容的承诺。在
V0 中：

- 它跟随**前台应用**。只是并排出现在旁边的窗口——分屏、画中画、打开着的密码
  管理器——仍然在这一帧的像素里。
- 网站靠浏览器通过辅助功能暴露的 URL 匹配。不暴露 URL 的浏览器（Firefox 和
  部分 Electron 应用在内）无法匹配，域名排除在那里会静默失效。
- 截图是先拍下来的。当随之而来的应用或 URL 被判定为已排除时，该时刻及其
  artifact 会从保险库中删除——但它们是在判定之前就已经写入的。
- 系统音频是整机的一路混音。排除某个应用并不会把它的声音从录音里去掉。
- AfterRay 会在请求 ScreenCaptureKit 截图前检查隐私窗口状态。Chromium 浏览器
  使用只读的 AppleScript 窗口模式，Firefox 使用本地化的隐私窗口标题后缀，
  浏览器自身的辅助功能 chrome 作为正向回退。命中后不会创建截图、辅助功能
  artifact、OCR、活动跨度或记忆摘要。macOS 没有跨浏览器的隐私状态，所以
  Safari 和不受支持的浏览器版本仍是尽力而为；系统音频仍沿用普通的全机混音
  采集流程。

把排除前移到采集过滤器里、在帧产生之前就生效，计划在公开发布前完成。

## 故障排查

**录制一直没有开始。** 在**系统设置 → 隐私与安全性**中检查全部三项权限。源码
构建中，权限归属于启动 AfterRay 的那个终端，macOS 可能需要退出并重新打开该
应用。

**缺少某个模型。** 使用**设置 → AI 模型 → 下载缺失项**，或重新运行
`./scripts/download-models/download.sh`——已存在的文件会被复用。

**其他问题。** **设置 → 诊断**可以打开日志文件夹并复制诊断报告。

## 卸载

退出 AfterRay 并将其移入废纸篓，然后：

```sh
rm -rf ~/Library/Application\ Support/AfterRay ~/Library/Logs/AfterRay
rm -f ~/.local/bin/afterray
```

在钥匙串访问中删除 `dev.afterray.v0.vault` 条目即可移除保险库密钥；没有它，
任何残留的保险库副本都无法读取。如果你为远程助手配置过 API key，一并删除
`dev.afterray.v0.secrets`。

## 文档

- [开发文档](docs/development.md) —— 从源码构建、开发 CLI、架构、环境变量
- [发布 AfterRay](docs/releasing.md) —— 签名、公证、DMG
- [保险库加密设计](docs/vault-encryption-design.md) —— 威胁模型与密钥层级
- [V0 实现计划](docs/afterray-v0-implementation-plan.md) —— 冻结的范围与技术
  决策

## 许可证

AfterRay 是源码可见（source-available）软件，目前不是 OSI 定义的开源软件。除非
文件另有说明，否则它基于 [FSL-1.1-ALv2](LICENSE) 许可：可以为许可允许的目的
查看、构建、运行、修改和再分发它，但不得将其作为有竞争关系的商业产品或服务
提供。每个版本在发布两年后转为 Apache-2.0。
[`afterray-protocol`](crates/afterray-protocol/LICENSE) 今天即为 Apache-2.0，
以便客户端实现集成边界。本许可证不授予任何对 AfterRay 名称、徽标或商标的权利。

AfterRay 仍处于开发者预览阶段，暂时不接受外部贡献。

---

<p align="center">
  <a href="https://lody.ai">
    <img src="https://lody.ai/_docs-assets/logo-96.png" width="32" height="32" alt="Lody">
  </a>
  <br>
  使用 <a href="https://lody.ai"><strong>Lody</strong></a> 开发 —— 一个并行运行
  AI 编程 Agent 的团队工作空间，每个 Agent 都在独立的 Git worktree 中工作。
</p>
