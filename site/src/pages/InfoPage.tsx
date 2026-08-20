import type { Lang } from '../i18n'
import type { SiteRoute } from '../routes'

type Link = { label: string; href: string }
type Section = { title: string; body: string | string[]; links?: Link[] }
type PageCopy = {
  eyebrow: string
  title: string
  intro: string
  sections: Section[]
  cta?: string
  note?: string
}

type InfoLocaleText = {
  privacy: {
    eyebrow: string; title: string; intro: string
    sectionTitles: [string, string, string, string, string]
    sectionBodies: [string, string, string, string, string]
    repoLabel: string; note: string
  }
  security: {
    eyebrow: string; title: string; intro: string
    sectionTitles: [string, string, string, string, string]
    sectionBodies: [string, string, string, string, string]
    threatLabel: string; repoLabel: string; note: string
  }
  download: {
    eyebrow: string; title: string; intro: string
    sectionTitles: [string, string, string]
    requirements: [string, string, string, string, string]
    releaseBody: string; sourceBody: string
    licenseLabel: string; repoLabel: string; cta: string; note: string
  }
}

const repo = 'https://github.com/loro-dev/afterray'
const threatModel = `${repo}/blob/main/docs/harness-threat-model.md`
const license = `${repo}/blob/main/LICENSE`

const infoText: Record<Lang, InfoLocaleText> = {
  en: {
    privacy: {
      eyebrow: 'Privacy', title: 'Your history belongs on your Mac.',
      intro: 'AfterRay is a local-first computer-history app. This page separates what the app records from ordinary website and update requests.',
      sectionTitles: ['What the app can record', 'Where app data is processed', 'The remote-model exception', 'Website and download requests', 'Questions and changes'],
      sectionBodies: [
        'After you grant macOS permissions, AfterRay can capture your screen, foreground-app Accessibility context, and optional system and microphone audio. Raw input events expire after 48 hours. You can exclude apps and websites, pause capture, and delete history.',
        'Captures, OCR text, transcripts, search indexes, embeddings, and summaries are stored and processed on your Mac. AfterRay has no account system, product telemetry, or cloud-sync service.',
        'Local models keep prompts and retrieved evidence on your Mac. If you configure Ollama or an OpenAI-compatible endpoint on another machine, the prompt and evidence required for that request are sent to that endpoint and follow its operator’s policies.',
        'afterray.com is served through Cloudflare. Page visits, downloads, and update checks create ordinary edge request logs such as path, time, IP address, and user agent. AfterRay uses aggregate request data without sending a device ID or install ID.',
        'The implementation and product claims are reviewable in the source repository. Material changes to this page will update the date below.',
      ],
      repoLabel: 'AfterRay source repository', note: 'Updated August 20, 2026',
    },
    security: {
      eyebrow: 'Security', title: 'A small boundary around sensitive history.',
      intro: 'Computer history is unusually sensitive. AfterRay keeps the vault behind the daemon, encrypts stored data, and gives models and agents narrower interfaces than the app itself.',
      sectionTitles: ['Encrypted local vault', 'One process owns decryption', 'Limited agent access', 'Model boundary', 'Auditable distribution'],
      sectionBodies: [
        'Structured records and indexes live in SQLCipher. Capture artifacts use XChaCha20-Poly1305. The vault key is stored in the macOS Keychain and is not exposed to the SwiftUI app.',
        'The local daemon owns the vault, applies retention and deletion rules, and serves the app over a versioned local socket. The UI does not open encrypted storage directly.',
        'The built-in assistant receives allowlisted, read-only tools. The optional CLI exposes summaries and search results; original evidence requires a 30-minute grant in Settings.',
        'A local model keeps prompts and evidence on this Mac. A remote OpenAI-compatible provider receives the prompt and evidence needed for each request.',
        'Public releases are signed and notarized for macOS. Source, build scripts, threat model, and release process are available for review.',
      ],
      threatLabel: 'Agent harness threat model', repoLabel: 'Source repository', note: 'Updated August 20, 2026',
    },
    download: {
      eyebrow: 'Download', title: 'Install AfterRay for macOS.',
      intro: 'The public build is for Apple silicon Macs running macOS 15 or later. An M3 or newer Mac is recommended for on-device processing.',
      sectionTitles: ['Before you install', 'What you receive', 'Source and license'],
      requirements: ['macOS 15 or later', 'Apple silicon; M3 or newer recommended', 'Screen Recording permission for visual history', 'Optional microphone and system-audio permissions for meeting recall', 'Accessibility permission for foreground-app context'],
      releaseBody: 'The latest public DMG is Developer ID signed and notarized by Apple. AfterRay checks its signed update feed for newer releases. No account or separate first-launch command is required.',
      sourceBody: 'AfterRay is source-available under FSL-1.1-ALv2 and is not currently OSI Open Source. You can inspect the app and build process.',
      licenseLabel: 'License', repoLabel: 'Source repository', cta: 'Download the latest DMG', note: 'The download link always resolves to the newest published release.',
    },
  },
  'zh-Hans': {
    privacy: {
      eyebrow: '隐私', title: '你的历史，应当留在你的 Mac 上。', intro: 'AfterRay 是一款本地优先的电脑历史工具。这里分别说明 App 会记录什么，以及网站和更新请求会产生什么。',
      sectionTitles: ['App 可以记录什么', 'App 数据在哪里处理', '远程模型是唯一例外', '网站和下载请求', '问题与变更'],
      sectionBodies: ['授予 macOS 权限后，AfterRay 可以捕获屏幕、前台 App 的 Accessibility 上下文，以及可选的系统音频和麦克风音频。原始输入事件 48 小时后过期。你可以排除 App 和网站、暂停捕获或删除历史。', '捕获内容、OCR 文本、转录、搜索索引、embedding 和总结都存储并处理在你的 Mac 上。AfterRay 没有账号系统、产品遥测或云同步服务。', '本地模型会让 prompt 和检索证据留在 Mac 上。如果你配置另一台机器上的 Ollama 或 OpenAI 兼容端点，一次请求需要的 prompt 和证据会发送到该端点，并受其运营者政策约束。', 'afterray.com 通过 Cloudflare 提供服务。访问页面、下载 App 或检查更新时会产生路径、时间、IP 地址、User-Agent 等普通边缘日志。AfterRay 只使用汇总请求数据，不发送设备 ID 或安装 ID。', '实现和产品承诺可以在源码仓库中检查。这里若有重要修改，会更新下方日期。'],
      repoLabel: 'AfterRay 源码仓库', note: '更新于 2026 年 8 月 20 日',
    },
    security: {
      eyebrow: '安全', title: '给敏感历史划一条尽量小的边界。', intro: '电脑历史非常敏感。AfterRay 把 vault 放在 daemon 后面，加密磁盘数据，并让模型和 agent 使用比 App 更窄的接口。',
      sectionTitles: ['加密的本地 Vault', '只有一个进程负责解密', '受限的 Agent 访问', '模型边界', '可审查的分发流程'],
      sectionBodies: ['结构化记录和索引保存在 SQLCipher 中，捕获 artifact 使用 XChaCha20-Poly1305。Vault 密钥存于 macOS Keychain，不暴露给 SwiftUI App。', '本地 daemon 拥有 vault，执行保留和删除规则，并通过带版本的本地 socket 为 App 提供数据。UI 不直接打开加密存储。', '内置助手只能使用 allowlist 内的只读工具。可选 CLI 默认暴露总结和搜索结果；原始证据需要在设置中授予 30 分钟访问权。', '本地模型会让 prompt 和证据留在本机。远程 OpenAI 兼容服务会收到每次请求所需的 prompt 和证据。', '公开发行版经过 macOS 签名和公证。源码、构建脚本、威胁模型和发行流程均可审查。'],
      threatLabel: 'Agent harness 威胁模型', repoLabel: '源码仓库', note: '更新于 2026 年 8 月 20 日',
    },
    download: {
      eyebrow: '下载', title: '安装 AfterRay macOS 版。', intro: '公开版本适用于 macOS 15 或更高版本的 Apple 芯片 Mac。本地处理推荐使用 M3 或更新的 Mac。',
      sectionTitles: ['安装前确认', '下载内容', '源码与许可证'], requirements: ['macOS 15 或更高版本', 'Apple 芯片；推荐 M3 或更新型号', '用于视觉历史的屏幕录制权限', '用于会议回忆的可选麦克风和系统音频权限', '用于获取前台 App 上下文的 Accessibility 权限'],
      releaseBody: '最新公开 DMG 使用 Developer ID 签名并经过 Apple 公证。AfterRay 通过带签名的更新 feed 检查新版本。不需要账号或额外的首次启动命令。', sourceBody: 'AfterRay 以 FSL-1.1-ALv2 形式 source-available，目前不是 OSI Open Source。你可以审查 App 和构建流程。',
      licenseLabel: '许可证', repoLabel: '源码仓库', cta: '下载最新 DMG', note: '下载链接始终指向最新的已发布版本。',
    },
  },
  'zh-Hant': {
    privacy: {
      eyebrow: '隱私', title: '你的歷史，應該留在你的 Mac 上。', intro: 'AfterRay 是本機優先的電腦歷史工具。這裡分別說明 App 會記錄什麼，以及網站與更新請求會產生什麼。',
      sectionTitles: ['App 可以記錄什麼', 'App 資料在哪裡處理', '遠端模型是唯一例外', '網站與下載請求', '問題與變更'],
      sectionBodies: ['授予 macOS 權限後，AfterRay 可以捕捉螢幕、前景 App 的 Accessibility 情境，以及可選的系統與麥克風音訊。原始輸入事件 48 小時後到期。你可以排除 App 和網站、暫停捕捉或刪除歷史。', '捕捉內容、OCR 文字、轉錄、搜尋索引、embedding 與摘要都儲存並處理在你的 Mac 上。AfterRay 沒有帳號系統、產品遙測或雲端同步服務。', '本機模型讓 prompt 與檢索證據留在 Mac 上。若設定另一台機器上的 Ollama 或 OpenAI 相容端點，該次請求所需內容會傳送到該端點並受其政策約束。', 'afterray.com 透過 Cloudflare 提供服務。頁面瀏覽、下載與更新檢查會產生路徑、時間、IP 與 User-Agent 等一般邊緣日誌。AfterRay 只使用彙總請求資料，不傳送裝置或安裝 ID。', '實作與產品承諾可在原始碼儲存庫中檢查。重要修改會更新下方日期。'],
      repoLabel: 'AfterRay 原始碼儲存庫', note: '更新於 2026 年 8 月 20 日',
    },
    security: {
      eyebrow: '安全', title: '為敏感歷史劃出盡量小的邊界。', intro: '電腦歷史非常敏感。AfterRay 將 vault 放在 daemon 後方、加密磁碟資料，並讓模型與 agent 使用比 App 更窄的介面。',
      sectionTitles: ['加密的本機 Vault', '只有一個行程負責解密', '受限的 Agent 存取', '模型邊界', '可審查的發行流程'],
      sectionBodies: ['結構化記錄與索引儲存在 SQLCipher，捕捉 artifact 使用 XChaCha20-Poly1305。Vault 金鑰存於 macOS Keychain，不暴露給 SwiftUI App。', '本機 daemon 擁有 vault、執行保留與刪除規則，並透過有版本的本機 socket 提供資料。UI 不直接開啟加密儲存。', '內建助手只能使用 allowlist 內的唯讀工具。可選 CLI 預設提供摘要與搜尋結果；原始證據需要在設定中授予 30 分鐘存取權。', '本機模型讓 prompt 與證據留在本機。遠端 OpenAI 相容服務會收到每次請求所需的 prompt 與證據。', '公開發行版經過 macOS 簽署與公證。原始碼、建置腳本、威脅模型與發行流程均可審查。'],
      threatLabel: 'Agent harness 威脅模型', repoLabel: '原始碼儲存庫', note: '更新於 2026 年 8 月 20 日',
    },
    download: {
      eyebrow: '下載', title: '安裝 AfterRay macOS 版。', intro: '公開版本適用於 macOS 15 以上的 Apple 晶片 Mac。本機處理建議使用 M3 或更新機型。',
      sectionTitles: ['安裝前確認', '下載內容', '原始碼與授權'], requirements: ['macOS 15 或以上', 'Apple 晶片；建議 M3 或更新機型', '用於視覺歷史的螢幕錄製權限', '用於會議回顧的可選麥克風與系統音訊權限', '用於前景 App 情境的 Accessibility 權限'],
      releaseBody: '最新公開 DMG 使用 Developer ID 簽署並經 Apple 公證。AfterRay 透過已簽署的更新 feed 檢查新版本。不需要帳號或額外首次啟動指令。', sourceBody: 'AfterRay 以 FSL-1.1-ALv2 形式 source-available，目前不是 OSI Open Source。你可以審查 App 與建置流程。',
      licenseLabel: '授權', repoLabel: '原始碼儲存庫', cta: '下載最新 DMG', note: '下載連結永遠指向最新已發行版本。',
    },
  },
  ja: {
    privacy: {
      eyebrow: 'プライバシー', title: 'あなたの履歴は、あなたのMacに。', intro: 'AfterRayはローカルファーストのコンピューター履歴アプリです。アプリの記録内容と、Webサイト・更新リクエストを分けて説明します。',
      sectionTitles: ['アプリが記録できる内容', 'データの処理場所', 'リモートモデルの例外', 'Webサイトとダウンロード', '質問と変更'],
      sectionBodies: ['macOSの許可後、画面、前景アプリのAccessibility情報、任意のシステム音声とマイク音声を記録できます。生の入力イベントは48時間後に削除されます。アプリやサイトの除外、一時停止、履歴削除が可能です。', 'キャプチャ、OCR、文字起こし、検索索引、埋め込み、要約はMac内に保存・処理されます。アカウントシステム、製品テレメトリ、クラウド同期はありません。', 'ローカルモデルではプロンプトと取得した証拠がMac内に残ります。別の端末のOllamaやOpenAI互換エンドポイントを設定すると、そのリクエストに必要な内容が送信され、運営者のポリシーが適用されます。', 'afterray.comはCloudflare経由で配信されます。閲覧、ダウンロード、更新確認ではパス、時刻、IP、User-Agentなど通常のエッジリクエストログが生じます。端末IDやインストールIDは送信しません。', '実装と製品上の主張はソースリポジトリで確認できます。重要な変更時は下の日付を更新します。'],
      repoLabel: 'AfterRayソースリポジトリ', note: '2026年8月20日更新',
    },
    security: {
      eyebrow: 'セキュリティ', title: '機密性の高い履歴を、小さな境界の内側へ。', intro: 'コンピューター履歴は極端に機微です。AfterRayはvaultをdaemonの背後に置き、保存データを暗号化し、モデルとエージェントにはアプリより狭いインターフェースだけを渡します。',
      sectionTitles: ['暗号化されたローカルVault', '復号を所有する単一プロセス', '制限されたエージェントアクセス', 'モデルの境界', '監査可能な配布'],
      sectionBodies: ['構造化データと索引はSQLCipher、キャプチャファイルはXChaCha20-Poly1305で保護されます。Vault鍵はmacOS Keychainにあり、SwiftUIアプリには渡りません。', 'ローカルdaemonがvault、保持、削除を所有し、バージョン付きのローカルソケットでアプリにデータを提供します。UIは暗号化ストレージを直接開きません。', '内蔵アシスタントは許可リスト内の読み取り専用ツールだけを使います。オプションのCLIは要約と検索結果を返します。元の証拠には「設定」で30分の許可が必要です。', 'ローカルモデルならプロンプトと証拠はMac内に残ります。リモートのOpenAI互換プロバイダーは各リクエストに必要な内容を受け取ります。', '公開版はmacOS向けに署名・公証されています。ソース、ビルドスクリプト、脅威モデル、リリース手順を確認できます。'],
      threatLabel: 'エージェントハーネスの脅威モデル', repoLabel: 'ソースリポジトリ', note: '2026年8月20日更新',
    },
    download: {
      eyebrow: 'ダウンロード', title: 'AfterRayをmacOSにインストール。', intro: '公開版はmacOS 15以降のAppleシリコンMac向けです。端末内処理にはM3以降を推奨します。',
      sectionTitles: ['インストール前の確認', 'ダウンロード内容', 'ソースとライセンス'], requirements: ['macOS 15以降', 'Appleシリコン（M3以降推奨）', '画面履歴のための画面収録権限', '会議の記録に使う任意のマイク・システム音声権限', '前景アプリ情報のためのAccessibility権限'],
      releaseBody: '最新の公開DMGはDeveloper IDで署名され、Appleの公証を受けています。署名済みupdate feedから新しい版を確認します。アカウントや追加の初回コマンドは不要です。', sourceBody: 'AfterRayはFSL-1.1-ALv2のsource-availableソフトウェアで、現時点ではOSI Open Sourceではありません。アプリとbuild processを確認できます。',
      licenseLabel: 'ライセンス', repoLabel: 'ソースリポジトリ', cta: '最新DMGをダウンロード', note: 'ダウンロードリンクは常に最新の公開版を指します。',
    },
  },
  ko: {
    privacy: {
      eyebrow: '개인정보 보호', title: '기록은 Mac에 남아야 합니다.', intro: 'AfterRay는 로컬 우선 컴퓨터 기록 앱입니다. 앱이 기록하는 정보와 웹사이트·업데이트 요청에서 생기는 정보를 구분해 설명합니다.',
      sectionTitles: ['앱이 기록할 수 있는 정보', '데이터 처리 위치', '원격 모델 예외', '웹사이트와 다운로드 요청', '문의와 변경'],
      sectionBodies: ['macOS 권한을 허용하면 화면, 전면 앱의 Accessibility 맥락, 선택한 시스템 및 마이크 오디오를 기록할 수 있습니다. 원시 입력 이벤트는 48시간 뒤 삭제됩니다. 앱·사이트 제외, 일시 정지, 기록 삭제가 가능합니다.', '캡처, OCR, 전사, 검색 인덱스, 임베딩, 요약은 Mac에 저장되고 처리됩니다. 계정 시스템, 제품 텔레메트리, 클라우드 동기화 서비스가 없습니다.', '로컬 모델은 프롬프트와 검색 증거를 Mac에 남깁니다. 다른 기기의 Ollama 또는 OpenAI 호환 엔드포인트를 설정하면 요청에 필요한 내용이 전송되고 운영자 정책이 적용됩니다.', 'afterray.com은 Cloudflare를 통해 제공됩니다. 방문, 다운로드, 업데이트 확인은 경로, 시간, IP, User-Agent 등의 일반 에지 로그를 만듭니다. 기기 ID나 설치 ID는 보내지 않습니다.', '구현과 제품 약속은 소스 저장소에서 검토할 수 있습니다. 중요한 변경 시 아래 날짜를 갱신합니다.'],
      repoLabel: 'AfterRay 소스 저장소', note: '2026년 8월 20일 업데이트',
    },
    security: {
      eyebrow: '보안', title: '민감한 기록을 작은 경계 안에.', intro: 'AfterRay는 vault를 daemon 뒤에 두고 저장 데이터를 암호화하며 모델과 에이전트에는 앱보다 좁은 인터페이스만 제공합니다.',
      sectionTitles: ['암호화된 로컬 Vault', '복호화를 소유하는 단일 프로세스', '제한된 에이전트 접근', '모델 경계', '검토 가능한 배포'],
      sectionBodies: ['구조화 데이터와 인덱스는 SQLCipher, 캡처 파일은 XChaCha20-Poly1305로 보호합니다. Vault 키는 macOS Keychain에 보관하며 SwiftUI 앱에 노출하지 않습니다.', '로컬 daemon이 vault, 보존, 삭제 규칙을 소유하고 버전이 있는 로컬 소켓으로 데이터를 제공합니다. UI는 암호화 저장소를 직접 열지 않습니다.', '내장 어시스턴트는 허용 목록의 읽기 전용 도구만 사용합니다. 선택적 CLI는 요약과 검색 결과를 제공합니다. 원본 증거는 설정에서 30분 접근을 허용해야 합니다.', '로컬 모델은 프롬프트와 증거를 Mac에 남깁니다. 원격 OpenAI 호환 제공자는 각 요청에 필요한 내용을 받습니다.', '공개 릴리스는 macOS용으로 서명 및 공증됩니다. 소스, 빌드 스크립트, 위협 모델, 릴리스 절차를 검토할 수 있습니다.'],
      threatLabel: '에이전트 하네스 위협 모델', repoLabel: '소스 저장소', note: '2026년 8월 20일 업데이트',
    },
    download: {
      eyebrow: '다운로드', title: 'macOS에 AfterRay 설치.', intro: '공개 빌드는 macOS 15 이상 Apple Silicon Mac용입니다. 기기 내 처리에는 M3 이상을 권장합니다.',
      sectionTitles: ['설치 전 확인', '다운로드 내용', '소스와 라이선스'], requirements: ['macOS 15 이상', 'Apple Silicon(M3 이상 권장)', '시각 히스토리를 위한 화면 기록 권한', '회의 기록을 위한 선택적 마이크·시스템 오디오 권한', '전면 앱 맥락을 위한 Accessibility 권한'],
      releaseBody: '최신 공개 DMG는 Developer ID로 서명되고 Apple 공증을 받았습니다. 서명된 update feed에서 새 버전을 확인합니다. 계정이나 별도의 첫 실행 명령은 필요 없습니다.', sourceBody: 'AfterRay는 FSL-1.1-ALv2로 source-available이며 현재 OSI Open Source는 아닙니다. 앱과 빌드 절차를 검토할 수 있습니다.',
      licenseLabel: '라이선스', repoLabel: '소스 저장소', cta: '최신 DMG 다운로드', note: '다운로드 링크는 항상 최신 공개 릴리스를 가리킵니다.',
    },
  },
  es: {
    privacy: {
      eyebrow: 'Privacidad', title: 'Tu historial debe quedarse en tu Mac.', intro: 'AfterRay es una app de historial del ordenador, primero local. Aquí separamos lo que registra la app de las solicitudes normales del sitio y las actualizaciones.',
      sectionTitles: ['Qué puede registrar la app', 'Dónde se procesan los datos', 'La excepción del modelo remoto', 'Solicitudes web y descargas', 'Preguntas y cambios'],
      sectionBodies: ['Tras conceder permisos de macOS, AfterRay puede capturar pantalla, contexto Accessibility de la app activa y audio opcional del sistema y micrófono. Los eventos de entrada sin procesar caducan tras 48 horas. Puedes excluir apps y sitios, pausar o borrar el historial.', 'Capturas, OCR, transcripciones, índices, embeddings y resúmenes se guardan y procesan en tu Mac. AfterRay no tiene cuentas, telemetría de producto ni sincronización en la nube.', 'Los modelos locales mantienen prompts y pruebas en tu Mac. Si configuras Ollama o un endpoint compatible con OpenAI en otro equipo, el contenido necesario se envía allí y se rige por sus políticas.', 'afterray.com se sirve mediante Cloudflare. Visitas, descargas y comprobaciones de actualización crean logs normales con ruta, hora, IP y User-Agent. No se envía un ID de dispositivo o instalación.', 'La implementación y las promesas del producto se pueden revisar en el repositorio. Los cambios importantes actualizarán la fecha inferior.'],
      repoLabel: 'Repositorio de AfterRay', note: 'Actualizado el 20 de agosto de 2026',
    },
    security: {
      eyebrow: 'Seguridad', title: 'Un límite pequeño para un historial sensible.', intro: 'El historial del ordenador es especialmente sensible. AfterRay mantiene el vault detrás del daemon, cifra los datos guardados y ofrece a modelos y agentes una interfaz más estrecha que la app.',
      sectionTitles: ['Vault local cifrado', 'Un proceso controla el descifrado', 'Acceso limitado para agentes', 'Límite de los modelos', 'Distribución auditable'],
      sectionBodies: ['Los datos e índices viven en SQLCipher y los artifacts usan XChaCha20-Poly1305. La clave está en el llavero de macOS y no se expone a la app SwiftUI.', 'El daemon local controla el vault y las reglas de retención y borrado, y sirve datos por un socket local versionado. La UI no abre el almacenamiento cifrado.', 'El asistente integrado solo recibe herramientas de lectura permitidas. La CLI opcional ofrece resúmenes y resultados de búsqueda; la evidencia original requiere una autorización de 30 minutos en Ajustes.', 'Un modelo local mantiene prompt y pruebas en el Mac. Un proveedor remoto compatible con OpenAI recibe lo necesario para cada solicitud.', 'Las versiones públicas están firmadas y notarizadas para macOS. Código, scripts, modelo de amenazas y proceso de publicación se pueden revisar.'],
      threatLabel: 'Modelo de amenazas del harness del agente', repoLabel: 'Repositorio', note: 'Actualizado el 20 de agosto de 2026',
    },
    download: {
      eyebrow: 'Descargar', title: 'Instala AfterRay para macOS.', intro: 'La versión pública es para Mac con Apple silicon y macOS 15 o posterior. Se recomienda M3 o posterior para procesamiento local.',
      sectionTitles: ['Antes de instalar', 'Qué recibes', 'Código y licencia'], requirements: ['macOS 15 o posterior', 'Apple silicon; M3 o posterior recomendado', 'Permiso de grabación de pantalla', 'Permisos opcionales de micrófono y audio del sistema', 'Permiso Accessibility para el contexto de la app activa'],
      releaseBody: 'El DMG público más reciente está firmado con Developer ID y notarizado por Apple. AfterRay consulta un feed de actualización firmado. No requiere cuenta ni comandos adicionales.', sourceBody: 'AfterRay es source-available bajo FSL-1.1-ALv2 y actualmente no es Open Source según OSI. Puedes revisar la app y su compilación.',
      licenseLabel: 'Licencia', repoLabel: 'Repositorio', cta: 'Descargar el último DMG', note: 'El enlace siempre resuelve a la versión publicada más reciente.',
    },
  },
  de: {
    privacy: {
      eyebrow: 'Datenschutz', title: 'Dein Verlauf gehört auf deinen Mac.', intro: 'AfterRay ist eine zuerst lokale App für Computerverlauf. Hier trennen wir App-Aufzeichnungen von normalen Website- und Update-Anfragen.',
      sectionTitles: ['Was die App erfassen kann', 'Wo Daten verarbeitet werden', 'Die Ausnahme für Remote-Modelle', 'Website- und Download-Anfragen', 'Fragen und Änderungen'],
      sectionBodies: ['Nach macOS-Freigaben kann AfterRay Bildschirm, Accessibility-Kontext der aktiven App sowie optional System- und Mikrofon-Audio erfassen. Rohe Eingabeereignisse laufen nach 48 Stunden ab. Apps und Websites lassen sich ausschließen; Aufnahme pausieren und Verlauf löschen ist jederzeit möglich.', 'Aufnahmen, OCR, Transkripte, Suchindex, Embeddings und Zusammenfassungen bleiben auf dem Mac. AfterRay hat kein Kontosystem, keine Produkttelemetrie und keinen Cloud-Sync.', 'Lokale Modelle behalten Prompts und Belege auf dem Mac. Bei Ollama oder einem OpenAI-kompatiblen Endpoint auf einem anderen Gerät werden die benötigten Inhalte dorthin gesendet und dessen Richtlinien gelten.', 'afterray.com wird über Cloudflare bereitgestellt. Besuche, Downloads und Update-Prüfungen erzeugen normale Edge-Logs mit Pfad, Zeit, IP und User-Agent. Die App sendet keine Geräte- oder Installations-ID.', 'Implementierung und Produktversprechen sind im Quellrepository prüfbar. Wesentliche Änderungen aktualisieren das Datum unten.'],
      repoLabel: 'AfterRay-Quellrepository', note: 'Aktualisiert am 20. August 2026',
    },
    security: {
      eyebrow: 'Sicherheit', title: 'Eine kleine Grenze um einen sensiblen Verlauf.', intro: 'Computerverlauf ist ungewöhnlich heikel. AfterRay hält den Vault hinter dem Daemon, verschlüsselt gespeicherte Daten und gibt Modellen und Agenten schmalere Schnittstellen als der App.',
      sectionTitles: ['Verschlüsselter lokaler Vault', 'Ein Prozess besitzt die Entschlüsselung', 'Begrenzter Agentenzugriff', 'Modellgrenze', 'Prüfbare Verteilung'],
      sectionBodies: ['Strukturierte Daten und Index liegen in SQLCipher; Artifacts nutzen XChaCha20-Poly1305. Der Vault-Schlüssel liegt im macOS-Schlüsselbund und wird der SwiftUI-App nicht gegeben.', 'Der lokale Daemon besitzt Vault, Aufbewahrung und Löschung und liefert Daten über einen versionierten lokalen Socket. Die UI öffnet den verschlüsselten Speicher nicht direkt.', 'Der integrierte Assistent erhält nur freigegebene Lesewerkzeuge. Originalbelege über die CLI erfordern eine 30-Minuten-Freigabe in den Einstellungen.', 'Ein lokales Modell behält Prompt und Belege auf dem Mac. Ein entfernter OpenAI-kompatibler Anbieter erhält die pro Anfrage benötigten Inhalte.', 'Öffentliche Versionen sind für macOS signiert und notarisiert. Source, Build-Skripte, Bedrohungsmodell und Release-Prozess sind prüfbar.'],
      threatLabel: 'Bedrohungsmodell der Agent-Harness', repoLabel: 'Quellrepository', note: 'Aktualisiert am 20. August 2026',
    },
    download: {
      eyebrow: 'Download', title: 'AfterRay für macOS installieren.', intro: 'Die öffentliche Version ist für Apple-Silicon-Macs ab macOS 15. Für lokale Verarbeitung wird M3 oder neuer empfohlen.',
      sectionTitles: ['Vor der Installation', 'Was du erhältst', 'Quellcode und Lizenz'], requirements: ['macOS 15 oder neuer', 'Apple Silicon; M3 oder neuer empfohlen', 'Bildschirmaufnahme-Berechtigung für visuellen Verlauf', 'Optionale Mikrofon- und Systemaudio-Berechtigungen', 'Accessibility-Berechtigung für den Kontext der aktiven App'],
      releaseBody: 'Das aktuelle öffentliche DMG ist mit Developer ID signiert und von Apple notarisiert. AfterRay prüft einen signierten Update-Feed. Konto oder zusätzliche Startbefehle sind nicht nötig.', sourceBody: 'AfterRay ist unter FSL-1.1-ALv2 source-available und derzeit nicht OSI Open Source. App und Build-Prozess sind einsehbar.',
      licenseLabel: 'Lizenz', repoLabel: 'Quellrepository', cta: 'Aktuelles DMG laden', note: 'Der Link verweist immer auf die neueste veröffentlichte Version.',
    },
  },
  fr: {
    privacy: {
      eyebrow: 'Confidentialité', title: 'Votre historique doit rester sur votre Mac.', intro: 'AfterRay est une app d’historique informatique, locale d’abord. Cette page distingue ce que l’app enregistre des requêtes ordinaires du site et des mises à jour.',
      sectionTitles: ['Ce que l’app peut enregistrer', 'Où les données sont traitées', 'L’exception du modèle distant', 'Requêtes du site et téléchargements', 'Questions et modifications'],
      sectionBodies: ['Après autorisation macOS, AfterRay peut capturer l’écran, le contexte Accessibility de l’app active et, au choix, l’audio système et micro. Les événements de saisie bruts expirent après 48 heures. Vous pouvez exclure apps et sites, suspendre ou supprimer l’historique.', 'Captures, OCR, transcriptions, index, embeddings et résumés restent stockés et traités sur votre Mac. AfterRay n’a ni compte, ni télémétrie produit, ni synchronisation cloud.', 'Les modèles locaux gardent prompts et preuves sur le Mac. Si vous configurez Ollama ou un endpoint compatible OpenAI sur une autre machine, le contenu nécessaire y est envoyé et suit les règles de son opérateur.', 'afterray.com est servi via Cloudflare. Visites, téléchargements et vérifications de mise à jour créent des logs edge ordinaires : chemin, heure, IP et User-Agent. Aucun identifiant d’appareil ou d’installation n’est envoyé.', 'L’implémentation et les engagements produit sont consultables dans le dépôt. Toute modification importante mettra à jour la date ci-dessous.'],
      repoLabel: 'Dépôt source AfterRay', note: 'Mis à jour le 20 août 2026',
    },
    security: {
      eyebrow: 'Sécurité', title: 'Une frontière réduite autour d’un historique sensible.', intro: 'L’historique informatique est particulièrement sensible. AfterRay garde le vault derrière le daemon, chiffre les données stockées et donne aux modèles et agents des interfaces plus étroites que celle de l’app.',
      sectionTitles: ['Vault local chiffré', 'Un seul processus déchiffre', 'Accès agent limité', 'Frontière des modèles', 'Distribution vérifiable'],
      sectionBodies: ['Données structurées et index vivent dans SQLCipher ; les artifacts utilisent XChaCha20-Poly1305. La clé du vault reste dans le trousseau macOS et n’est pas exposée à l’app SwiftUI.', 'Le daemon local possède le vault et les règles de rétention et suppression, puis sert l’app via un socket local versionné. L’UI n’ouvre pas directement le stockage chiffré.', 'L’assistant intégré ne reçoit que des outils de lecture autorisés. L’accès CLI aux preuves originales exige une autorisation de 30 minutes dans Réglages.', 'Un modèle local garde prompt et preuves sur le Mac. Un fournisseur distant compatible OpenAI reçoit ce qui est nécessaire à chaque requête.', 'Les versions publiques sont signées et notariées pour macOS. Source, scripts, modèle de menace et publication sont consultables.'],
      threatLabel: 'Modèle de menace du harness agent', repoLabel: 'Dépôt source', note: 'Mis à jour le 20 août 2026',
    },
    download: {
      eyebrow: 'Télécharger', title: 'Installer AfterRay pour macOS.', intro: 'La version publique vise les Mac Apple silicon sous macOS 15 ou ultérieur. Un M3 ou plus récent est recommandé pour le traitement local.',
      sectionTitles: ['Avant l’installation', 'Ce que vous recevez', 'Source et licence'], requirements: ['macOS 15 ou ultérieur', 'Apple silicon ; M3 ou plus récent recommandé', 'Autorisation d’enregistrement d’écran', 'Autorisations facultatives micro et audio système', 'Autorisation Accessibility pour le contexte de l’app active'],
      releaseBody: 'Le DMG public actuel est signé Developer ID et notarié par Apple. AfterRay consulte un flux de mise à jour signé. Aucun compte ni commande de premier lancement n’est nécessaire.', sourceBody: 'AfterRay est source-available sous FSL-1.1-ALv2 et n’est pas actuellement Open Source au sens de l’OSI. L’app et son build sont consultables.',
      licenseLabel: 'Licence', repoLabel: 'Dépôt source', cta: 'Télécharger le dernier DMG', note: 'Le lien pointe toujours vers la dernière version publiée.',
    },
  },
}

function buildInfoPages(text: InfoLocaleText): Record<Exclude<SiteRoute['page'], 'home'>, PageCopy> {
  const privacySections = text.privacy.sectionTitles.map((title, index) => ({
    title,
    body: text.privacy.sectionBodies[index],
    links: index === 4 ? [{ label: text.privacy.repoLabel, href: repo }] : undefined,
  }))
  const securitySections = text.security.sectionTitles.map((title, index) => ({
    title,
    body: text.security.sectionBodies[index],
    links: index === 3
      ? [{ label: text.security.threatLabel, href: threatModel }]
      : index === 4 ? [{ label: text.security.repoLabel, href: repo }] : undefined,
  }))

  return {
    privacy: { eyebrow: text.privacy.eyebrow, title: text.privacy.title, intro: text.privacy.intro, sections: privacySections, note: text.privacy.note },
    security: { eyebrow: text.security.eyebrow, title: text.security.title, intro: text.security.intro, sections: securitySections, note: text.security.note },
    download: {
      eyebrow: text.download.eyebrow, title: text.download.title, intro: text.download.intro,
      sections: [
        { title: text.download.sectionTitles[0], body: text.download.requirements },
        { title: text.download.sectionTitles[1], body: text.download.releaseBody },
        { title: text.download.sectionTitles[2], body: text.download.sourceBody, links: [{ label: text.download.licenseLabel, href: license }, { label: text.download.repoLabel, href: repo }] },
      ],
      cta: text.download.cta, note: text.download.note,
    },
  }
}

const pages = Object.fromEntries(
  Object.entries(infoText).map(([lang, text]) => [lang, buildInfoPages(text)]),
) as Record<Lang, Record<Exclude<SiteRoute['page'], 'home'>, PageCopy>>

export default function InfoPage({ route }: { route: SiteRoute }) {
  if (route.page === 'home') return null
  const content = pages[route.lang][route.page]

  return (
    <main className="info-page" id="main">
      <article className="info-article">
        <header className="info-head">
          <p className="hero-eyebrow">{content.eyebrow}</p>
          <h1>{content.title}</h1>
          <p className="info-intro">{content.intro}</p>
          {route.page === 'download' && content.cta ? (
            <a className="btn btn-primary" href="/download/latest">{content.cta}</a>
          ) : null}
        </header>
        <div className="info-sections">
          {content.sections.map((section) => (
            <section key={section.title}>
              <h2>{section.title}</h2>
              {Array.isArray(section.body) ? (
                <ul>{section.body.map((item) => <li key={item}>{item}</li>)}</ul>
              ) : (
                <p>
                  {section.body}
                  {section.links?.map((link, index) => (
                    <span key={link.href}> {index > 0 ? '· ' : ''}<a href={link.href}>{link.label}</a></span>
                  ))}
                </p>
              )}
            </section>
          ))}
        </div>
        {content.note ? <p className="info-note mono dim">{content.note}</p> : null}
      </article>
    </main>
  )
}
