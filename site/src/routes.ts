import { LANGS, languageDefinition, type Lang } from './i18n'

export type PageKey = 'home' | 'privacy' | 'security' | 'download'

export type SiteRoute = {
  page: PageKey
  lang: Lang
  path: string
  title: string
  description: string
  htmlLang: string
  ogLocale: string
  imageAlt: string
  featureList?: string[]
}

type PageSeo = Record<PageKey, { title: string; description: string }>

const seoByLanguage: Record<Lang, PageSeo> = {
  en: {
    home: {
      title: 'Private, Searchable Memory for Mac — AfterRay',
      description: 'AfterRay is a private, local-first screen and audio history for Mac. Replay any moment, search what you saw or heard, and let your agent look it up.',
    },
    privacy: {
      title: 'Privacy — AfterRay',
      description: 'Learn what AfterRay records, where your Mac history is stored, which processing stays on device, and when data can leave your Mac.',
    },
    security: {
      title: 'Security — AfterRay',
      description: 'See how AfterRay encrypts its local vault, protects the vault key, limits agent access, and separates local models from remote endpoints.',
    },
    download: {
      title: 'Download AfterRay for macOS',
      description: 'Download the signed and notarized AfterRay app for Apple silicon Macs running macOS 15 or later, and review requirements before installing.',
    },
  },
  'zh-Hans': {
    home: {
      title: 'Mac 本地屏幕历史与可搜索记忆 — AfterRay',
      description: 'AfterRay 在 Mac 本地记录屏幕与音频，让你回放任意时刻、搜索看过或听过的内容，也让 AI agent 查询这些记忆。',
    },
    privacy: {
      title: '隐私说明 — AfterRay',
      description: '了解 AfterRay 会记录什么、Mac 历史保存在哪里、哪些处理在本机完成，以及什么情况下数据可能离开你的 Mac。',
    },
    security: {
      title: '安全设计 — AfterRay',
      description: '了解 AfterRay 如何加密本地 vault、保护密钥、限制 agent 访问，以及隔离本地模型和远程模型端点。',
    },
    download: {
      title: '下载 AfterRay macOS 版',
      description: '下载经过签名和公证的 AfterRay，适用于运行 macOS 15 或更高版本的 Apple 芯片 Mac；安装前可查看系统要求。',
    },
  },
  'zh-Hant': {
    home: {
      title: 'Mac 本機螢幕歷史與可搜尋記憶 — AfterRay',
      description: 'AfterRay 在 Mac 本機記錄螢幕與音訊，讓你重播任一時刻、搜尋看過或聽過的內容，也讓 AI agent 查詢這些記憶。',
    },
    privacy: {
      title: '隱私說明 — AfterRay',
      description: '瞭解 AfterRay 會記錄什麼、Mac 歷史儲存在哪裡、哪些處理在本機完成，以及資料何時可能離開你的 Mac。',
    },
    security: {
      title: '安全設計 — AfterRay',
      description: '瞭解 AfterRay 如何加密本機 vault、保護金鑰、限制 agent 存取，以及區隔本機模型與遠端模型端點。',
    },
    download: {
      title: '下載 AfterRay macOS 版',
      description: '下載已簽署並經 Apple 公證的 AfterRay，適用於 macOS 15 以上的 Apple 晶片 Mac；安裝前可查看系統需求。',
    },
  },
  ja: {
    home: {
      title: 'Macのプライベートかつ検索可能な記憶 — AfterRay',
      description: 'AfterRayは画面と音声の履歴をMac内に保存します。いつでも再生・検索でき、AIエージェントからも参照できます。',
    },
    privacy: {
      title: 'プライバシー — AfterRay',
      description: 'AfterRayが記録する内容、Mac内の保存場所、端末内で行う処理、データがMac外へ送られる条件を説明します。',
    },
    security: {
      title: 'セキュリティ — AfterRay',
      description: 'ローカルvaultの暗号化、鍵の保護、エージェントのアクセス制限、ローカルモデルとリモートモデルの境界を説明します。',
    },
    download: {
      title: 'AfterRayをmacOSにダウンロード',
      description: 'macOS 15以降のAppleシリコンMac向けに、署名・公証済みのAfterRayをダウンロードし、動作要件を確認できます。',
    },
  },
  ko: {
    home: {
      title: 'Mac을 위한 비공개 검색형 기억 — AfterRay',
      description: 'AfterRay는 화면과 오디오 기록을 Mac에 보관합니다. 원하는 순간을 재생하고 검색하거나 AI 에이전트가 찾아보게 할 수 있습니다.',
    },
    privacy: {
      title: '개인정보 보호 — AfterRay',
      description: 'AfterRay가 기록하는 정보, Mac 내 저장 위치, 기기에서 처리되는 항목, 데이터가 Mac을 벗어날 수 있는 경우를 설명합니다.',
    },
    security: {
      title: '보안 — AfterRay',
      description: '로컬 vault 암호화, 키 보호, 에이전트 접근 제한, 로컬 모델과 원격 모델 엔드포인트의 경계를 설명합니다.',
    },
    download: {
      title: 'macOS용 AfterRay 다운로드',
      description: 'macOS 15 이상 Apple Silicon Mac용으로 서명 및 공증된 AfterRay를 다운로드하고 설치 요구 사항을 확인하세요.',
    },
  },
  es: {
    home: {
      title: 'Memoria privada y buscable para Mac — AfterRay',
      description: 'AfterRay guarda en tu Mac un historial privado de pantalla y audio. Reproduce cualquier momento, busca lo que viste u oíste y deja que tu agente lo consulte.',
    },
    privacy: {
      title: 'Privacidad — AfterRay',
      description: 'Descubre qué registra AfterRay, dónde se guarda el historial, qué se procesa en el dispositivo y cuándo pueden salir datos de tu Mac.',
    },
    security: {
      title: 'Seguridad — AfterRay',
      description: 'Descubre cómo AfterRay cifra el vault local, protege la clave, limita el acceso de agentes y separa modelos locales de endpoints remotos.',
    },
    download: {
      title: 'Descargar AfterRay para macOS',
      description: 'Descarga AfterRay firmado y notarizado para equipos Mac con Apple silicon y macOS 15 o posterior, y revisa los requisitos de instalación.',
    },
  },
  de: {
    home: {
      title: 'Privates, durchsuchbares Gedächtnis für den Mac — AfterRay',
      description: 'AfterRay speichert Bildschirm- und Audioverlauf privat auf deinem Mac. Spiele Momente ab, durchsuche Erlebtes und lass deinen Agenten darin nachsehen.',
    },
    privacy: {
      title: 'Datenschutz — AfterRay',
      description: 'Erfahre, was AfterRay aufzeichnet, wo der Verlauf gespeichert wird, was lokal verarbeitet wird und wann Daten den Mac verlassen können.',
    },
    security: {
      title: 'Sicherheit — AfterRay',
      description: 'So verschlüsselt AfterRay den lokalen Vault, schützt den Schlüssel, begrenzt Agentenzugriffe und trennt lokale von entfernten Modellen.',
    },
    download: {
      title: 'AfterRay für macOS laden',
      description: 'Lade die signierte und notarialisierte AfterRay-App für Apple-Silicon-Macs mit macOS 15 oder neuer und prüfe die Systemanforderungen.',
    },
  },
  fr: {
    home: {
      title: 'Une mémoire privée et consultable pour Mac — AfterRay',
      description: 'AfterRay conserve sur votre Mac un historique privé de l’écran et du son. Revivez n’importe quel moment, recherchez ce que vous avez vu ou entendu et laissez votre agent le consulter.',
    },
    privacy: {
      title: 'Confidentialité — AfterRay',
      description: 'Découvrez ce qu’AfterRay enregistre, où l’historique est stocké, quels traitements restent sur l’appareil et quand des données peuvent quitter votre Mac.',
    },
    security: {
      title: 'Sécurité — AfterRay',
      description: 'Découvrez comment AfterRay chiffre le vault local, protège sa clé, limite l’accès des agents et sépare modèles locaux et services distants.',
    },
    download: {
      title: 'Télécharger AfterRay pour macOS',
      description: 'Téléchargez AfterRay signé et notarié pour les Mac Apple silicon sous macOS 15 ou version ultérieure, puis vérifiez les prérequis.',
    },
  },
}

const imageAltByLanguage: Record<Lang, string> = {
  en: "AfterRay: your Mac's private, searchable memory",
  'zh-Hans': 'AfterRay：Mac 上私密、可搜索的记忆',
  'zh-Hant': 'AfterRay：Mac 上私密、可搜尋的記憶',
  ja: 'AfterRay：Macのプライベートかつ検索可能な記憶',
  ko: 'AfterRay: Mac을 위한 비공개 검색형 기억',
  es: 'AfterRay: memoria privada y buscable para Mac',
  de: 'AfterRay: privates, durchsuchbares Gedächtnis für den Mac',
  fr: 'AfterRay : une mémoire privée et consultable pour Mac',
}

const featureListByLanguage: Record<Lang, string[]> = {
  en: ['Replay screen, audio, and work context', 'Search OCR text and transcripts on device', 'Answers cited to original moments', 'Read-only CLI and Agent Skill for history queries', 'Exclude apps and sites, pause, or delete history'],
  'zh-Hans': ['回放屏幕、音频与工作上下文', '在本机搜索 OCR 文本和转录', '基于原始时刻提供带引用的回答', '通过只读 CLI 和 Agent Skill 查询历史', '排除 App 和网站，随时暂停或删除历史'],
  'zh-Hant': ['重播螢幕、音訊與工作情境', '在本機搜尋 OCR 文字與轉錄', '以原始時刻為引用的回答', '透過唯讀 CLI 與 Agent Skill 查詢歷史', '排除 App 與網站，隨時暫停或刪除歷史'],
  ja: ['画面・音声・作業コンテキストを再生', 'OCRテキストと文字起こしを端末内で検索', '元の瞬間を引用した回答', '読み取り専用CLIとAgent Skill', 'アプリやサイトの除外、一時停止、履歴削除'],
  ko: ['화면·오디오·작업 맥락 재생', '기기에서 OCR 텍스트와 전사 검색', '원본 순간을 인용한 답변', '읽기 전용 CLI와 Agent Skill', '앱 및 사이트 제외, 일시 정지, 기록 삭제'],
  es: ['Reproducir pantalla, audio y contexto de trabajo', 'Buscar texto OCR y transcripciones en el dispositivo', 'Respuestas con citas al momento original', 'CLI y Agent Skill de solo lectura', 'Excluir apps y sitios, pausar o eliminar el historial'],
  de: ['Bildschirm, Audio und Arbeitskontext wiedergeben', 'OCR-Text und Transkripte lokal durchsuchen', 'Antworten mit Verweisen auf Originalmomente', 'Schreibgeschützte CLI und Agent Skill', 'Apps und Websites ausschließen, pausieren oder Verlauf löschen'],
  fr: ['Revoir l’écran, le son et le contexte de travail', 'Rechercher localement le texte OCR et les transcriptions', 'Réponses citées vers les instants d’origine', 'CLI et Agent Skill en lecture seule', 'Exclure des apps et sites, suspendre ou supprimer l’historique'],
}

const pageKeys: PageKey[] = ['home', 'privacy', 'security', 'download']

function routePath(page: PageKey, lang: Lang): string {
  const prefix = languageDefinition(lang).pathPrefix
  if (page === 'home') return prefix === '' ? '/' : `/${prefix}/`
  return prefix === '' ? `/${page}/` : `/${prefix}/${page}/`
}

// @dec:indexable-locale-urls — docs/decisions/active/product/2026-08-20-indexable-locale-urls.md
function buildSiteRoutes(): SiteRoute[] {
  return LANGS.flatMap((language) => pageKeys.map((page) => {
    const seo = seoByLanguage[language.code][page]
    return {
      page,
      lang: language.code,
      path: routePath(page, language.code),
      title: seo.title,
      description: seo.description,
      htmlLang: language.htmlLang,
      ogLocale: language.ogLocale,
      imageAlt: imageAltByLanguage[language.code],
      featureList: page === 'home' ? featureListByLanguage[language.code] : undefined,
    }
  }))
}

export const SITE_ROUTES = buildSiteRoutes()

function normalizePath(pathname: string): string {
  const withoutIndex = pathname.replace(/\/index\.html$/, '/')
  if (withoutIndex === '') return '/'
  const withLeadingSlash = withoutIndex.startsWith('/') ? withoutIndex : `/${withoutIndex}`
  return withLeadingSlash === '/' || withLeadingSlash.endsWith('/')
    ? withLeadingSlash
    : `${withLeadingSlash}/`
}

export function resolveRoute(pathname: string): SiteRoute {
  const normalized = normalizePath(pathname)
  return SITE_ROUTES.find((candidate) => candidate.path === normalized) ?? SITE_ROUTES[0]
}

export function pathFor(page: PageKey, lang: Lang): string {
  const match = SITE_ROUTES.find((candidate) => candidate.page === page && candidate.lang === lang)
  if (!match) throw new Error(`missing ${lang} route for ${page}`)
  return match.path
}

export const prerenderPaths = SITE_ROUTES.map((candidate) => candidate.path)
