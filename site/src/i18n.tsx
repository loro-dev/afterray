import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react'

export type Lang = 'en' | 'zh'
export type Part = string | { em: string }

/** Every locale the switcher offers, labelled in its own language.
 *  Adding one means adding an entry here plus a `copy` block. */
export const LANGS: { code: Lang; label: string }[] = [
  { code: 'en', label: 'English' },
  { code: 'zh', label: '中文' },
]

const en = {
  meta: {
    title: 'AfterRay — Remember everything you see and hear on your Mac.',
    htmlLang: 'en',
  },
  nav: {
    language: 'Language',
    skip: 'Skip to content',
  },
  hero: {
    eyebrow: 'Local-first computer history',
    titleA: ['Remember'] as Part[],
    titleB: [{ em: 'everything.' }] as Part[],
    sub: 'AfterRay records your screen and audio all day — so you and your agent can find anything you saw or heard.',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'See what it remembers',
    facts: ['macOS 15+', 'Exclude apps and sites', 'Pause or delete anytime', 'Nothing leaves this Mac'],
  },
  jtbd: [
    {
      title: 'Pick up where you dropped it',
      body: 'Ask it to finish the migration you left half-done on Tuesday. It can see which files you touched, and when.',
    },
    {
      title: 'Answer from what happened',
      body: '“What did we decide about retention?” comes back with the moment it came from, not a guess.',
    },
    {
      title: 'Draft from what you did',
      body: 'The standup note, the PR description, the handoff — written from the week, not from memory.',
    },
  ],
  recall: {
    body: '⇧⌘Space from any app. Drag the timeline back to any moment.',
    mock: {
      status: 'Recording',
      searchHint: 'Search your day — Tab for AI chat',
      date: 'Friday, Aug 14',
      hint: 'Drag to zoom · Swipe to travel · Esc to close',
      heardLabel: 'Heard',
      openLabel: 'Open',
      // speech only exists where there was a call, so every line sits inside
      // one of the Zoom spans above — the panel appears and vanishes with them
      transcript: [
        { pos: 0.35, time: '12:09 PM', who: 'Alex', text: 'The timeline zoom has to feel like a camera, not a scrollbar.' },
        { pos: 0.39, time: '12:30 PM', who: 'Jo', text: 'Can we keep the playhead fixed and move the track underneath?' },
        { pos: 0.42, time: '12:46 PM', who: 'You', text: 'Yes — that is the part that makes it feel like a camera.' },
        { pos: 0.46, time: '1:08 PM', who: 'Alex', text: 'Then scrubbing only needs the poster frame. Settle can come after.' },
        { pos: 0.755, time: '3:47 PM', who: 'Chen', text: 'The spike is a duplicate copy in cold-still packing.' },
        { pos: 0.775, time: '3:58 PM', who: 'Alex', text: 'Favorites never expire. Everything else stays bounded.' },
        { pos: 0.79, time: '4:06 PM', who: 'You', text: 'Bench says HEIF forty-one milliseconds, JPEG sixty-three.' },
      ],
      segments: [
        { app: 'Xcode', from: 0, to: 0.08, dur: '43m', c: '#ff5f4a' },
        { app: 'Slack', from: 0.08, to: 0.11, dur: '16m', c: '#b8576b' },
        { app: 'Safari', from: 0.11, to: 0.2, dur: '49m', c: '#e58a4d' },
        { app: 'Xcode', from: 0.2, to: 0.26, dur: '32m', c: '#ff5f4a' },
        { app: 'Notes', from: 0.26, to: 0.32, dur: '32m', c: '#c9a05a' },
        { app: 'Zoom', from: 0.32, to: 0.5, dur: '1h 37m', c: '#a96b60' },
        { app: 'Slack', from: 0.5, to: 0.54, dur: '22m', c: '#b8576b' },
        { app: 'Safari', from: 0.54, to: 0.62, dur: '43m', c: '#e58a4d' },
        { app: 'GitHub', from: 0.62, to: 0.74, dur: '1h 5m', c: '#8a7a70' },
        { app: 'Zoom', from: 0.74, to: 0.8, dur: '32m', c: '#a96b60' },
        { app: 'Xcode', from: 0.8, to: 0.93, dur: '1h 10m', c: '#ff5f4a' },
        { app: 'Notes', from: 0.93, to: 1, dur: '38m', c: '#c9a05a' },
      ],
      records: [
        { pos: 0.04, time: '9:24 AM', app: 'Xcode', title: 'afterrayd — agent.rs', c: '#ff5f4a' },
        { pos: 0.15, time: '10:21 AM', app: 'Safari', title: 'hot-stills-cold-gop.md', c: '#e58a4d', url: 'docs.afterray.dev/hot-stills-cold-gop' },
        { pos: 0.29, time: '11:37 AM', app: 'Notes', title: 'retention ideas', c: '#c9a05a' },
        { pos: 0.4, time: '12:36 PM', app: 'Zoom', title: 'design review — recording', c: '#a96b60' },
        { pos: 0.77, time: '3:56 PM', app: 'Zoom', title: 'design review — recording', c: '#a96b60' },
        { pos: 0.68, time: '3:07 PM', app: 'GitHub', title: 'PR #128 — retention discussion', c: '#8a7a70' },
        { pos: 0.92, time: '5:58 PM', app: 'Xcode', title: 'bench-codec — HEIF vs JPEG', c: '#ff5f4a' },
      ],
    },
  },
  memories: {
    titleA: ['You did a lot today.'] as Part[],
    titleB: ["Here's ", { em: 'what it was.' }] as Part[],
    body: 'AfterRay writes your day back to you in half-hour slots. The model runs here, and it is told never to invent a file, a URL, or a task it did not see.',
    points: [
      'Written as you go, without being asked',
      'Every line opens to the moment behind it',
    ],
    mock: {
      head: 'Friday, Aug 14',
      label: 'Memories',
      rows: [
        {
          span: '9:00–9:30',
          summary: 'Traced the agent loop in afterrayd, then started a note on retention.',
          apps: 'Xcode · Notes',
        },
        {
          span: '10:30–11:00',
          summary: 'Read hot-stills-cold-gop.md and compared HEIF against the JPEG decode path.',
          apps: 'Safari · Xcode',
        },
        {
          span: '2:00–2:30 PM',
          summary: 'Closed out the disk chapter of the v1 spec.',
          apps: 'Notes · GitHub',
        },
        {
          span: '3:30–4:00 PM',
          summary: 'Debugged the GOP encoder memory spike on a call, then filed PR #128.',
          apps: 'Zoom · GitHub',
        },
      ],
    },
  },
  searchAsk: {
    titleA: ['Half-remember it.'] as Part[],
    titleB: ['Find it ', { em: 'exactly.' }] as Part[],
    body: 'Forget the filename and the app. A half-remembered phrase is enough — or just ask.',
    points: [
      'Joint search across OCR text and transcripts',
      'Semantic search: by meaning, not just keywords',
      'Ask answers with citations to the original moments',
    ],
    mock: {
      tryLabel: 'Try one',
      searchHead: 'You half-remember',
      foundHead: 'It finds',
      askHead: 'Or just ask',
      screenLabel: 'On screen',
      heardLabel: 'Heard',
      replay: 'Replay',
      scenarios: [
        {
          chip: 'Keeping favorites',
          keys: ['favorite', 'favourite', 'keep', 'star', 'retention'],
          query: 'that thing about keeping favorites',
          results: [
            {
              src: 'heard',
              app: 'Zoom',
              time: 'Wed 11:02 AM',
              c: '#a96b60',
              text: 'favorites never expire — everything else stays bounded',
              match: 'favorites never expire',
            },
            {
              src: 'screen',
              app: 'GitHub',
              time: 'Wed 3:15 PM',
              c: '#8a7a70',
              text: 'PR #128 — the storage budget applies to unstarred moments only',
              match: 'storage budget',
            },
          ],
          answer:
            'Anything you star is exempt and never expires. Everything else lives inside the storage budget you set.',
        },
        {
          chip: 'That memory spike',
          keys: ['spike', 'memory', 'encoder', 'gop'],
          query: 'the memory spike someone mentioned',
          results: [
            {
              src: 'heard',
              app: 'Zoom',
              time: 'Thu 5:20 PM',
              c: '#a96b60',
              text: 'the spike is a duplicate copy in cold-still packing',
              match: 'duplicate copy',
            },
            {
              src: 'screen',
              app: 'Xcode',
              time: 'Thu 4:05 PM',
              c: '#ff5f4a',
              text: 'bench-codec — HEIF 41ms vs JPEG 63ms per frame',
              match: 'bench-codec',
            },
          ],
          answer:
            'A duplicate copy in cold-still packing. Spotted Thursday afternoon, removed the same evening.',
        },
        {
          chip: 'The vault key note',
          keys: ['vault', 'key', 'note', 'wrote'],
          query: 'where I wrote down the vault key idea',
          results: [
            {
              src: 'screen',
              app: 'Notes',
              time: 'Tue 5:48 PM',
              c: '#c9a05a',
              text: 'todo: write the vault locking test first',
              match: 'vault locking',
            },
            {
              src: 'screen',
              app: 'Safari',
              time: 'Tue 6:12 PM',
              c: '#e58a4d',
              text: 'docs/vault-encryption-design.md — key hierarchy',
              match: 'key hierarchy',
            },
          ],
          answer:
            'In Notes on Tuesday evening, while the vault-encryption design doc was open in Safari.',
        },
      ],
    },
  },
  agents: {
    titleA: ['One command,'] as Part[],
    titleB: ['any ', { em: 'agent.' }] as Part[],
    body: 'Install the skill once. Claude Code, Codex, and anything else that reads Agent Skills can then query your history — no MCP server, no credentials.',
    toolsLabel: 'Drops into the agents you already use',
    tools: ['Claude Code', 'Codex', 'Hermes', 'Cursor'],
    install: 'npx skills add loro-dev/afterray -g',
    installOut: 'installed afterray → Claude Code, Codex, Hermes',
    note: 'Read-only. The vault key never leaves the daemon.',
    jailTitle: 'The assistant inside AfterRay is caged.',
    jailBody:
      'It reads your vault and answers, and it has no second mode. No HTTP client, '
      + 'because the crate the loop lives in depends on nothing that could make a '
      + 'request. No shell and no filesystem, because a build rule fails if a tool so '
      + 'much as names them.',
    jailProof: 'Three dependencies and one build rule. Both are readable in a minute.',
    jailProofHref:
      'https://github.com/loro-dev/afterray/blob/main/docs/harness-threat-model.md',
    jailCaveat:
      'Point it at a local model and none of this leaves the Mac. Point it at a cloud '
      + 'endpoint and the prompt goes there — that is what choosing one means.',
    mock: [
      { cmd: 'afterray search "keeping favorites" --limit 1', out: '[ { "source": "transcript", "time": "Wed 11:02 AM",\n    "text": "favorites never expire…" } ]' },
      { cmd: 'afterray ask "where did we land on retention?"', out: '{ "answer": "Stars are exempt; the rest fits the storage budget.",\n  "citations": [ "Wed 3:15 PM · GitHub" ] }' },
      { cmd: 'afterray memories --from-ms … --to-ms …', out: '[ { "span": "3:00–4:00 PM",\n    "summary": "Debugged the GOP encoder memory spike" } ]' },
      { cmd: 'afterray activity --from-ms … --to-ms …', out: '[ { "app": "Xcode", "duration": "2h 14m" },\n  { "app": "Zoom", "duration": "24m" } ]' },
    ],
  },
  privacy: {
    statementA: ' bytes',
    statementB: 'leave your Mac.',
    pillars: [
      {
        title: 'Captured locally',
        body: 'Screen, system audio, microphone, and Accessibility semantics are written to an encrypted vault on your Mac.',
      },
      {
        title: 'Indexed locally',
        body: 'OCR, speech recognition, and semantic embeddings run on-device. Raw content and vectors never leave it.',
      },
      {
        title: 'Modeled locally',
        body: 'Summaries and answers come from a model running on your machine — a bundled MLX pack or your own Ollama.',
      },
      {
        title: 'Encrypted at rest',
        body: 'SQLCipher + XChaCha20-Poly1305 encrypt every record. The key lives in the macOS Keychain.',
      },
    ],
  },
  specs: {
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['Platform', 'macOS 15+ · Apple Silicon (M3 recommended)'],
      ['Storage', 'SQLCipher + XChaCha20-Poly1305, key in the Keychain'],
      ['On disk', 'Older captures repack to closed-GOP AV1 — 7–10% of the original JPEG'],
      ['Retention', 'A storage budget you set, 100 GB by default — oldest unstarred go first, favorites never expire'],
      ['Models', 'On-device ASR, embeddings, and LLM — or your own Ollama or OpenAI-compatible endpoint'],
      ['Upload', 'No account, no telemetry, no cloud sync — nothing leaves unless you point it at a remote model'],
    ],
  },
  final: {
    titleA: ['Give your Mac'] as Part[],
    titleB: ['a memory that ', { em: 'never forgets.' }] as Part[],
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'GitHub',
  },
  footer: {
    tagline: 'A ray that persists after the day is gone.',
    rights: '© 2026',
  },
}

export type Copy = typeof en

const zh: Copy = {
  meta: {
    title: 'AfterRay — 记住你在 Mac 上看见、听见的一切。',
    htmlLang: 'zh-CN',
  },
  nav: {
    language: '语言',
    skip: '跳到正文',
  },
  hero: {
    eyebrow: '本地优先的电脑历史',
    titleA: ['记住'],
    titleB: [{ em: '一切。' }],
    sub: 'AfterRay 全天记录你的屏幕和声音——你和你的 agent 都能找回所见所闻。',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: '看看它记得什么',
    facts: ['macOS 15+', '可排除 App 和网站', '随时暂停或删除', '不出这台 Mac'],
  },
  jtbd: [
    {
      title: '从放下处接着做',
      body: '让它接着做周二没做完的迁移。你动过哪些文件、何时动的，它都看得见。',
    },
    {
      title: '按已发生的事作答',
      body: '「保留怎么定的？」回来的是出处，不是猜测。',
    },
    {
      title: '按你做过的事起草',
      body: '站会记录、PR 描述、交接——按这一周写，不靠回忆。',
    },
  ],
  recall: {
    body: '任意 App 里按 ⇧⌘Space。拖动时间线回到任意时刻。',
    mock: {
      status: '录制中',
      searchHint: '搜索你的一天 — Tab 打开 AI 对话',
      date: '8 月 14 日 周五',
      hint: '拖动缩放 · 滑动穿梭 · Esc 关闭',
      heardLabel: '听到',
      openLabel: '打开',
      transcript: [
        { pos: 0.35, time: '12:09', who: 'Alex', text: '时间线缩放要像相机，不像滚动条。' },
        { pos: 0.39, time: '12:30', who: 'Jo', text: '能不能把播放头固定住，让轨道在下面滑？' },
        { pos: 0.42, time: '12:46', who: '你', text: '对——就是这一点让它像相机。' },
        { pos: 0.46, time: '13:08', who: 'Alex', text: '那拖动时只要海报帧。落点可以后补。' },
        { pos: 0.755, time: '15:47', who: 'Chen', text: '峰值是 cold-still 打包里的重复拷贝。' },
        { pos: 0.775, time: '15:58', who: 'Alex', text: '收藏永不过期。其余的保持限额。' },
        { pos: 0.79, time: '16:06', who: '你', text: 'bench 说 HEIF 41 毫秒，JPEG 63 毫秒。' },
      ],
      segments: [
        { app: 'Xcode', from: 0, to: 0.08, dur: '43m', c: '#ff5f4a' },
        { app: 'Slack', from: 0.08, to: 0.11, dur: '16m', c: '#b8576b' },
        { app: 'Safari', from: 0.11, to: 0.2, dur: '49m', c: '#e58a4d' },
        { app: 'Xcode', from: 0.2, to: 0.26, dur: '32m', c: '#ff5f4a' },
        { app: 'Notes', from: 0.26, to: 0.32, dur: '32m', c: '#c9a05a' },
        { app: 'Zoom', from: 0.32, to: 0.5, dur: '1h 37m', c: '#a96b60' },
        { app: 'Slack', from: 0.5, to: 0.54, dur: '22m', c: '#b8576b' },
        { app: 'Safari', from: 0.54, to: 0.62, dur: '43m', c: '#e58a4d' },
        { app: 'GitHub', from: 0.62, to: 0.74, dur: '1h 5m', c: '#8a7a70' },
        { app: 'Zoom', from: 0.74, to: 0.8, dur: '32m', c: '#a96b60' },
        { app: 'Xcode', from: 0.8, to: 0.93, dur: '1h 10m', c: '#ff5f4a' },
        { app: 'Notes', from: 0.93, to: 1, dur: '38m', c: '#c9a05a' },
      ],
      records: [
        { pos: 0.04, time: '9:24', app: 'Xcode', title: 'afterrayd — agent.rs', c: '#ff5f4a' },
        { pos: 0.15, time: '10:21', app: 'Safari', title: 'hot-stills-cold-gop.md', c: '#e58a4d', url: 'docs.afterray.dev/hot-stills-cold-gop' },
        { pos: 0.29, time: '11:37', app: 'Notes', title: '保留点子', c: '#c9a05a' },
        { pos: 0.4, time: '12:36', app: 'Zoom', title: '设计评审 — 录音', c: '#a96b60' },
        { pos: 0.77, time: '15:56', app: 'Zoom', title: '设计评审 — 录音', c: '#a96b60' },
        { pos: 0.68, time: '15:07', app: 'GitHub', title: 'PR #128 — 保留讨论', c: '#8a7a70' },
        { pos: 0.92, time: '17:58', app: 'Xcode', title: 'bench-codec — HEIF vs JPEG', c: '#ff5f4a' },
      ],
    },
  },
  memories: {
    titleA: ['今天你做了很多。'],
    titleB: ['这就是', { em: '这一天。' }],
    body: 'AfterRay 按半小时把这一天写回给你。模型跑在本机，没见过的文件、链接、任务一律不编。',
    points: [
      '边走边写，不用你开口',
      '每一行都能打开背后那一刻',
    ],
    mock: {
      head: '8 月 14 日 周五',
      label: '记忆',
      rows: [
        {
          span: '9:00–9:30',
          summary: '顺着 afterrayd 的 agent 循环排查，随后开了篇保留笔记。',
          apps: 'Xcode · Notes',
        },
        {
          span: '10:30–11:00',
          summary: '读 hot-stills-cold-gop.md，对比 HEIF 与 JPEG 的解码路径。',
          apps: 'Safari · Xcode',
        },
        {
          span: '14:00–14:30',
          summary: '收尾 v1 spec 的磁盘章节。',
          apps: 'Notes · GitHub',
        },
        {
          span: '15:30–16:00',
          summary: '通话中调试 GOP 编码器的内存峰值，随后提了 PR #128。',
          apps: 'Zoom · GitHub',
        },
      ],
    },
  },
  searchAsk: {
    titleA: ['记得个大概。'],
    titleB: ['把它找', { em: '准。' }],
    body: '忘掉文件名和 App。记得只言片语就够——或者直接问。',
    points: [
      '跨 OCR 文本和转写联合检索',
      '语义搜索：按意思，不只按关键字',
      '问答附带来源时刻的引用',
    ],
    mock: {
      tryLabel: '试一个',
      searchHead: '你记得个大概',
      foundHead: '它找到了',
      askHead: '或者直接问',
      screenLabel: '屏幕上',
      heardLabel: '听到',
      replay: '回放',
      scenarios: [
        {
          chip: '保留收藏',
          keys: ['收藏', '保留', 'star'],
          query: '保留收藏那件事',
          results: [
            {
              src: 'heard',
              app: 'Zoom',
              time: '周三 11:02',
              c: '#a96b60',
              text: '收藏永不过期——其余的保持限额',
              match: '收藏永不过期',
            },
            {
              src: 'screen',
              app: 'GitHub',
              time: '周三 15:15',
              c: '#8a7a70',
              text: 'PR #128 —— 存储预算只作用于未收藏的时刻',
              match: '存储预算',
            },
          ],
          answer: '标了星的一律豁免、永不过期。其余的都在你设的存储预算里。',
        },
        {
          chip: '那个内存峰值',
          keys: ['峰值', '内存', '编码', 'gop'],
          query: '有人提过的那个内存峰值',
          results: [
            {
              src: 'heard',
              app: 'Zoom',
              time: '周四 17:20',
              c: '#a96b60',
              text: '峰值是 cold-still 打包里的重复拷贝',
              match: '重复拷贝',
            },
            {
              src: 'screen',
              app: 'Xcode',
              time: '周四 16:05',
              c: '#ff5f4a',
              text: 'bench-codec —— HEIF 41ms vs JPEG 63ms 每帧',
              match: 'bench-codec',
            },
          ],
          answer: 'cold-still 打包里的一次重复拷贝。周四下午发现，当晚去掉。',
        },
        {
          chip: 'vault 密钥那条笔记',
          keys: ['vault', '密钥', '笔记', '记'],
          query: '我把 vault 密钥那个想法记哪了',
          results: [
            {
              src: 'screen',
              app: 'Notes',
              time: '周二 17:48',
              c: '#c9a05a',
              text: 'todo：先写 vault 锁定测试',
              match: 'vault 锁定',
            },
            {
              src: 'screen',
              app: 'Safari',
              time: '周二 18:12',
              c: '#e58a4d',
              text: 'docs/vault-encryption-design.md —— key hierarchy',
              match: 'key hierarchy',
            },
          ],
          answer: '周二傍晚写在 Notes 里，当时 Safari 开着 vault 加密设计文档。',
        },
      ],
    },
  },
  agents: {
    titleA: ['一条命令，'],
    titleB: ['任意 ', { em: 'agent。' }],
    body: '装一次 skill。Claude Code、Codex 和任何能读 Agent Skills 的工具，都能查你的历史——不用 MCP，不用凭据。',
    toolsLabel: '接入你已经在用的 Agent',
    tools: ['Claude Code', 'Codex', 'Hermes', 'Cursor'],
    install: 'npx skills add loro-dev/afterray -g',
    installOut: 'installed afterray → Claude Code, Codex, Hermes',
    note: '只读。Vault 密钥永不离开守护进程。',
    jailTitle: 'AfterRay 内置的助手被关在笼子里。',
    jailBody:
      '它读你的 vault，然后回答，没有第二种模式。没有 HTTP 客户端——它运行的那个 '
      + 'crate 的依赖里就没有任何能发请求的东西。没有 shell、没有文件系统——工具的源码里'
      + '只要出现这些名字，构建就会失败。',
    jailProof: '三个依赖，一条构建规则。一分钟就能读完。',
    jailProofHref:
      'https://github.com/loro-dev/afterray/blob/main/docs/harness-threat-model.md',
    jailCaveat:
      '配本地模型，这些一个字节都不出这台 Mac。配云端接口，prompt 就会送过去——'
      + '选择云端模型，本来就是这个意思。',
    mock: [
      { cmd: 'afterray search "保留收藏" --limit 1', out: '[ { "source": "transcript", "time": "周三 11:02",\n    "text": "收藏永不过期…" } ]' },
      { cmd: 'afterray ask "保留怎么定的？"', out: '{ "answer": "标星豁免；其余的在存储预算内。",\n  "citations": [ "周三 15:15 · GitHub" ] }' },
      { cmd: 'afterray memories --from-ms … --to-ms …', out: '[ { "span": "15:00–16:00",\n    "summary": "调试 GOP 编码器的内存峰值" } ]' },
      { cmd: 'afterray activity --from-ms … --to-ms …', out: '[ { "app": "Xcode", "duration": "2h 14m" },\n  { "app": "Zoom", "duration": "24m" } ]' },
    ],
  },
  privacy: {
    statementA: ' 字节',
    statementB: '离开你的 Mac。',
    pillars: [
      {
        title: '捕获在本地',
        body: '屏幕、系统音频、麦克风与 Accessibility 语义，全部写入你 Mac 上的加密 Vault。',
      },
      {
        title: '索引在本地',
        body: 'OCR、语音识别与语义 embedding 在本机运行。原文与向量不出设备。',
      },
      {
        title: '模型在本地',
        body: '总结与问答来自本机运行的模型——内置 MLX 包，或你自己的 Ollama。',
      },
      {
        title: '静态加密',
        body: 'SQLCipher + XChaCha20-Poly1305 逐条加密。密钥存于 macOS Keychain。',
      },
    ],
  },
  specs: {
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['平台', 'macOS 15+ · Apple Silicon（推荐 M3）'],
      ['存储', 'SQLCipher + XChaCha20-Poly1305，密钥存于 Keychain'],
      ['磁盘', '较早的捕获会重打包成 closed-GOP AV1——原 JPEG 的 7–10%'],
      ['保留', '你自己设的存储预算，默认 100 GB——先清最早的非收藏，收藏永不过期'],
      ['模型', '本机 ASR / Embedding / LLM，或你自己的 Ollama、OpenAI 兼容接口'],
      ['上传', '没有账号，没有遥测，没有云同步——除非你指向远程模型，否则什么都不出去'],
    ],
  },
  final: {
    titleA: ['给你的 Mac'],
    titleB: ['一份', { em: '不会遗忘' }, '的记忆。'],
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: 'GitHub',
  },
  footer: {
    tagline: '日子走后仍在的那道光。',
    rights: '© 2026',
  },
}

export const copy: Record<Lang, Copy> = { en, zh }

const LangCtx = createContext<{ lang: Lang; setLang: (l: Lang) => void }>({
  lang: 'en',
  setLang: () => {},
})

const STORAGE_KEY = 'afterray-lang'

function detectLang(): Lang {
  try {
    const param = new URLSearchParams(window.location.search).get('lang')
    if (param === 'en' || param === 'zh') return param
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved === 'en' || saved === 'zh') return saved
  } catch {
    /* private mode etc. */
  }
  return navigator.language?.toLowerCase().startsWith('zh') ? 'zh' : 'en'
}

export function LangProvider({ children }: { children: ReactNode }) {
  // The prerendered HTML is English, so both sides must start there or the
  // trees disagree on hydration. The reader's language is picked up in an
  // effect, which never runs on the server.
  const [lang, setLangState] = useState<Lang>('en')

  useEffect(() => {
    setLangState(detectLang())
  }, [])

  useEffect(() => {
    document.documentElement.lang = copy[lang].meta.htmlLang
    document.title = copy[lang].meta.title
  }, [lang])

  // Persist only a deliberate choice. Writing on every change would let the
  // pre-detection default overwrite a language the reader already picked.
  const setLang = useCallback((next: Lang) => {
    setLangState(next)
    try {
      localStorage.setItem(STORAGE_KEY, next)
    } catch {
      /* private mode etc. */
    }
  }, [])

  return (
    <LangCtx.Provider value={{ lang, setLang }}>{children}</LangCtx.Provider>
  )
}

export function useLang() {
  return useContext(LangCtx)
}

export function useCopy(): Copy {
  return copy[useLang().lang]
}

/** Renders title part arrays, wrapping { em } segments in <em>. */
export function Rich({ parts }: { parts: Part[] }) {
  return (
    <>
      {parts.map((p, i) =>
        typeof p === 'string' ? (
          <span key={i}>{p}</span>
        ) : p.em ? (
          <em key={i}>{p.em}</em>
        ) : null,
      )}
    </>
  )
}
