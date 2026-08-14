import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react'

export type Lang = 'en' | 'zh'
export type Part = string | { em: string }

const en = {
  meta: {
    title: 'AfterRay — Stop briefing your agent. It was there.',
    htmlLang: 'en',
  },
  nav: {
    features: 'Recall',
    cli: 'Agents',
    privacy: 'Privacy',
    download: 'Download',
    skip: 'Skip to content',
  },
  hero: {
    eyebrow: 'Local-first computer history',
    titleA: ['Stop briefing your agent.'] as Part[],
    titleB: ['It ', { em: 'was there.' }] as Part[],
    sub: 'AfterRay records your screen and audio all day, so Claude Code and Codex can look up what you read, watched, and were told — instead of waiting for you to explain it. All on this Mac.',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'See what it remembers',
    facts: ['macOS 15+ · Apple Silicon', 'No account, no telemetry', 'Nothing leaves this Mac'],
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
    titleA: ['One hotkey,'] as Part[],
    titleB: ['the day ', { em: 'comes back.' }] as Part[],
    body: 'Press ⇧⌘Space in any app. The pixels as they were, the audio as it sounded, captions replaying in place. Zoom the timeline from one second out to a month and land on the exact moment.',
    mock: {
      status: 'Recording',
      searchHint: 'Search your day — Tab for AI chat',
      date: 'Friday, Aug 14',
      hint: 'Drag to zoom · Swipe to travel · Esc to close',
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
        {
          pos: 0.4,
          time: '12:36 PM',
          app: 'Zoom',
          title: 'design review — recording',
          c: '#a96b60',
          quote: '"the timeline zoom has to feel like a camera, not a scrollbar"',
        },
        {
          pos: 0.77,
          time: '3:56 PM',
          app: 'Zoom',
          title: 'design review — recording',
          c: '#a96b60',
          quote: '"favorites never expire — everything else stays bounded"',
        },
        { pos: 0.68, time: '3:07 PM', app: 'GitHub', title: 'PR #128 — retention discussion', c: '#8a7a70' },
        { pos: 0.92, time: '5:58 PM', app: 'Xcode', title: 'bench-codec — HEIF vs JPEG', c: '#ff5f4a' },
      ],
    },
  },
  memories: {
    titleA: ['You did a lot today.'] as Part[],
    titleB: ["Here's ", { em: 'what it was.' }] as Part[],
    body: 'AfterRay folds your day into episodes and writes a line or two about each — what you were doing, and what it was for. The model runs on this Mac, and it is told never to invent a file, a URL, or a task it did not see.',
    points: [
      'Written on the hour, without being asked',
      'Every line opens to the moment behind it',
      'Grounded in what was actually on screen',
    ],
    mock: {
      head: 'Friday, Aug 14',
      label: 'Memories',
      rows: [
        {
          span: '9:00–10:00',
          summary: 'Traced the agent loop in afterrayd, then started a note on retention.',
          apps: 'Xcode · Notes',
        },
        {
          span: '10:00–11:00',
          summary: 'Read hot-stills-cold-gop.md and compared HEIF against the JPEG decode path.',
          apps: 'Safari · Xcode',
        },
        {
          span: '2:00–3:00 PM',
          summary: 'Closed out the disk chapter of the v1 spec.',
          apps: 'Notes · GitHub',
        },
        {
          span: '3:00–4:00 PM',
          summary: 'Debugged the GOP encoder memory spike on a call, then filed PR #128.',
          apps: 'Zoom · GitHub',
        },
      ],
    },
  },
  searchAsk: {
    titleA: ['Half-remember it.'] as Part[],
    titleB: ['Find it ', { em: 'exactly.' }] as Part[],
    body: 'Forget the filename, forget the app. Full-text search plus on-device semantic embeddings take any half-remembered phrase straight to the evidence — or just ask, and get an answer with citations you can tap to replay.',
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
              text: 'PR #128 — the retention ceiling applies to non-favorites only',
              match: 'retention ceiling',
            },
          ],
          answer:
            'Anything you star is exempt and never expires. Everything else is bounded by a retention ceiling.',
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
    mock: [
      { cmd: 'afterray search "keeping favorites" --limit 1', out: '[ { "source": "transcript", "time": "Wed 11:02 AM",\n    "text": "favorites never expire…" } ]' },
      { cmd: 'afterray ask "where did we land on retention?"', out: '{ "answer": "Stars are exempt; the rest is bounded.",\n  "citations": [ "Wed 3:15 PM · GitHub" ] }' },
      { cmd: 'afterray memories --from-ms … --to-ms …', out: '[ { "span": "3:00–4:00 PM",\n    "summary": "Debugged the GOP encoder memory spike" } ]' },
      { cmd: 'afterray activity --from-ms … --to-ms …', out: '[ { "app": "Xcode", "duration": "2h 14m" },\n  { "app": "Zoom", "duration": "24m" } ]' },
    ],
  },
  privacy: {
    statementA: ' bytes',
    statementB: 'leave your Mac.',
    sub: 'Screen, audio, and semantics are captured to an encrypted vault on this Mac. OCR, speech recognition, and embeddings run on-device. Summaries and answers come from a model running here. There is no account to create and no server to trust — the originals stay put, for as long as you keep them.',
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
        body: 'Summaries and answers come from a model running on your machine — a built-in GGUF or your own Ollama.',
      },
      {
        title: 'Encrypted at rest',
        body: 'SQLCipher + XChaCha20-Poly1305 encrypt every record. The key lives only in the macOS Keychain.',
      },
    ],
  },
  specs: {
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['Platform', 'macOS 15+ · Apple Silicon (M3 recommended)'],
      ['Storage', 'SQLCipher + XChaCha20-Poly1305, key in the Keychain'],
      ['On disk', 'Older captures repack to closed-GOP AV1 — measured at 7% of the original JPEG'],
      ['Retention', 'Non-favorites are bounded automatically; starred moments never expire'],
      ['Models', 'On-device ASR / Embedding / LLM, or your own Ollama'],
      ['Upload', 'None. No account, no telemetry, no cloud sync'],
    ],
  },
  final: {
    titleA: ['Give your Mac'] as Part[],
    titleB: ['a memory that ', { em: 'never forgets.' }] as Part[],
    sub: 'Runs on your Mac · No account · Your data stays yours',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'GitHub',
  },
  footer: {
    tagline: 'A ray that persists after the day is gone.',
    rights: '© 2026 · Local-first · Private by design',
  },
}

export type Copy = typeof en

const zh: Copy = {
  meta: {
    title: 'AfterRay — 别再交代背景了，你的 agent 当时就在',
    htmlLang: 'zh-CN',
  },
  nav: {
    features: '回放',
    cli: 'Agent',
    privacy: '隐私',
    download: '下载',
    skip: '跳到正文',
  },
  hero: {
    eyebrow: '纯本地的 computer history',
    titleA: ['别再交代背景了。'],
    titleB: ['你的 agent ', { em: '当时就在。' }],
    sub: 'AfterRay 整天记录你的屏幕和声音，Claude Code、Codex 可以直接查你读过什么、看过什么、别人跟你说过什么——不用你再解释一遍。全程在这台 Mac 上。',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: '看看它记得什么',
    facts: ['macOS 15+ · Apple Silicon', '无账号，无遥测', '数据不出这台 Mac'],
  },
  jtbd: [
    {
      title: '接着上次的活干',
      body: '让它继续周二没做完的那次迁移。你动过哪些文件、什么时候动的，它都看得到。',
    },
    {
      title: '答案来自真实发生过的事',
      body: '「retention 最后怎么定的？」回来的是出处，不是猜测。',
    },
    {
      title: '替你起草',
      body: '站会记录、PR 描述、交接文档——依据这一周真实发生的事，而不是你的记忆。',
    },
  ],
  recall: {
    titleA: ['按一下 ⇧⌘Space，'],
    titleB: ['这一天就', { em: '回来了。' }],
    body: '在任意 App 里按下 ⇧⌘Space。当时的画面、当时的声音，字幕原地回放。时间线从一秒连续缩放到一个月，落回确切的那一刻。',
    mock: {
      status: '录制中',
      searchHint: '搜索你的一天 — Tab 打开 AI 对话',
      date: '8 月 14 日 周五',
      hint: '拖动缩放 · 滑动穿梭 · Esc 关闭',
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
        { pos: 0.29, time: '11:37', app: 'Notes', title: 'retention 点子', c: '#c9a05a' },
        {
          pos: 0.4,
          time: '12:36',
          app: 'Zoom',
          title: '设计评审 — 录音',
          c: '#a96b60',
          quote: '「时间线缩放要做得像相机运镜，而不是滚动条」',
        },
        {
          pos: 0.77,
          time: '15:56',
          app: 'Zoom',
          title: '设计评审 — 录音',
          c: '#a96b60',
          quote: '「收藏的永不过期，其余的自动限额」',
        },
        { pos: 0.68, time: '15:07', app: 'GitHub', title: 'PR #128 — retention 讨论', c: '#8a7a70' },
        { pos: 0.92, time: '17:58', app: 'Xcode', title: 'bench-codec — HEIF vs JPEG', c: '#ff5f4a' },
      ],
    },
  },
  memories: {
    titleA: ['今天你做了很多，'],
    titleB: ['它都替你', { em: '记下来了。' }],
    body: 'AfterRay 把这一天折叠成一个个片段，为每段写下一两句——你当时在做什么、为了什么。模型跑在这台 Mac 上，并且被明确要求：没看见的文件、链接、任务，一个字都不能编。',
    points: [
      '整点自动写好，不用你开口',
      '每一行都能翻回背后那一刻',
      '只依据屏幕上真实出现过的内容',
    ],
    mock: {
      head: '8 月 14 日 周五',
      label: '记忆',
      rows: [
        {
          span: '9:00–10:00',
          summary: '通读 afterrayd 的 agent 循环，随后开了一篇 retention 的笔记。',
          apps: 'Xcode · Notes',
        },
        {
          span: '10:00–11:00',
          summary: '读 hot-stills-cold-gop.md，对比 HEIF 与 JPEG 的解码路径。',
          apps: 'Safari · Xcode',
        },
        {
          span: '14:00–15:00',
          summary: '收尾 v1 spec 的磁盘章节。',
          apps: 'Notes · GitHub',
        },
        {
          span: '15:00–16:00',
          summary: '在会上调试 GOP 编码的内存峰值，之后提了 PR #128。',
          apps: 'Zoom · GitHub',
        },
      ],
    },
  },
  searchAsk: {
    titleA: ['只记得大概，'],
    titleB: ['也能找回', { em: '确切。' }],
    body: '不记得文件名，不记得在哪个 App——没关系。全文检索叠加本地语义 embedding，用你记住的只言片语直接跳回证据；或者干脆问一句，拿到的答案自带可回放的时刻引用。',
    points: [
      'OCR 全文 + 语音转写联合检索',
      '语义搜索：按「意思」而不只是关键字',
      '问答的每条结论都附可回放的引用',
    ],
    mock: {
      tryLabel: '试一个',
      searchHead: '你只记得个大概',
      foundHead: '它找到了',
      askHead: '或者干脆问一句',
      screenLabel: '屏幕上',
      heardLabel: '听到的',
      replay: '回放',
      scenarios: [
        {
          chip: '收藏会不会被清掉',
          keys: ['收藏', '清', '保留', 'star'],
          query: '收藏的东西会不会被清掉来着',
          results: [
            {
              src: 'heard',
              app: 'Zoom',
              time: '周三 11:02',
              c: '#a96b60',
              text: '收藏的永不过期，其余的自动限额',
              match: '收藏的永不过期',
            },
            {
              src: 'screen',
              app: 'GitHub',
              time: '周三 15:15',
              c: '#8a7a70',
              text: 'PR #128 —— 保留上限只作用于非收藏的时刻',
              match: '保留上限',
            },
          ],
          answer: '标了收藏的永远豁免，不会过期；其余的按保留上限自动清理。',
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
          answer: 'cold-still 打包里的一次重复拷贝。周四下午发现，当晚就去掉了。',
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
          answer: '在周二傍晚的 Notes 里，当时 Safari 开着 vault 加密的设计文档。',
        },
      ],
    },
  },
  agents: {
    titleA: ['一条命令，'],
    titleB: ['任意 ', { em: 'Agent。' }],
    body: '装一次 skill。Claude Code、Codex，以及任何能读 Agent Skills 的工具，就能查你本机的历史——不用配 MCP，也不用交凭据。',
    toolsLabel: '装进你已经在用的 Agent',
    tools: ['Claude Code', 'Codex', 'Hermes', 'Cursor'],
    install: 'npx skills add loro-dev/afterray -g',
    installOut: 'installed afterray → Claude Code, Codex, Hermes',
    note: '只读。Vault 密钥永不离开守护进程。',
    mock: [
      { cmd: 'afterray search "收藏会不会被清掉" --limit 1', out: '[ { "source": "transcript", "time": "周三 11:02",\n    "text": "收藏的永不过期…" } ]' },
      { cmd: 'afterray ask "retention 最后怎么定的？"', out: '{ "answer": "收藏豁免，其余自动限额。",\n  "citations": [ "周三 15:15 · GitHub" ] }' },
      { cmd: 'afterray memories --from-ms … --to-ms …', out: '[ { "span": "15:00–16:00",\n    "summary": "调试 GOP 编码的内存峰值" } ]' },
      { cmd: 'afterray activity --from-ms … --to-ms …', out: '[ { "app": "Xcode", "duration": "2h 14m" },\n  { "app": "Zoom", "duration": "24m" } ]' },
    ],
  },
  privacy: {
    statementA: ' 字节',
    statementB: '离开你的 Mac。',
    sub: '屏幕、声音与语义，捕获进这台 Mac 上的加密 Vault。OCR、语音识别与 embedding 都在本机完成。总结和回答，来自跑在这里的模型。没有账号要注册，没有服务器需要信任——原件留在原地，你留多久它就在多久。',
    pillars: [
      {
        title: '捕获在本地',
        body: '屏幕、系统音频、麦克风与 Accessibility 语义，全部写入你 Mac 上的加密 Vault。',
      },
      {
        title: '索引在本地',
        body: 'OCR、语音识别与语义 embedding 都在本机完成，原文与向量不出设备。',
      },
      {
        title: '模型在本地',
        body: '总结与问答由本机运行的大模型完成——内置 GGUF 或你自己的 Ollama。',
      },
      {
        title: '存储已加密',
        body: 'SQLCipher + XChaCha20-Poly1305 逐条加密，密钥只存在于 macOS Keychain。',
      },
    ],
  },
  specs: {
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['平台', 'macOS 15+ · Apple Silicon（推荐 M3）'],
      ['存储', 'SQLCipher + XChaCha20-Poly1305，密钥存于 Keychain'],
      ['磁盘', '较早的画面后台重打包成 closed-GOP AV1——实测为原 JPEG 的 7%'],
      ['保留', '非收藏的时刻自动限额；标了收藏的永不过期'],
      ['模型', '本机 ASR / Embedding / LLM，或你自己的 Ollama'],
      ['上传', '无。没有账号，没有遥测，没有云端同步'],
    ],
  },
  final: {
    titleA: ['让你的 Mac'],
    titleB: ['拥有', { em: '不会遗忘' }, '的记忆。'],
    sub: '本机运行 · 无需账号 · 你的数据永远只是你的',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: 'GitHub',
  },
  footer: {
    tagline: 'A ray that persists after the day is gone.',
    rights: '© 2026 · 纯本地 · 纯隐私',
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
  const [lang, setLangState] = useState<Lang>(detectLang)

  useEffect(() => {
    document.documentElement.lang = copy[lang].meta.htmlLang
    document.title = copy[lang].meta.title
    try {
      localStorage.setItem(STORAGE_KEY, lang)
    } catch {
      /* ignore */
    }
  }, [lang])

  return (
    <LangCtx.Provider value={{ lang, setLang: setLangState }}>
      {children}
    </LangCtx.Provider>
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
