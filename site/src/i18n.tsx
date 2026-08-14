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
  },
  hero: {
    eyebrow: 'AfterRay — The afterglow of your day',
    titleA: ['Total ', { em: 'recall.' }] as Part[],
    titleB: [{ em: 'Zero' }, ' upload.'] as Part[],
    sub: 'AfterRay records what you see and hear on your Mac, and turns it into memory you can replay, search, and build on — with AI that runs entirely on-device. No cloud. No account. No exceptions.',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'See what it remembers',
    scroll: 'Scroll',
    scrollHint: 'past the event horizon',
  },
  privacy: {
    statementA: ' bytes',
    statementB: 'leave your Mac.',
    sub: "Most AI memory products upload your life to someone else's server. AfterRay refuses by architecture: captures, indexes, model inputs, and model outputs stay on this machine.",
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
    body: 'Press ⇧⌘Space in any app and an immersive overlay fills the screen: the pixels as they were, the audio as it sounded. Scrub the app-usage timeline, zoom from one second out to a month, and land on the exact moment.',
    points: [
      'Full-screen stills with the sound of that moment',
      'App-usage timeline, zooming second → hour → day → month',
      'Transcript captions replay in place',
    ],
    mock: {
      status: 'Recording',
      search: 'Search your day',
      ask: 'Ask about your day',
      date: 'Friday, Aug 14',
      hint: 'Drag to zoom · Swipe to travel · Esc to close',
      moments: [
        {
          time: '10:15 AM',
          caption: '"the timeline zoom has to feel like a camera, not a scrollbar"',
          meta: '10:15 AM · Zoom',
          still: 'rgba(84, 120, 200, 0.10)',
        },
        {
          time: '2:32 PM',
          caption: '"retention should be bounded by disk budget, not item count"',
          meta: '2:32 PM · Zoom',
          still: 'rgba(255, 74, 61, 0.08)',
        },
        {
          time: '5:41 PM',
          caption: 'docs/afterray-v1-spec.md — editing',
          meta: '5:41 PM · Xcode',
          still: 'rgba(142, 91, 168, 0.10)',
        },
      ],
      segments: [
        { app: 'Xcode', dur: '2h 14m', w: 34, c: '#5478c8' },
        { app: 'Safari', dur: '46m', w: 17, c: '#4a90d9' },
        { app: 'Zoom', dur: '24m', w: 12, c: '#4a7ddb' },
        { app: 'Slack', dur: '18m', w: 10, c: '#8e5ba8' },
        { app: 'Notes', dur: '12m', w: 8, c: '#c8b45a' },
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
    body: 'Everything the overlay shows, the afterray CLI answers in JSON: search, moments, OCR evidence, activity spans, memories, and ask. Read-only by design — the vault key never leaves the daemon, and external tools never open the database.',
    points: [
      'afterray search / moment / evidence — the raw evidence, as JSON',
      'afterray ask — answers with moment citations',
      'afterray activity / memories — structured spans of your day',
    ],
    mock: [
      { cmd: 'afterray search "retention ceiling" --limit 2', out: '[ { "source": "transcript", "time": "Wed 11:02 AM",\n    "text": "…bounded by disk budget, not item count…", "score": 0.87 },\n  { "source": "ocr", "time": "Wed 3:15 PM",\n    "text": "…AFTERRAY_MAX_UNSTARRED_MOMENTS…", "score": 0.91 } ]' },
      { cmd: 'afterray ask "where did we land on retention?"', out: '{ "answer": "Disk-budget based, 10/20 GB tiers.",\n  "citations": [ "3:15 PM · GitHub", "11:02 AM · Zoom" ] }' },
    ],
  },
  agents: {
    titleA: ['Bring your own'] as Part[],
    titleB: [{ em: 'agent.' }] as Part[],
    body: 'One toggle (Settings → Advanced → CLI for agents) installs afterray into ~/.local/bin. From there, any tool that can run a shell command can query your encrypted vault — no MCP server to configure, no credentials to hand out.',
    toolsLabel: 'Works with anything that can exec a shell',
    tools: ['Claude Code', 'Codex', 'Kimi', 'Hermes', 'DeepSeek', 'ZCode', 'Cursor'],
    mock: {
      context: '# inside Claude Code',
      cmd: 'afterray ask "what did I decide about retention?"',
      reply: 'PR #128, Wednesday 3:15 PM — disk-budget based, 10/20 GB tiers. Replaying the meeting snippet…',
    },
    note: '* Read-only by design. The vault key stays in the daemon; agents never touch the database.',
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
  },
  hero: {
    eyebrow: 'AfterRay — 一天的余晖，不再消散',
    titleA: ['记住', { em: '一切。' }],
    titleB: ['止于', { em: '本机。' }],
    sub: 'AfterRay 持续记录你在 Mac 上看到与听到的一切，由完全在本机运行的 AI 整理成可回放、可检索、可沉淀的记忆。无云端，无账号，无例外。',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: '看看它记得什么',
    scroll: 'Scroll',
    scrollHint: '越过事件视界',
  },
  privacy: {
    statementA: ' 字节',
    statementB: '离开你的 Mac。',
    sub: '大多数「AI 记忆」产品把你的生活上传到别人的服务器。AfterRay 从架构上拒绝这件事：数据、索引、模型输入、模型输出，全程留在本机。',
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
    body: '在任意 App 里按下全局快捷键，沉浸式浮层铺满屏幕：当时的画面、当时的声音。拖动 App 使用时长的时间线，从一秒连续缩放到一个月，落回确切的那一刻。',
    points: [
      '全屏画面，配上那一刻的环境音',
      'App 使用时长时间线，秒 / 小时 / 天 / 月连续缩放',
      '语音转写字幕，原地回放',
    ],
    mock: {
      status: '录制中',
      search: '搜索你的一天',
      ask: '问问你的一天',
      time: '14:47:03',
      date: '8 月 14 日 周五',
      hint: '拖动缩放 · 滑动穿梭 · Esc 关闭',
      caption: '「保留策略这块我们按磁盘上限来，不按条数」',
      captionMeta: '14:32 · Zoom',
      segments: [
        { app: 'Xcode', dur: '2h 14m', w: 34, c: '#5478c8' },
        { app: 'Safari', dur: '46m', w: 17, c: '#4a90d9' },
        { app: 'Zoom', dur: '24m', w: 12, c: '#4a7ddb' },
        { app: 'Slack', dur: '18m', w: 10, c: '#8e5ba8' },
        { app: 'Notes', dur: '12m', w: 8, c: '#c8b45a' },
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
      askHead: '回答',
      question: '磁盘预算那次到底定了什么？',
      answer: '保留策略按磁盘上限而不是条数——10/20GB 两档，收藏的时刻永不过期。',
      citations: ['15:15 · GitHub', '11:02 · Zoom'],
    },
  },
  cli: {
    titleA: ['你的历史，'],
    titleB: ['一条', { em: '命令' }, '即达。'],
    body: '浮层里能看到的一切，afterray CLI 都能以 JSON 回答：检索、时刻详情、OCR 证据、活动片段、记忆、问答。设计上只读——Vault 密钥永远不离开守护进程，外部工具永远碰不到数据库。',
    points: [
      'afterray search / moment / evidence — 原始证据，JSON 输出',
      'afterray ask — 带时刻引用的回答',
      'afterray activity / memories — 结构化的日常片段',
    ],
    mock: [
      { cmd: 'afterray search "retention ceiling" --limit 2', out: '[ { "source": "transcript", "time": "周三 11:02",\n    "text": "…按磁盘上限来，不按条数…", "score": 0.87 },\n  { "source": "ocr", "time": "周三 15:15",\n    "text": "…AFTERRAY_MAX_UNSTARRED_MOMENTS…", "score": 0.91 } ]' },
      { cmd: 'afterray ask "retention 最后怎么定的？"', out: '{ "answer": "按磁盘预算，10/20GB 两档。",\n  "citations": [ "15:15 · GitHub", "11:02 · Zoom" ] }' },
    ],
  },
  agents: {
    titleA: ['带上你自己的'],
    titleB: [{ em: 'Agent。' }],
    body: '一个开关（设置 → 高级 → CLI for agents）就会把 afterray 装进 ~/.local/bin。从此任何能执行 shell 命令的工具都能查询你的加密 Vault——不用配置 MCP server，也不用交出任何凭据。',
    toolsLabel: '任何能跑 shell 的 Agent 都能用',
    tools: ['Claude Code', 'Codex', 'Kimi', 'Hermes', 'DeepSeek', 'ZCode', 'Cursor'],
    mock: {
      context: '# 在 Claude Code 里',
      cmd: 'afterray ask "retention 最后怎么定的？"',
      reply: 'PR #128，周三 15:15 —— 按磁盘预算，10/20GB 两档。正在回放会议片段…',
    },
    note: '* 设计上只读。Vault 密钥留在守护进程里，Agent 永远接触不到数据库。',
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
