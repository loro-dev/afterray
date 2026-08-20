# AfterRay Vault 加密设计

> **状态（2026-08-20 更新）：这是已接受的设计。两者不一致时，以代码为准。**
> 以下各点已被取代或尚未实现——下面的正文仍保留原始表述：
> - §4「锁屏…尽快从内存清理密钥」→ daemon 不做这件事。派生出的数据库密钥和 artifact wrapping key 在 `Vault` 上活满整个进程生命周期，没有任何路径卸载它们（字段 `crates/afterray-store/src/lib.rs:770`，派生 `crates/afterray-store/src/lib.rs:1029`）；`DaemonSupervisor.suspendForSystemLock` 只翻一个布尔标志（`apps/AfterRay/Sources/DaemonSupervisor.swift:231`），daemon 继续运行、socket 继续监听。§8.1 用自己的话承认了这一点，§4 却读起来像已经做完。
> - §4「如确实需要落盘缓存，它必须和原 artifact 使用同等级加密，并进入统一删除范围」/ §5 把 导出文件 列入 物理回收 → 有一个反例。`SummaryExportFileStore` 把 slot 摘要以**明文** JSON 写进 `$TMPDIR/AfterRay-Summary-Exports/<uuid>.json`，权限 `0600`，保留上限 24 小时（`swift/AfterRayRecall/Sources/SummaryExportFileStore.swift:21`、`swift/AfterRayRecall/Sources/SummaryExportFileStore.swift:5`）。它在 vault 之外，`Vault::delete_history` 只删 vault 内的 moments / artifacts / memories / slot_summaries / input_events / edge_snapshots，够不着它（`crates/afterray-store/src/lib.rs:3269`）。实际约束这些文件的不是加密也不是统一删除，而是 Swift 侧的三处生命周期清理：启动（`apps/AfterRay/Sources/AfterRayApp.swift:63`）、锁屏/睡眠（`apps/AfterRay/Sources/AfterRayApp.swift:1278`）、退出（`apps/AfterRay/Sources/AfterRayApp.swift:91`）。
> - §5「由用户主动创建的恢复包」→ 未实现，且整个 workspace 里没有任何口令 KDF（argon2 / scrypt / PBKDF2 一个都没有）。后果是当下就生效的：已有 vault 缺少 Keychain 条目时 `Vault::open` fail-closed 返回 `StoreError::MissingVaultKey`（`crates/afterray-store/src/lib.rs:1003`），所以 Keychain 条目丢失 = 不可恢复的数据丢失，没有第二条路。
> - §8.1「macOS Data Protection Keychain 保存主密钥」→ 机制名称不对。已签名的 Developer ID 构建落在**文件 keychain**：`persist_keychain_item` 先试 protected keychain，收到 `errSecMissingEntitlement` 就回落（`crates/afterray-store/src/lib.rs:481`），回落路径写 `kSecAttrAccessible = "aku"`（`crates/afterray-store/src/lib.rs:439`、`crates/afterray-store/src/lib.rs:546`）并关掉 iCloud 同步（`crates/afterray-store/src/lib.rs:541`）。原因是没有 provisioning profile 时 AMFI 会拒绝所需 entitlement，代码注释记在 `crates/afterray-store/src/lib.rs:426`。契约（设备绑定、仅解锁后可读）等价，名字不对。
> - §8.1「artifact id、content type、格式版本和用途进入 AEAD authenticated data」→ 格式版本没有进去。`artifact_aad` 绑定的是常量域字符串 `afterray-artifact-v1\0` + purpose + id + content_type（`crates/afterray-store/src/lib.rs:6165`）；`format_version` 是 `artifacts` 表的一列（`crates/afterray-store/src/lib.rs:5140`）。这样做可以说更强（域字符串固定，版本降级不靠 AAD 挡），但文档的描述是错的。
> - §8.2「锁定状态由 daemon 自己向系统查询，不信任调用方声称的解锁」→ 方向正好反过来。锁屏/睡眠只有 Swift app 在监听（`apps/AfterRay/Sources/AfterRayApp.swift:176`），随后调用 `recordStop`（`apps/AfterRay/Sources/AfterRayApp.swift:203`）；daemon 的 `record_stop` 照单执行，不向系统查询任何东西（`crates/afterrayd/src/main.rs:2276`）。
> - §5「vacuum 策略」→ 代码里没有任何 VACUUM。只有 `PRAGMA secure_delete = ON` 部分补偿（`crates/afterray-store/src/lib.rs:6242`）。
> - §8.2「安全评审覆盖随机数、nonce、key derivation、文件替换和 downgrade 风险」→ 没有留下任何评审产物。
>
> §1 的 daemon 独占 vault 已经单独立档，见 [decisions/active/architecture/2026-08-20-daemon-owns-the-vault.md](decisions/active/architecture/2026-08-20-daemon-owns-the-vault.md)。

> 状态：Accepted  
> 决策日期：2026-08-13  
> 适用范围：V0 及后续桌面版本

## 1. 决策

AfterRay 的正式产品采用应用级静态加密，FileVault 只作为额外的设备级保护，不能替代 AfterRay 自己的加密层。

Vault 分成两类数据，并分别处理：

- Metadata、OCR、Transcript、全文索引和其他结构化记录保存在 SQLCipher 数据库中。
- 截图、音频和其他大型 artifact 独立保存；每个 artifact 都使用带认证的加密算法加密，不使用一个巨大的加密容器。

Swift UI 不直接读取数据库、artifact 文件或密钥。Rust daemon 是 Vault 的唯一所有者，负责加密、解密、查询、保留策略和删除；UI 只通过有版本的本地 IPC 获取必要的 read model 或当前需要展示的解密结果。

## 2. 密钥结构

每个 Vault 使用一个随机生成的主密钥。主密钥由 macOS Keychain 保存，使用 `ThisDeviceOnly` 类型的保护，默认不随普通系统备份迁移到其他设备。

正式版本中，每个 artifact 使用独立随机数据密钥（DEK）：

1. artifact 内容使用 DEK 和 AEAD 加密。
2. DEK 由 Vault 主密钥包裹后保存。
3. immutable metadata（artifact id、类型、版本等）作为 authenticated data 参与校验，防止密文被替换到错误记录。

数据库由从 Vault 主密钥派生的独立数据库密钥保护。数据库密钥和 artifact 加密密钥必须使用不同的派生上下文，不能直接复用同一段 key bytes。

当前实现已经使用 wrapped per-artifact DEK。旧 V0 的单一 Vault key + nonce 文件会在打开 Vault 时逐文件迁移；数据库也会从直接使用 Vault key 自动 rekey 为独立派生的 database key。该迁移不改变 Swift/Rust 的所有权边界。

## 3. 算法与文件组织

- 数据库：SQLCipher。
- artifact：XChaCha20-Poly1305，或经过安全评审后等价的 AEAD。
- 文件粒度：一张截图或一个有界音频 segment 对应一个独立密文 artifact。
- 禁止把所有媒体放进一个需要整体解密或整体重写的大容器。
- nonce 必须对同一密钥保持唯一；随机数必须来自系统安全随机源。
- artifact header 必须带格式版本，便于后续迁移算法或密钥结构。

独立 artifact 的结构符合 Timeline 的随机访问方式：回溯时只读取和解密当前帧及少量相邻帧，收藏或删除某条记录也不需要重写全部历史。

## 4. 运行时规则

- 用户登录且设备已解锁时，daemon 才能取得 Vault 密钥并开始捕获。
- 锁屏、睡眠、退出登录或用户切换时，暂停捕获，结束正在写入的事务，并尽快从内存清理密钥、解密图片、音频缓冲、模型上下文和临时明文。 **[未实现 → 密钥这一半没有做；`Vault` 持有的派生密钥活满进程生命周期，`crates/afterray-store/src/lib.rs:770`]**
- 解密后的截图只进入有上限的内存缓存，不写入磁盘预览缓存。
- 如确实需要落盘缓存，它必须和原 artifact 使用同等级加密，并进入统一删除范围。 **[已变更 → 摘要导出是明文落盘且在统一删除之外，`swift/AfterRayRecall/Sources/SummaryExportFileStore.swift:21`]**
- 崩溃恢复不得留下明文临时文件；写入使用临时密文文件、同步必要数据后原子 rename。

## 5. 删除与恢复

删除分成两个可观察状态：

1. 逻辑删除：立即从 Timeline、搜索索引和 Agent 查询结果中移除，同时删除或撤销对应 wrapped DEK。
2. 物理回收：清理独立 artifact、数据库记录、WAL、派生摘要、导出文件和其他副本。 **[未实现 → 导出文件在 vault 之外，`Vault::delete_history` 触及不到，`crates/afterray-store/src/lib.rs:3269`]**

独立 artifact 不需要 pack compaction。数据库仍需验证 WAL、free page 和 vacuum 策略，产品不能在物理回收完成前宣称字节已经彻底清除。 **[未实现 → 代码里没有任何 VACUUM，只有 `PRAGMA secure_delete = ON`，`crates/afterray-store/src/lib.rs:6242`]**

`ThisDeviceOnly` 密钥意味着：设备或 Keychain 条目损坏后，Vault 默认不可恢复。这是安全性与可恢复性的明确取舍。正式发布前应提供由用户主动创建的恢复包：使用用户口令派生的密钥包裹 Vault 恢复密钥；AfterRay 不持有服务器端后门或托管副本。 **[未实现 → workspace 内没有任何口令 KDF；`Vault::open` fail-closed，`crates/afterray-store/src/lib.rs:1003`]**

## 6. 威胁边界

这套结构主要防护：

- 磁盘被离线读取。
- Vault 目录被单独复制或通过未加密备份泄露。
- 用户离开电脑后，AfterRay 仍保留可直接读取的明文历史。
- 只拿到 artifact 文件但没有 Keychain 密钥的攻击者。

它不承诺防护：

- 已控制当前登录会话、可读取 AfterRay 进程内存的恶意软件。
- 用户主动把解密内容复制、截图或发送给外部服务。
- macOS、固件或硬件信任根已经失陷的设备。

因此应用级加密不能替代 App 排除、暂停捕获、权限最小化、外部 Agent scope、导出确认和安全更新。

## 7. 性能原则

不能为了修复 CPU 或滚动延迟而删除静态加密。已知的高 CPU 问题来自周期性全量数据库查询，而不是 artifact 加密。

性能优化按以下顺序进行：

1. 避免全量读取，使用增量 Timeline 查询和正确索引。
2. 当前帧优先，取消已经过期的解密与图片解码任务。
3. 使用有界的密文缓存和解密图片内存缓存。
4. 记录数据库查询、磁盘读取、AEAD、IPC、JPEG 解码和呈现各阶段耗时，再优化真实瓶颈。

不采用“为了性能把截图明文落盘”或“把整个 Vault 一次性解密到临时目录”的方案。

## 8. V0 与正式版出口

### 8.1 当前实现状态（2026-08-13）

已完成：

- macOS Data Protection Keychain 保存主密钥，使用 `AccessibleWhenUnlockedThisDeviceOnly` 且禁止同步；旧 Keychain item 会安全迁移。 **[已变更 → Developer ID 构建实际落在文件 keychain（`aku` + 关闭同步），`crates/afterray-store/src/lib.rs:426`]**
- 数据库与 artifact wrapping key 使用独立的 BLAKE3 derive-key context。
- SQLCipher 开启 memory security、secure delete、内存 temp store 和 WAL。
- 每个 artifact 使用随机 DEK；密文文件只包含版本 header、data nonce 和 ciphertext，wrapped DEK 与 wrapping nonce 保存在 SQLCipher 中。
- artifact id、content type、格式版本和用途进入 AEAD authenticated data。 **[已变更 → AAD 是常量域字符串 + purpose + id + content_type，格式版本没有进去，`crates/afterray-store/src/lib.rs:6165`]**
- ARV0 artifact 与旧数据库 key 自动迁移；迁移采用新旧文件并存、数据库切换、最后删除旧文件的崩溃安全顺序。
- 私有目录为 `0700`，文件为 `0600`；artifact 写入经过 `fsync` 和原子 rename；启动时清理孤立密文、迁移残留与明文 capture staging。
- 已有 Vault 丢失 Keychain key 时 fail-closed，不会生成替代 key 覆盖恢复入口。
- 锁屏、睡眠和用户切换时停止录制，并清理 Timeline、搜索结果、音频、编码 artifact cache 和解码图片 cache；恢复活动会重新启动录制。
  **daemon 本身仍在运行**：主密钥留在进程内存里，socket 也仍可连接，因此锁屏后本机进程依然可以读到明文历史。真正卸载密钥、关闭 socket 的锁屏行为列在 8.2 的发布前要求里。
- daemon socket 位于 `0700` 目录内、自身为 `0600`，绑定前拒绝替换不属于自己的路径（非 socket、他人所有、或仍有 daemon 在监听），接受连接后校验对端 uid。
- OpenAI 兼容 API key 存在 Keychain（`dev.afterray.v0.secrets`），不再写进 `settings.json`；旧版本写下的明文 key 会在启动时迁移并从文件中抹去。`settings.json` 自身经临时文件原子写入并保持 `0600`。
- 远程 endpoint 只接受 `https`，或指向本机的 `http`（loopback）；HTTP 客户端不跟随 redirect，避免 API key 与检索到的历史被带去用户没有确认的主机。
- retention 先在 SQLCipher 事务中删除 wrapped DEK，再删除 artifact 文件，使内容立即不可通过正常 Vault 路径恢复。

尚未产品化的可选能力只有“用户主动创建的口令恢复包”。它需要单独确定口令强度、丢失提示和恢复 UI；AfterRay 不因此保留服务器端密钥。

### 8.2 交付要求

V0 必须满足：

- SQLCipher 保护结构化数据和索引。
- 每个截图、音频 artifact 独立使用 AEAD 加密。
- Vault key 存在 Keychain，Swift UI 不接触 key。
- 重启后使用同一 Vault 和同一 Keychain key 恢复历史。
- 运行目录和 staging 不遗留明文媒体。

对外发布前还必须满足：

- wrapped per-artifact DEK 和版本化 header。
- 锁屏、睡眠、用户切换时的暂停与内存清理经过验证。
- 锁屏、睡眠、用户切换时 daemon 卸载主密钥并停止响应读取请求，解锁后重新取钥匙。锁定状态由 daemon 自己向系统查询，不信任调用方声称的解锁。 **[未实现 → 只有 Swift app 检测锁屏并调用 `recordStop`，daemon 不查询任何东西，`apps/AfterRay/Sources/AfterRayApp.swift:176`]**
- 数据库 WAL、删除和崩溃恢复经过验证。
- 可选的用户持有恢复包与恢复流程。 **[未实现 → 见顶部状态块]**
- 安全评审覆盖随机数、nonce、key derivation、文件替换和 downgrade 风险。 **[未实现 → 没有留下任何评审产物]**

## 9. 明确不采用的方案

- 仅依赖 FileVault。
- 截图加密，但 OCR、Transcript 或搜索索引明文保存。
- Swift UI 直接打开 SQLCipher 或访问 Keychain key。
- 一个包含全部历史的巨大加密容器。
- 服务器保存主密钥或可绕过用户密钥的恢复后门。
