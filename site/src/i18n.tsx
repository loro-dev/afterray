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
    title: 'AfterRay — Total recall. Zero upload.',
    htmlLang: 'en',
  },
  nav: {
    features: 'The app',
    cli: 'CLI',
    privacy: 'Privacy',
    download: 'Download',
    skip: 'Skip to content',
  },
  hero: {
    eyebrow: 'Local-first computer history',
    titleA: ['Total ', { em: 'recall.' }] as Part[],
    titleB: [{ em: 'Zero' }, ' upload.'] as Part[],
    sub: 'It records what you see and hear on your Mac, then turns that into memory you can replay, search, and ask — on this machine only. No cloud, no account, no exceptions.',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'See what it remembers',
    scroll: 'Scroll',
    scrollHint: 'past the event horizon',
  },
  privacy: {
    statementA: ' bytes',
    statementB: 'leave your Mac.',
    sub: "Other computer-history tools ship your activity to the cloud — ChatGPT's Computer History sends your event files to OpenAI's servers just to summarize them. AfterRay refuses by architecture: captures, indexes, model inputs, and model outputs stay on this machine.",
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
  recall: {
    titleA: ['One hotkey,'] as Part[],
    titleB: ['the day ', { em: 'comes back.' }] as Part[],
    body: 'Press ⇧⌘Space in any app and an immersive overlay fills the screen: the pixels as they were, the audio as it sounded, captions replaying in place. Scrub the app-usage timeline, zoom from one second out to a month, and land on the exact moment.',
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
          quote: '"retention should be bounded by disk budget, not item count"',
        },
        { pos: 0.68, time: '3:07 PM', app: 'GitHub', title: 'PR #128 — retention discussion', c: '#8a7a70' },
        { pos: 0.92, time: '5:58 PM', app: 'Xcode', title: 'bench-codec — HEIF vs JPEG', c: '#ff5f4a' },
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
      searchHead: 'Search results',
      queries: [
        {
          keys: ['retention'],
          query: 'that retention ceiling discussion',
          results: [
            {
              src: 'OCR',
              time: 'Wed 3:15 PM',
              text: '…retention ceiling for non-favorites — AFTERRAY_MAX_UNSTARRED_MOMENTS…',
            },
            {
              src: 'Transcript',
              time: 'Wed 11:02 AM',
              text: '"retention should be bounded by disk budget, not item count" — Zoom',
            },
          ],
        },
        {
          keys: ['gop', 'encoder'],
          query: 'the GOP encoder memory spike',
          results: [
            {
              src: 'OCR',
              time: 'Thu 4:05 PM',
              text: '…bench-codec: HEIF 41ms vs JPEG 63ms per frame…',
            },
            {
              src: 'Transcript',
              time: 'Thu 5:20 PM',
              text: '"the spike is a duplicate copy in cold-still packing" — Zoom',
            },
          ],
        },
        {
          keys: ['vault', 'key'],
          query: 'vault key rotation notes',
          results: [
            {
              src: 'OCR',
              time: 'Tue 5:48 PM',
              text: '…todo: write the vault locking test first…',
            },
            {
              src: 'OCR',
              time: 'Tue 6:12 PM',
              text: '…docs/vault-encryption-design.md — key hierarchy…',
            },
          ],
        },
      ],
      askHead: 'Answer',
      presets: [
        {
          q: 'What did we decide about the disk budget?',
          a: 'Retention is bounded by disk budget, not item count — 10 and 20 GB tiers, and favorited moments never expire.',
          cites: ['3:15 PM · GitHub', '11:02 AM · Zoom'],
        },
        {
          q: 'When did the encoder memory spike get fixed?',
          a: 'Thursday evening — the duplicate copy in cold-still packing was removed; HEIF stayed the fast decode path.',
          cites: ['5:20 PM · Zoom', '6:47 PM · Xcode'],
        },
      ],
    },
  },
  cli: {
    titleA: ['Your history,'] as Part[],
    titleB: ['on the ', { em: 'command line.' }] as Part[],
    body: 'Your computer history, answered in JSON: the afterray CLI exposes search, moments, OCR evidence, activity spans, memories, and ask. Read-only by design — the vault key never leaves the daemon, and external tools never open the database.',
    points: [
      'afterray search / moment / evidence — the raw evidence, as JSON',
      'afterray ask — answers with moment citations',
      'afterray activity / memories — structured spans of your day',
    ],
    mock: [
      { cmd: 'afterray search "retention ceiling" --limit 2', out: '[ { "source": "transcript", "time": "Wed 11:02 AM",\n    "text": "…bounded by disk budget, not item count…", "score": 0.87 },\n  { "source": "ocr", "time": "Wed 3:15 PM",\n    "text": "…AFTERRAY_MAX_UNSTARRED_MOMENTS…", "score": 0.91 } ]' },
      { cmd: 'afterray ask "where did we land on retention?"', out: '{ "answer": "Disk-budget based, 10/20 GB tiers.",\n  "citations": [ "3:15 PM · GitHub", "11:02 AM · Zoom" ] }' },
      { cmd: 'afterray memories --from-ms … --to-ms …', out: '[ { "span": "2:00–3:00 PM",\n    "summary": "Closed out the disk chapter of the v1 spec" },\n  { "span": "3:00–4:00 PM",\n    "summary": "Debugged the GOP encoder memory spike" } ]' },
      { cmd: 'afterray activity --from-ms … --to-ms …', out: '[ { "app": "Xcode", "duration": "2h 14m" },\n  { "app": "Safari", "duration": "46m" },\n  { "app": "Zoom", "duration": "24m" } ]' },
    ],
  },
  agents: {
    titleA: ['One command,'] as Part[],
    titleB: ['any ', { em: 'agent.' }] as Part[],
    body: 'Install the AfterRay skill once. Claude Code, Codex, Hermes, and anything else that reads Agent Skills can then search and ask your local computer history — no MCP server, no credentials.',
    toolsLabel: 'Drops into the agents you already use',
    tools: ['Claude Code', 'Codex', 'Hermes', 'Cursor'],
    install: 'npx skills add loro-dev/afterray -g',
    installOut: 'installed afterray → Claude Code, Codex, Hermes',
    mock: {
      cmd: 'afterray ask "what did I decide about retention?"',
      reply: 'PR #128, Wednesday 3:15 PM — disk-budget based, 10/20 GB tiers.',
    },
    note: 'Read-only. The vault key stays in the daemon; agents never open the database.',
  },
  specs: {
    title: ['One pipeline, ', { em: 'entirely local.' }] as Part[],
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['Platform', 'macOS 15+ · Apple Silicon (M3 recommended)'],
      ['Storage', 'SQLCipher + XChaCha20-Poly1305, key in the Keychain'],
      ['Models', 'On-device ASR / Embedding / LLM, or your own Ollama'],
      ['Upload', 'None. No account, no telemetry, no cloud sync'],
    ],
  },
  final: {
    titleA: ['Give your Mac'] as Part[],
    titleB: ['a memory that ', { em: 'never forgets.' }] as Part[],
    sub: 'Free download · Runs locally · Your data stays yours',
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
    title: 'AfterRay — 记住一切，止于本机',
    htmlLang: 'zh-CN',
  },
  nav: {
    features: '应用',
    cli: 'CLI',
    privacy: '隐私',
    download: '下载',
    skip: '跳到正文',
  },
  hero: {
    eyebrow: '纯本地的 computer history',
    titleA: ['记住', { em: '一切。' }],
    titleB: ['止于', { em: '本机。' }],
    sub: '记录你在 Mac 上看到与听到的一切，整理成可回放、可检索、可追问的记忆。全程本机：无云端，无账号，无例外。',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: '看看它记得什么',
    scroll: 'Scroll',
    scrollHint: '越过事件视界',
  },
  privacy: {
    statementA: ' 字节',
    statementB: '离开你的 Mac。',
    sub: '别的 computer history 要把你的活动事件上传到云端才能总结——ChatGPT 的 Computer History 也得先把事件文件发到 OpenAI 的服务器。AfterRay 从架构上拒绝这件事：数据、索引、模型输入、模型输出，全程留在本机。',
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
  recall: {
    titleA: ['按一下 ⇧⌘Space，'],
    titleB: ['这一天就', { em: '回来了。' }],
    body: '在任意 App 里按下全局快捷键，沉浸式浮层铺满屏幕：当时的画面、当时的声音，字幕原地回放。拖动 App 使用时长的时间线，从一秒连续缩放到一个月，落回确切的那一刻。',
    mock: {
      status: '录制中',
      searchHint: '搜索你的一天 — Tab 打开 AI 对话',
      date: '8 月 14 日 周五',
      hint: '拖动缩放 · 滑动穿梭 · Esc 关闭',
      segments: [
        { app: 'Xcode', from: 0, to: 0.14, dur: '1h 15m', c: '#ff5f4a' },
        { app: 'Safari', from: 0.14, to: 0.3, dur: '1h 26m', c: '#e58a4d' },
        { app: 'Notes', from: 0.3, to: 0.42, dur: '1h 05m', c: '#c9a05a' },
        { app: 'Zoom', from: 0.42, to: 0.68, dur: '2h 20m', c: '#a96b60' },
        { app: 'GitHub', from: 0.68, to: 0.84, dur: '1h 26m', c: '#8a7a70' },
        { app: 'Xcode', from: 0.84, to: 1, dur: '1h 26m', c: '#ff5f4a' },
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
          quote: '「保留策略这块我们按磁盘上限来，不按条数」',
        },
        { pos: 0.68, time: '15:07', app: 'GitHub', title: 'PR #128 — retention 讨论', c: '#8a7a70' },
        { pos: 0.92, time: '17:58', app: 'Xcode', title: 'bench-codec — HEIF vs JPEG', c: '#ff5f4a' },
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
      searchHead: '搜索结果',
      queries: [
        {
          keys: ['retention'],
          query: 'retention 上限那次讨论',
          results: [
            {
              src: 'OCR',
              time: '周三 15:15',
              text: '…retention ceiling for non-favorites — AFTERRAY_MAX_UNSTARRED_MOMENTS…',
            },
            {
              src: '转写',
              time: '周三 11:02',
              text: '「保留策略这块我们按磁盘上限来，不按条数」—— Zoom',
            },
          ],
        },
        {
          keys: ['gop', '编码'],
          query: 'GOP 编码的内存峰值',
          results: [
            {
              src: 'OCR',
              time: '周四 16:05',
              text: '…bench-codec：HEIF 41ms vs JPEG 63ms 每帧…',
            },
            {
              src: '转写',
              time: '周四 17:20',
              text: '「峰值是 cold-still 打包里的重复拷贝」—— Zoom',
            },
          ],
        },
        {
          keys: ['vault', '密钥'],
          query: 'vault 密钥轮换的笔记',
          results: [
            {
              src: 'OCR',
              time: '周二 17:48',
              text: '…todo：先写 vault 锁定测试…',
            },
            {
              src: 'OCR',
              time: '周二 18:12',
              text: '…docs/vault-encryption-design.md — key hierarchy…',
            },
          ],
        },
      ],
      askHead: '回答',
      presets: [
        {
          q: '磁盘预算那次到底定了什么？',
          a: '保留策略按磁盘上限而不是条数——10/20GB 两档，收藏的时刻永不过期。',
          cites: ['15:15 · GitHub', '11:02 · Zoom'],
        },
        {
          q: '编码器内存峰值什么时候修好的？',
          a: '周四傍晚——去掉了 cold-still 打包里的重复拷贝，HEIF 仍是快速解码路径。',
          cites: ['17:20 · Zoom', '18:47 · Xcode'],
        },
      ],
    },
  },
  cli: {
    titleA: ['你的历史，'],
    titleB: ['一条', { em: '命令' }, '即达。'],
    body: '你的 computer history，用 JSON 回答：afterray CLI 提供检索、时刻详情、OCR 证据、活动片段、记忆与问答。设计上只读——Vault 密钥永远不离开守护进程，外部工具永远碰不到数据库。',
    points: [
      'afterray search / moment / evidence — 原始证据，JSON 输出',
      'afterray ask — 带时刻引用的回答',
      'afterray activity / memories — 结构化的日常片段',
    ],
    mock: [
      { cmd: 'afterray search "retention ceiling" --limit 2', out: '[ { "source": "transcript", "time": "周三 11:02",\n    "text": "…按磁盘上限来，不按条数…", "score": 0.87 },\n  { "source": "ocr", "time": "周三 15:15",\n    "text": "…AFTERRAY_MAX_UNSTARRED_MOMENTS…", "score": 0.91 } ]' },
      { cmd: 'afterray ask "retention 最后怎么定的？"', out: '{ "answer": "按磁盘预算，10/20GB 两档。",\n  "citations": [ "15:15 · GitHub", "11:02 · Zoom" ] }' },
      { cmd: 'afterray memories --from-ms … --to-ms …', out: '[ { "span": "14:00–15:00",\n    "summary": "收尾 v1 spec 的磁盘章节" },\n  { "span": "15:00–16:00",\n    "summary": "调试 GOP 编码的内存峰值" } ]' },
      { cmd: 'afterray activity --from-ms … --to-ms …', out: '[ { "app": "Xcode", "duration": "2h 14m" },\n  { "app": "Safari", "duration": "46m" },\n  { "app": "Zoom", "duration": "24m" } ]' },
    ],
  },
  agents: {
    titleA: ['一条命令，'],
    titleB: ['任意 ', { em: 'Agent。' }],
    body: '用 npx skills 装一次 AfterRay skill。Claude Code、Codex、Hermes，以及任何能读 Agent Skills 的工具，就能检索、追问你本机的 computer history——不用配 MCP，也不用交凭据。',
    toolsLabel: '装进你已经在用的 Agent',
    tools: ['Claude Code', 'Codex', 'Hermes', 'Cursor'],
    install: 'npx skills add loro-dev/afterray -g',
    installOut: 'installed afterray → Claude Code, Codex, Hermes',
    mock: {
      cmd: 'afterray ask "retention 最后怎么定的？"',
      reply: 'PR #128，周三 15:15 —— 按磁盘预算，10/20GB 两档。',
    },
    note: '只读。Vault 密钥留在守护进程里，Agent 碰不到数据库。',
  },
  specs: {
    title: ['一条', { em: '全程本地' }, '的流水线'],
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['平台', 'macOS 15+ · Apple Silicon（推荐 M3）'],
      ['存储', 'SQLCipher + XChaCha20-Poly1305，密钥存于 Keychain'],
      ['模型', '本机 ASR / Embedding / LLM，或你自己的 Ollama'],
      ['上传', '无。没有账号，没有遥测，没有云端同步'],
    ],
  },
  final: {
    titleA: ['让你的 Mac'],
    titleB: ['拥有', { em: '不会遗忘' }, '的记忆。'],
    sub: '免费下载 · 本地运行 · 你的数据永远只是你的',
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
