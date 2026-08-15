# 自动更新调整计划

> 状态：已实施（阶段 0–2 + Cloudflare 后端），2026-08-15
> 基线：`main` @ `1be0c77`，实施于 `worktree-auto-update`
> 目标：让已安装的 AfterRay 能自己发现、下载、安装新版本，且不丢录制、不丢
> 系统权限、不静默跑在旧 daemon 上。
>
> 落地结果与计划的偏差见文末[实施记录](#实施记录)。阶段 3（CI）未做。

## Sparkle 是什么

macOS 上非 App Store 分发应用的事实标准更新框架，开源、2006 年至今，Transmission、
IINA、Bartender 那类应用都在用。它负责一件事：让 app 自己完成"检查—下载—替换—重启"。

运作方式：你在服务器上放一个叫 **appcast** 的 XML（本质是个 RSS），每条 item 描述一个
版本 —— 版本号、下载地址、最低系统要求、签名。app 里嵌入 `Sparkle.framework`，它按设定
间隔拉这个 XML，比对本地 `CFBundleVersion`，发现更新就下载压缩包、用 EdDSA 公钥验签、
退出 app、由一个独立的辅助进程（`Autoupdate`）把新 bundle 换上去、再把 app 拉起来。

自己写要处理的是：替换一个**正在运行**的 app bundle、装在 `/Applications` 时的权限提升、
下载文件的 quarantine 标记清除、代码签名校验、防止攻击者把你降级到有漏洞的旧版本、
断点续传、以及替换失败时的回滚。这些 Sparkle 都做完了，且经过了二十年的实战。

## 结论先行

用 **Sparkle 2**，不自研。本项目非沙盒（`build-release.sh` 的 `codesign` 只用
`--options runtime`，无 entitlements），是 Sparkle 最省事的场景。

代价是 `Sparkle.framework` 进 bundle、签名流程多三步、`build-release.sh` 的二进制
审计规则要放开一个口子。

**真正的工作量不在 Sparkle 集成，在阶段 0。** 那四项与 Sparkle 无关，但不做的话
自动更新会以"静默失败"的形式坏掉 —— 用户收不到更新且没有任何报错，或者更新了
但没生效。建议阶段 0 单独成一个 PR 先合。

发布链路本身比预想的更接近就绪：two-pass notarization 已经把 ticket staple 到了 app
bundle 上（`build-release.sh:352`），zip 打包步骤也已存在（`:345`），这两件恰好是
Sparkle 的前提条件，见 1.4。

---

## 现状事实

| 维度 | 现状 | 位置 |
|---|---|---|
| 分发 | 手工 `make release` → DMG，Developer ID 签名 + notarize + staple | `scripts/build-release.sh` |
| **notarization** | **two-pass：先 notarize app 并把 ticket staple 到 bundle，再 notarize DMG** | `build-release.sh:338-354`、`:375-389` |
| **zip 打包** | **已存在（`ditto -c -k --keepParent`），但产物在 `$temp_root` 用完即弃** | `build-release.sh:344-345` |
| 版本一致性 | `CFBundleShortVersionString` 与 `Cargo.toml` workspace version 强制相等 | `build-release.sh:130` |
| **构建号** | **`CFBundleVersion` 写死 `1`，从未递增** | `apps/AfterRay/Resources/Info.plist` |
| 沙盒 | 否 | `build-release.sh:302-314` |
| CI | 无 | — |
| 进程模型 | app 直接 `Process()` 拉起 `afterrayd`，daemon 再拉起 shim / worker | `DaemonSupervisor.swift:86-118` |
| 退出 | `.terminateLater` + `await shutdown()`，socket 关闭 → SIGTERM → 15s → SIGKILL | `AfterRayApp.swift:57-64`、`DaemonSupervisor.swift:161-200` |
| 协议版本校验 | 每个响应严格 `==` 校验 `protocol_version` | `DaemonClient.swift:420-431` |
| status 字段 | 已含 `daemon_version` / `protocol_version` / `schema_version` / `recording_state` | `RecallModels.swift:195-214` |
| 现有 manifest | `dist/*.json` 已含 version / build / sha256 / min_macos / arch / notarized | `build-release.sh:377-391` |
| store 迁移 | 版本化单向迁移 `migrate_schema_6..9` | `crates/afterray-store/src/lib.rs:2863-2932` |

两条好消息：`applicationShouldTerminate` 的等待式退出本来就是更新器需要的语义；
`DaemonStatus` 已经带 `daemon_version`，握手几乎零成本。

---

## 阶段 0：前置修正（不依赖 Sparkle，建议先合）

### 0.1 `CFBundleVersion` 单调递增

**为什么是第一项**：Sparkle 判断"有没有新版本"只看 `CFBundleVersion`。它恒为 `1`
意味着**发布了但所有用户都收不到，且没有任何报错**。

- `build-release.sh` 在 `install` 源 plist 之后、`plutil -lint`（`:265`）之前，用
  PlistBuddy 把构建号写进**组装后的** bundle plist。顺序天然安全 —— 签名在 `:316`
  才发生。
- 取值：`AFTERRAY_BUILD_NUMBER` 环境变量优先，否则 `git rev-list --count HEAD`。
- 增加一条硬校验：新构建号必须严格大于上一次发布的构建号（从 appcast 或 `dist/` 里
  最近一份 manifest 读）。这条校验的价值等同于上面那句加粗的话。

### 0.2 daemon 版本握手

现状 `recoverIfNeeded()` 只问"socket 通不通"：

```swift
if await daemonIsReachable() { return false }   // DaemonSupervisor.swift:64
```

`DaemonClient.swift:426` 的严格 `protocol_version` 校验让**协议变化时是安全的**
（旧 daemon 会被判为不可达，进而重启）。但**patch 级更新协议号不变**，此时新 app
会静默复用旧 daemon —— 新 UI 配旧 daemon 逻辑，写进同一个库。自动更新会把这个原本
罕见的情况变成常态。

- `daemonIsReachable()` 改为返回 `DaemonStatus?`。
- 比对 `status.daemonVersion` 与自身 `CFBundleShortVersionString`。两者同源
  （Rust workspace version，由 `build-release.sh:130` 强制一致），可直接比。
- 不一致 → 走 `shutdown()` 再拉起新的，而不是复用。
- dev 模式（`developmentRepoRoot() != nil`）下降级为日志警告，不强制重启。
- 测试：`swift/AfterRayRecall/Tests/DaemonWireTests.swift` 加用例。

### 0.3 引导用户把 app 移到 `/Applications`

只读 DMG 卷里的 bundle 替换不了，**从 DMG 直接运行的 app 永远无法自更新**。

- 在 `OnboardingController.showIfNeeded()`（`AfterRayApp.swift:54`）之前插入检测。
- 判据：bundle 路径不在 `/Applications` 或 `~/Applications`，且 `developmentRepoRoot()`
  为 nil（复用 `DaemonSupervisor.swift:246` 的 dev 判据）。
- 从只读卷运行时是强提示；已在磁盘但不在 Applications 时是可跳过的建议。

### 0.4 已安装的 CLI 副本会过期

`AfterRayCliInstall.install()` 是**复制**到 `~/.local/bin`（`AfterRayCliInstall.swift:69`），
更新后那份副本仍是旧的。协议号变化时它会直接报 mismatch —— 行为正确，但用户看到的是
"CLI 突然坏了"。

- 启动时若 `isInstalled`，比对副本与 bundled 二进制的 sha256，不一致则静默重装。

---

## 阶段 1：打包与分发基建

### 1.1 引入 Sparkle

- `Package.swift` 加依赖，沿用现有 `exact:` 风格锁版本。
- **主要难点**：SwiftPM 产出的是裸可执行文件，bundle 由 shell 手工组装，`swift build`
  不会把 framework 放进 bundle。需要两步：
  - `AfterRayApp` target 加
    `linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]`
    （root package 可用 `unsafeFlags`）。
  - `build-release.sh` 从 SwiftPM 解出的 XCFramework 复制 `Sparkle.framework` 到
    `Contents/Frameworks/`。具体路径形如
    `.build/artifacts/sparkle/**/Sparkle.xcframework/macos-*/Sparkle.framework`，
    **实现时用 `find` 探测确认**，不要写死。
- 非沙盒可移除 `Sparkle.framework/Versions/B/XPCServices/`（官方明确允许），省体积也
  少两个签名目标。

### 1.2 签名流程改造

官方顺序，**不加 `--deep`**：

```sh
codesign -f -s "$id" -o runtime Sparkle.framework/Versions/B/Autoupdate
codesign -f -s "$id" -o runtime Sparkle.framework/Versions/B/Updater.app
codesign -f -s "$id" -o runtime Sparkle.framework
```

插在现有 helper 签名循环（`build-release.sh:316-323`）之前，最后仍是签整个 app。
`--local` 模式下同样要走（`-` 身份）。

**会踩的坑**：现有动态库审计（`build-release.sh:282-300`）对 `@rpath/*` 依赖的检查是
"同目录下必须存在同名文件"。主二进制在 `Contents/MacOS/`，依赖是
`@rpath/Sparkle.framework/Versions/B/Sparkle`，审计会去找 `Contents/MacOS/Sparkle`，
找不到就 `die`。必须为 framework 依赖扩展这条规则 —— 而不是删掉它，那条审计有价值。

### 1.3 EdDSA 密钥

- `generate_keys` 生成，私钥进 Keychain，公钥作为 `SUPublicEDKey` 写进 Info.plist。
- 同时加 `SUFeedURL`、`SUEnableAutomaticChecks`、`SUScheduledCheckInterval`。
- **最高风险项：私钥丢失 = 所有已安装用户永久收不到更新，且无法补救**（只能让用户
  手工重装）。必须离线备份，并在 `docs/releasing.md` 里写明。

### 1.4 产物与 appcast

**这一节大部分已经做完了。** 脚本为 notarization 本来就要打 zip
（`build-release.sh:344-345`），而且已经把 ticket **staple 到 app bundle 本身**而不只是
DMG（`:352`）。后者恰好是 Sparkle 的关键前提：Sparkle 下载 zip、解压、替换 app，若
ticket 只在 DMG 上，更新出来的 app 不带 ticket，离线首次启动会被 Gatekeeper 拦。
`docs/releasing.md:62-64` 已记录这个顺序及其理由。

剩下要做的：

- **不能直接复用第 345 行那个 zip 当更新包** —— 它打在 staple 之前，里面的 app 没有
  ticket。必须在 `stapler staple`（`:352`）之后重新 `ditto -c -k --keepParent` 一份输出到
  `dist/`。这是个容易因为"反正已经有 zip 了"而想当然跳过的坑，且症状只在离线首次启动
  时出现，很难在开发机上复现。
- `sign_update` 生成 edSignature。
- appcast item 从现有 manifest（`build-release.sh:395-409`）扩展：`sparkle:version`
  （= CFBundleVersion）、`sparkle:shortVersionString`、`sparkle:minimumSystemVersion`、
  `enclosure` 带 `sparkle:edSignature` 与 `length`。
- DMG 保留给首次下载，不变。
- 托管位置见"待决策"。

---

## 阶段 2：app 内集成

- `SPUStandardUpdaterController`，dev 模式（`developmentRepoRoot() != nil`）整体禁用。
- 两处菜单各加 "Check for Updates…"：主菜单 `AfterRayApp.swift:79-97`、状态栏菜单
  `AfterRayApp.swift:204-242`。
- Settings 加自动更新开关，沿用 `SettingsSection` 模式（`AfterRaySettings.swift`）。
- `SPUUpdaterDelegate`：**录制中不打断**。用 `DaemonStatus.recordingState`
  （`RecallModels.swift:199`）判断，正在录制时推迟安装。
- 默认策略：后台自动下载，**退出时安装**。对一个持续录屏的产品，弹窗要求立即重启是
  最差的默认值。

---

## 阶段 3：CI（本轮可选）

目前完全没有 CI。手工发布能跑通，但阶段 0.1 那类"漏一步就静默失联"的风险会一直在。

- `macos-14` runner 是 arm64，可直接跑 `build-release.sh`。
- 证书用 base64 secret 导入临时 keychain；notarization 用 App Store Connect API key。
- 产出 zip + DMG + appcast，发 GitHub Release。

---

## 明确不做

- **delta 更新**：模型权重在 Application Support 而非 bundle 内，DMG 仅 ~18MB，不值。
- **降级**：store 迁移是单向的，装回旧版 daemon 打不开已升级的库。Sparkle 本身不降级；
  但应在 store 里记录最高支持 schema，旧 daemon 遇到更新的 schema 时给明确报错而不是
  误读或崩溃。
- **静默强制更新**：本地录屏产品，用户必须能控制何时替换二进制。

## 风险清单

| 风险 | 后果 | 缓解 |
|---|---|---|
| EdDSA 私钥丢失 | 全部用户永久失联 | 离线备份，写进发布文档 |
| 签名身份变更 | 屏幕录制/麦克风权限全部重置，用户需重新授权 | 保持同一 Developer ID 与 Team ID |
| 把 `--local` ad-hoc 包发给真实用户 | 后续升级到 Developer ID 版时权限重置 | 现有 `-local` 命名已有防护，发布流程再加一道 |
| 构建号未递增 | 发布了但无人收到，无报错 | 阶段 0.1 的硬校验 |
| 旧 daemon 残留被复用 | 新 UI 跑旧逻辑，静默写库 | 阶段 0.2 版本握手 |

## 待决策（已定）

1. **appcast 托管**：Cloudflare R2 + Pages Function，域名 `afterray.com`。
2. **本轮是否建 CI**：未做，仍是本机 `make release` → `make publish`。
3. **更新时机默认值**：后台下载 + 退出时安装，用户可在设置里关掉自动检查。

---

## 实施记录

### 与计划不同的三处

**1. 握手比对的是 `CFBundleVersion`，不是 marketing version。**
计划设想比对 `DaemonStatus.daemonVersion`，但那个值来自 Cargo workspace version，
同一个 marketing version 的两次构建它完全相同 —— 而"只改了 daemon 的 patch 更新"
恰好就是这种情况，握手会失效。改为：app 启动 daemon 时把自己的 `CFBundleVersion`
写进 `AFTERRAY_HOST_BUILD`，daemon 在 `status` 里回显 `host_build`（新增可选字段，
`#[serde(default)]`，不需要升 protocol_version），app 比对该值。旧 daemon 没有这个
字段，解码为 nil，同样触发重启 —— 这正是需要的行为。

**2. appcast 是动态生成的，不是静态文件。**
`site/functions/appcast.xml.ts` 从 R2 里的 `releases.json` 渲染 XML，
`site/functions/download/[[path]].ts` 从同一 bucket 提供二进制。发布因此是一次上传
而不是一次站点部署：发版不会波及营销页，营销页重新部署也不会动到已发布的版本。

**3. Sparkle 的 XPCServices 被删掉了。**
它们只为沙盒宿主存在。保留意味着签名并 notarize 一批永不执行的代码，
`build-release.sh` 会连带审计它们。`Headers`/`PrivateHeaders`/`Modules` 同理删除。

### 新发现的坑（计划里没有的）

- **`swift build` 产出裸可执行文件**，bundle 由 shell 组装，所以 `Sparkle.framework`
  的嵌入和 `@executable_path/../Frameworks` 这条 rpath 都得手工加
  （`Package.swift` 的 `linkerSettings` + `build-release.sh` 的 ditto）。
- **两个菜单都在 `AfterRayUpdater.start()` 之前构建**，updater 未启动时它们拿不到
  菜单项。启动顺序因此前移到 `installAppMenu()` 之前。
- **`AfterRayCliInstall` 没有 `import AfterRayRecall`**，加日志时才暴露。

### 验证

- `swift build` / `cargo check --workspace` 通过
- `swift test` 全绿（含两个新增的 `host_build` 解码用例）
- `cargo test --workspace`：仅 `live_ollama_streams_tokens_when_running` 失败，
  该用例在未改动的 `main` 上同样失败（本机跑着 Ollama 但缺 `qwen3.6:latest`），
  与本次改动无关
- `npx tsc -b`（site，含新增的 `tsconfig.functions.json`）通过
- `make release-local` 完整跑通打包链路

### 尚未做

- **阶段 3 的 CI**：仍是本机发布。
- **首次下载链接**：站点的下载按钮还是 `href="#download"` 占位。发布之后
  `/download/AfterRay-<version>-arm64.dmg` 即可用，接上即可。
- **R2 bucket 与 Pages 绑定尚未创建**：需要跑一次
  `npx wrangler r2 bucket create afterray-releases`。
- **私钥尚未备份**：见 `docs/releasing.md` 的 "The signing key"。
