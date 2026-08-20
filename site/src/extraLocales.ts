import type { Copy, Lang, Part } from './i18n'

type ScenarioText = {
  chip: string
  keys: string[]
  query: string
  results: [string, string]
  matches: [string, string]
  answer: string
}

type LocaleText = {
  nav: Copy['nav']
  hero: Copy['hero']
  jtbd: Copy['jtbd']
  recall: {
    body: string
    status: string
    searchHint: string
    date: string
    hint: string
    heardLabel: string
    openLabel: string
    you: string
    transcript: string[]
    recordTitles: string[]
  }
  memories: {
    titleA: Part[]
    titleB: Part[]
    body: string
    points: string[]
    head: string
    label: string
    rows: string[]
  }
  searchAsk: {
    titleA: Part[]
    titleB: Part[]
    body: string
    points: string[]
    tryLabel: string
    searchHead: string
    foundHead: string
    askHead: string
    screenLabel: string
    heardLabel: string
    replay: string
    scenarios: [ScenarioText, ScenarioText, ScenarioText]
  }
  agents: {
    titleA: Part[]
    titleB: Part[]
    body: string
    toolsLabel: string
    note: string
    jailTitle: string
    jailBody: string
    jailProof: string
    jailCaveat: string
  }
  privacy: Copy['privacy']
  specs: Copy['specs']
  final: Copy['final']
  footer: Copy['footer']
}

function localizedCopy(base: Copy, text: LocaleText): Copy {
  return {
    nav: text.nav,
    hero: text.hero,
    jtbd: text.jtbd,
    recall: {
      body: text.recall.body,
      mock: {
        ...base.recall.mock,
        status: text.recall.status,
        searchHint: text.recall.searchHint,
        date: text.recall.date,
        hint: text.recall.hint,
        heardLabel: text.recall.heardLabel,
        openLabel: text.recall.openLabel,
        transcript: base.recall.mock.transcript.map((line, index) => ({
          ...line,
          who: line.who === 'You' ? text.recall.you : line.who,
          text: text.recall.transcript[index] ?? line.text,
        })),
        records: base.recall.mock.records.map((record, index) => ({
          ...record,
          title: text.recall.recordTitles[index] ?? record.title,
        })),
      },
    },
    memories: {
      titleA: text.memories.titleA,
      titleB: text.memories.titleB,
      body: text.memories.body,
      points: text.memories.points,
      mock: {
        head: text.memories.head,
        label: text.memories.label,
        rows: base.memories.mock.rows.map((row, index) => ({
          ...row,
          summary: text.memories.rows[index] ?? row.summary,
        })),
      },
    },
    searchAsk: {
      titleA: text.searchAsk.titleA,
      titleB: text.searchAsk.titleB,
      body: text.searchAsk.body,
      points: text.searchAsk.points,
      mock: {
        tryLabel: text.searchAsk.tryLabel,
        searchHead: text.searchAsk.searchHead,
        foundHead: text.searchAsk.foundHead,
        askHead: text.searchAsk.askHead,
        screenLabel: text.searchAsk.screenLabel,
        heardLabel: text.searchAsk.heardLabel,
        replay: text.searchAsk.replay,
        scenarios: base.searchAsk.mock.scenarios.map((scenario, scenarioIndex) => {
          const translated = text.searchAsk.scenarios[scenarioIndex]
          return {
            ...scenario,
            chip: translated.chip,
            query: translated.query,
            keys: translated.keys,
            results: scenario.results.map((result, resultIndex) => ({
              ...result,
              text: translated.results[resultIndex] ?? result.text,
              match: translated.matches[resultIndex] ?? result.match,
            })),
            answer: translated.answer,
          }
        }),
      },
    },
    agents: {
      ...base.agents,
      titleA: text.agents.titleA,
      titleB: text.agents.titleB,
      body: text.agents.body,
      toolsLabel: text.agents.toolsLabel,
      note: text.agents.note,
      jailTitle: text.agents.jailTitle,
      jailBody: text.agents.jailBody,
      jailProof: text.agents.jailProof,
      jailCaveat: text.agents.jailCaveat,
    },
    privacy: text.privacy,
    specs: text.specs,
    final: text.final,
    footer: text.footer,
  }
}

const zhHant: LocaleText = {
  nav: { language: '語言', skip: '跳至主要內容' },
  hero: {
    eyebrow: 'Mac 上私密、本機優先的電腦歷史',
    titleA: ['你的 Mac'],
    titleB: ['私密、', { em: '可搜尋的記憶。' }],
    sub: 'AfterRay 在 Mac 本機記錄螢幕與音訊，讓你重播任一時刻、搜尋看過或聽過的內容，也讓 agent 查詢這些記憶。',
    ctaPrimary: '下載 macOS 版', ctaSecondary: '看看它記得什麼',
    facts: ['macOS 15+', '可排除 App 與網站', '隨時暫停或刪除', '不離開這台 Mac'],
  },
  jtbd: [
    { title: '從中斷處接著做', body: '請它完成星期二做到一半的遷移。你動過哪些檔案、何時動過，它都能找到。' },
    { title: '根據發生過的事回答', body: '「保留政策最後怎麼決定？」回來的是原始時刻，不是猜測。' },
    { title: '根據做過的事起草', body: '站會筆記、PR 說明、交接內容，都從這一週寫成，不靠回憶。' },
  ],
  recall: {
    body: '在任何 App 按 ⇧⌘Space。拖曳時間軸回到任一時刻。', status: '錄製中',
    searchHint: '搜尋你的一天 — Tab 開啟 AI 對話', date: '8 月 14 日，星期五',
    hint: '拖曳縮放 · 滑動穿梭 · Esc 關閉', heardLabel: '聽到', openLabel: '開啟', you: '你',
    transcript: ['時間軸縮放應該像相機，而不是捲軸。', '可以固定播放頭，讓軌道在下面移動嗎？', '可以——這正是它像相機的關鍵。', '拖曳時只需要預覽幀，停下來再補即可。', '峰值來自 cold-still 封裝時的重複複製。', '收藏永不過期，其餘內容保持在上限內。', '測試是 HEIF 41 毫秒，JPEG 63 毫秒。'],
    recordTitles: ['afterrayd — agent.rs', 'hot-stills-cold-gop.md', '保留策略想法', '設計評審 — 錄製中', '設計評審 — 錄製中', 'PR #128 — 保留策略討論', 'bench-codec — HEIF 與 JPEG'],
  },
  memories: {
    titleA: ['今天你做了很多。'], titleB: ['這就是', { em: '這一天。' }],
    body: 'AfterRay 每半小時把一天整理給你。模型在本機執行，沒看過的檔案、網址或任務一律不編。',
    points: ['隨工作自動寫成，不必開口', '每一行都能回到背後的原始時刻'], head: '8 月 14 日，星期五', label: '記憶',
    rows: ['追查 afterrayd 的 agent 迴圈，接著開始整理保留策略。', '閱讀 hot-stills-cold-gop.md，比較 HEIF 與 JPEG 解碼路徑。', '完成 v1 規格的磁碟章節。', '在通話中除錯 GOP 編碼器記憶體峰值，接著提出 PR #128。'],
  },
  searchAsk: {
    titleA: ['只記得一點。'], titleB: ['也能', { em: '精準找到。' }],
    body: '忘了檔名和 App 也沒關係。記得一句話就夠，或直接提問。',
    points: ['同時搜尋 OCR 文字與轉錄', '依語意搜尋，不只比對關鍵字', '回答附上可重播的原始時刻'],
    tryLabel: '試一個', searchHead: '你只記得', foundHead: '它找到', askHead: '或直接問', screenLabel: '螢幕上', heardLabel: '聽到', replay: '重播',
    scenarios: [
      { chip: '保留收藏', keys: ['收藏', '保留', 'star'], query: '關於保留收藏的那件事', results: ['收藏永不過期——其餘內容保持在上限內', 'PR #128 — 儲存預算只套用到未收藏時刻'], matches: ['收藏永不過期', '儲存預算'], answer: '加上星號的內容不受限制且永不過期，其餘內容則位於你設定的儲存預算內。' },
      { chip: '記憶體峰值', keys: ['峰值', '記憶體', '編碼', 'gop'], query: '有人提過的記憶體峰值', results: ['峰值來自 cold-still 封裝時的重複複製', 'bench-codec — 每幀 HEIF 41ms、JPEG 63ms'], matches: ['重複複製', 'bench-codec'], answer: '原因是 cold-still 封裝中的重複複製。星期四下午發現，當晚移除。' },
      { chip: 'Vault 金鑰筆記', keys: ['vault', '金鑰', '筆記', '寫'], query: '我在哪裡寫過 vault 金鑰的想法', results: ['待辦：先寫 vault 鎖定測試', 'docs/vault-encryption-design.md — 金鑰階層'], matches: ['vault 鎖定', '金鑰階層'], answer: '星期二傍晚寫在 Notes，當時 Safari 開著 vault-encryption 設計文件。' },
    ],
  },
  agents: {
    titleA: ['一條指令，'], titleB: ['任何 ', { em: 'agent。' }],
    body: '安裝一次 skill，Claude Code、Codex 與其他支援 Agent Skills 的工具就能查詢你的歷史，不需要 MCP，也不需要憑據。',
    toolsLabel: '接入你已經使用的 Agent', note: '唯讀。Vault 金鑰永不離開 daemon。',
    jailTitle: 'AfterRay 內建助手被關在籠子裡。',
    jailBody: '它讀取 vault 並回答，沒有第二種模式。沒有 HTTP 用戶端——它所在 crate 的依賴無法發請求。沒有 shell、沒有檔案系統工具——工具原始碼只要出現這些名稱，建置就失敗。',
    jailProof: '三個依賴、一條建置規則，一分鐘就能讀完。',
    jailCaveat: '使用本機模型時內容不離開 Mac；選擇雲端端點時，提示詞與所需證據會送到該服務。',
  },
  privacy: {
    statementA: ' 位元組', statementB: '離開你的 Mac。',
    pillars: [
      { title: '本機捕捉', body: '螢幕、系統音訊、麥克風、Accessibility 語意與輸入內容寫入 Mac 上的加密 vault。安全欄位與密碼管理器不會被讀取，原始輸入事件 48 小時後刪除。' },
      { title: '本機索引', body: 'OCR、語音辨識與語意 embedding 在裝置上執行，原始內容與向量不會離開。' },
      { title: '本機模型', body: '摘要與回答由本機模型產生，可使用內建 MLX 套件或自己的 Ollama。' },
      { title: '靜態加密', body: 'SQLCipher 與 XChaCha20-Poly1305 加密每筆記錄，金鑰存於 macOS Keychain。' },
    ],
  },
  specs: {
    steps: ['捕捉', 'OCR / ASR', 'Embedding', '加密 Vault', '本機 LLM', '回顧'],
    rows: [['平台', 'macOS 15+ · Apple 晶片（建議 M3）'], ['儲存', 'SQLCipher + XChaCha20-Poly1305，金鑰存於 Keychain'], ['磁碟', '較舊捕捉會重封裝為 closed-GOP AV1，約為原 JPEG 的 7–10%'], ['保留', '你設定的儲存預算，預設 100 GB；到達上限時先移除最舊內容'], ['模型', '本機 ASR、embedding、LLM，或自己的 Ollama / OpenAI 相容端點'], ['上傳', '沒有帳號、遙測或雲端同步；除非選擇遠端模型，否則內容不離開']],
  },
  final: { titleA: ['給你的 Mac'], titleB: ['一份', { em: '不會遺忘' }, '的記憶。'], ctaPrimary: '下載 macOS 版', ctaSecondary: 'GitHub' },
  footer: { tagline: '日子走後仍留下的那道光。', rights: '© 2026' },
}

const ja: LocaleText = {
  nav: { language: '言語', skip: '本文へ移動' },
  hero: {
    eyebrow: 'Macのためのプライベートなローカルファースト履歴',
    titleA: ['Macの'], titleB: ['プライベートかつ', { em: '検索できる記憶。' }],
    sub: 'AfterRayは画面と音声をMac内に記録します。いつでも再生・検索でき、エージェントからも参照できます。',
    ctaPrimary: 'macOS版をダウンロード', ctaSecondary: '記憶している内容を見る',
    facts: ['macOS 15以降', 'アプリとサイトを除外', 'いつでも一時停止・削除', 'Macの外へ送信しない'],
  },
  jtbd: [
    { title: '中断した場所から再開', body: '火曜日に途中で止めた移行を続けるよう頼めます。触ったファイルと時刻を確認できます。' },
    { title: '起きたことから回答', body: '「保持期間はどう決めた？」には、推測ではなく元の瞬間を添えて答えます。' },
    { title: '実際の作業から下書き', body: 'スタンドアップ、PR説明、引き継ぎを、記憶ではなく一週間の記録から作ります。' },
  ],
  recall: {
    body: 'どのアプリからでも ⇧⌘Space。タイムラインをドラッグして任意の瞬間へ戻れます。', status: '記録中',
    searchHint: '一日を検索 — TabでAIチャット', date: '8月14日 金曜日', hint: 'ドラッグで拡大 · スワイプで移動 · Escで閉じる', heardLabel: '聞いた内容', openLabel: '開く', you: 'あなた',
    transcript: ['タイムラインのズームはスクロールバーではなく、カメラのように感じるべきです。', '再生ヘッドを固定して、下のトラックだけ動かせますか？', 'はい。それがカメラのように感じる理由です。', 'スクラブ中はポスターフレームだけで十分です。停止後に補完できます。', 'ピークの原因はcold-still packing内の重複コピーです。', 'お気に入りは期限なし。それ以外は上限内に収めます。', '計測はHEIFが41ms、JPEGが63msです。'],
    recordTitles: ['afterrayd — agent.rs', 'hot-stills-cold-gop.md', '保持期間の案', 'デザインレビュー — 記録中', 'デザインレビュー — 記録中', 'PR #128 — 保持期間の議論', 'bench-codec — HEIF対JPEG'],
  },
  memories: {
    titleA: ['今日は多くのことをしました。'], titleB: ['これが', { em: 'その一日です。' }],
    body: 'AfterRayは一日を30分ごとにまとめます。モデルはローカルで動き、見ていないファイルやURL、タスクを作りません。',
    points: ['頼まなくても作業とともに記録', '各行から元の瞬間を開ける'], head: '8月14日 金曜日', label: '記憶',
    rows: ['afterraydのエージェントループを追い、保持期間のメモを書き始めました。', 'hot-stills-cold-gop.mdを読み、HEIFとJPEGのデコード経路を比較しました。', 'v1仕様のディスク章を仕上げました。', '通話中にGOPエンコーダーのメモリピークを調査し、PR #128を提出しました。'],
  },
  searchAsk: {
    titleA: ['うろ覚えでも。'], titleB: [{ em: '正確に見つかる。' }],
    body: 'ファイル名やアプリを忘れても、覚えている一言で十分です。質問することもできます。',
    points: ['OCRテキストと文字起こしを横断検索', 'キーワードだけでなく意味で検索', '回答から元の瞬間へ移動'],
    tryLabel: '試す', searchHead: '覚えていること', foundHead: '見つかった内容', askHead: 'または質問', screenLabel: '画面', heardLabel: '音声', replay: '再生',
    scenarios: [
      { chip: 'お気に入りの保持', keys: ['お気に入り', '保持', 'star', 'スター'], query: 'お気に入りを残す話', results: ['お気に入りは期限なし。それ以外は上限内に収める', 'PR #128 — 保存容量は未スターの瞬間だけに適用'], matches: ['お気に入りは期限なし', '保存容量'], answer: 'スターを付けた内容は期限がなく、設定した保存容量の対象外です。' },
      { chip: 'メモリピーク', keys: ['ピーク', 'メモリ', 'エンコーダ', 'gop'], query: '誰かが話していたメモリピーク', results: ['ピークはcold-still packing内の重複コピー', 'bench-codec — HEIF 41ms、JPEG 63ms'], matches: ['重複コピー', 'bench-codec'], answer: 'cold-still packing内の重複コピーが原因で、木曜午後に見つかり、その日の夜に削除されました。' },
      { chip: 'Vault鍵のメモ', keys: ['vault', '鍵', 'メモ', '書いた'], query: 'vault鍵の案を書いた場所', results: ['TODO: 先にvault lockテストを書く', 'docs/vault-encryption-design.md — 鍵階層'], matches: ['vault lock', '鍵階層'], answer: '火曜夕方、Safariで設計文書を開いていたときのNotesです。' },
    ],
  },
  agents: {
    titleA: ['コマンド一つで、'], titleB: ['どの', { em: 'エージェントにも。' }],
    body: 'Skillを一度入れれば、Claude Code、CodexなどAgent Skills対応ツールから履歴を検索できます。MCPも認証情報も不要です。',
    toolsLabel: '普段使うエージェントに接続', note: '読み取り専用。Vault鍵はdaemonから出ません。',
    jailTitle: 'AfterRay内蔵アシスタントには明確な境界があります。',
    jailBody: 'Vaultを読んで答えるだけです。第二のモードはありません。実行ループにHTTPクライアントはなく、シェルやファイルシステムのツールもありません。ビルドルールがそれらの名を検出すると失敗します。',
    jailProof: '依存関係は三つ、ビルドルールは一つ。1分で確認できます。',
    jailCaveat: 'ローカルモデルなら内容はMac内に残ります。クラウドのエンドポイントを選ぶと、プロンプトと必要な証拠がそのサービスへ送られます。',
  },
  privacy: {
    statementA: 'バイトも', statementB: 'Macの外へ出ません。',
    pillars: [
      { title: 'ローカルで記録', body: '画面、システム音声、マイク、Accessibility情報、入力内容をMac上の暗号化vaultへ保存します。セキュアフィールドとパスワードマネージャーは読み取らず、生の入力イベントは48時間後に削除します。' },
      { title: 'ローカルで索引', body: 'OCR、音声認識、セマンティック埋め込みは端末内で実行され、原文とベクトルは外へ出ません。' },
      { title: 'ローカルで推論', body: '要約と回答は、このMac上で動くモデル（内蔵MLXパックまたは自分のOllama）から得られます。' },
      { title: '保存時に暗号化', body: 'SQLCipherとXChaCha20-Poly1305で各記録を暗号化し、鍵はmacOS Keychainに保存します。' },
    ],
  },
  specs: {
    steps: ['記録', 'OCR / ASR', 'Embedding', '暗号化Vault', 'ローカルLLM', '回顧'],
    rows: [['対応環境', 'macOS 15以降 · Appleシリコン（M3推奨）'], ['保存', 'SQLCipher + XChaCha20-Poly1305、鍵はKeychain'], ['ディスク', '古い記録はclosed-GOP AV1へ再圧縮し、元JPEGの7〜10%'], ['保持', '既定100GBの保存容量。上限では古いものから削除'], ['モデル', '端末内ASR・埋め込み・LLM、またはOllama / OpenAI互換エンドポイント'], ['アップロード', 'アカウント・テレメトリ・クラウド同期なし。リモートモデルを選ばない限り送信なし']],
  },
  final: { titleA: ['Macに、'], titleB: [{ em: '忘れない記憶' }, 'を。'], ctaPrimary: 'macOS版をダウンロード', ctaSecondary: 'GitHub' },
  footer: { tagline: '一日が過ぎても残る光。', rights: '© 2026' },
}

const ko: LocaleText = {
  nav: { language: '언어', skip: '본문으로 이동' },
  hero: {
    eyebrow: 'Mac을 위한 비공개 로컬 우선 컴퓨터 기록', titleA: ['Mac의'], titleB: ['비공개 ', { em: '검색형 기억.' }],
    sub: 'AfterRay는 화면과 오디오를 Mac에 기록합니다. 원하는 순간을 재생하고 검색하거나 에이전트가 찾아보게 할 수 있습니다.',
    ctaPrimary: 'macOS용 다운로드', ctaSecondary: '기억하는 내용 보기', facts: ['macOS 15+', '앱과 사이트 제외', '언제든 일시 정지·삭제', 'Mac 밖으로 전송하지 않음'],
  },
  jtbd: [
    { title: '멈춘 곳에서 이어가기', body: '화요일에 중단한 마이그레이션을 계속해 달라고 하세요. 어떤 파일을 언제 다뤘는지 찾을 수 있습니다.' },
    { title: '실제로 일어난 일로 답하기', body: '“보존 정책은 어떻게 정했지?”라는 질문에 추측이 아닌 원래 순간으로 답합니다.' },
    { title: '실제 작업으로 초안 만들기', body: '스탠드업, PR 설명, 인수인계를 기억이 아닌 한 주의 기록에서 작성합니다.' },
  ],
  recall: {
    body: '어느 앱에서든 ⇧⌘Space. 타임라인을 끌어 원하는 순간으로 돌아가세요.', status: '기록 중', searchHint: '하루 검색 — Tab으로 AI 채팅', date: '8월 14일 금요일', hint: '드래그로 확대 · 스와이프로 이동 · Esc로 닫기', heardLabel: '들은 내용', openLabel: '열기', you: '나',
    transcript: ['타임라인 확대는 스크롤바가 아니라 카메라처럼 느껴져야 해요.', '재생 헤드를 고정하고 트랙만 아래에서 움직일 수 있을까요?', '네, 바로 그 점이 카메라처럼 느껴지게 해요.', '스크러빙 중에는 포스터 프레임만 있으면 돼요. 멈춘 뒤 채우면 됩니다.', '피크는 cold-still packing의 중복 복사 때문이에요.', '즐겨찾기는 만료되지 않고 나머지만 한도 안에 둡니다.', '벤치는 HEIF 41ms, JPEG 63ms예요.'],
    recordTitles: ['afterrayd — agent.rs', 'hot-stills-cold-gop.md', '보존 아이디어', '디자인 리뷰 — 녹화', '디자인 리뷰 — 녹화', 'PR #128 — 보존 논의', 'bench-codec — HEIF 대 JPEG'],
  },
  memories: {
    titleA: ['오늘 많은 일을 했습니다.'], titleB: ['이것이 ', { em: '그 하루입니다.' }], body: 'AfterRay가 하루를 30분 단위로 정리합니다. 로컬 모델은 보지 않은 파일, URL, 작업을 만들어 내지 않습니다.',
    points: ['요청하지 않아도 작업하며 자동 작성', '각 줄에서 원래 순간 열기'], head: '8월 14일 금요일', label: '기억',
    rows: ['afterrayd의 에이전트 루프를 추적하고 보존 메모를 시작했습니다.', 'hot-stills-cold-gop.md를 읽고 HEIF와 JPEG 디코드 경로를 비교했습니다.', 'v1 사양의 디스크 장을 마무리했습니다.', '통화 중 GOP 인코더 메모리 피크를 디버깅하고 PR #128을 제출했습니다.'],
  },
  searchAsk: {
    titleA: ['어렴풋이 기억해도.'], titleB: [{ em: '정확히 찾습니다.' }], body: '파일명과 앱을 잊어도 괜찮습니다. 기억나는 한 구절이면 충분하고, 바로 질문해도 됩니다.',
    points: ['OCR 텍스트와 전사를 함께 검색', '키워드가 아닌 의미로 검색', '답변에서 원래 순간을 인용'], tryLabel: '예시', searchHead: '어렴풋이 기억한 내용', foundHead: '찾은 결과', askHead: '또는 질문', screenLabel: '화면', heardLabel: '오디오', replay: '재생',
    scenarios: [
      { chip: '즐겨찾기 보존', keys: ['즐겨찾기', '보존', 'star', '별표'], query: '즐겨찾기를 유지하는 얘기', results: ['즐겨찾기는 만료되지 않고 나머지만 한도 안에 둔다', 'PR #128 — 저장 예산은 별표 없는 순간에만 적용'], matches: ['즐겨찾기는 만료되지 않음', '저장 예산'], answer: '별표를 붙인 항목은 만료되지 않으며 설정한 저장 예산에서 제외됩니다.' },
      { chip: '메모리 피크', keys: ['피크', '메모리', '인코더', 'gop'], query: '누군가 말한 메모리 피크', results: ['피크는 cold-still packing의 중복 복사', 'bench-codec — HEIF 41ms, JPEG 63ms'], matches: ['중복 복사', 'bench-codec'], answer: 'cold-still packing의 중복 복사가 원인이었고 목요일 오후에 발견해 그날 저녁 제거했습니다.' },
      { chip: 'Vault 키 메모', keys: ['vault', '키', '메모', '적은'], query: 'vault 키 아이디어를 적은 곳', results: ['할 일: vault 잠금 테스트부터 작성', 'docs/vault-encryption-design.md — 키 계층'], matches: ['vault 잠금', '키 계층'], answer: '화요일 저녁 Safari에서 설계 문서를 열어 둔 채 Notes에 작성했습니다.' },
    ],
  },
  agents: {
    titleA: ['명령 하나로,'], titleB: ['어떤 ', { em: '에이전트든.' }], body: 'Skill을 한 번 설치하면 Claude Code, Codex 등 Agent Skills를 지원하는 도구가 기록을 조회할 수 있습니다. MCP나 자격 증명이 필요 없습니다.',
    toolsLabel: '이미 사용하는 에이전트에 연결', note: '읽기 전용. Vault 키는 daemon을 벗어나지 않습니다.', jailTitle: 'AfterRay 내장 어시스턴트에는 명확한 경계가 있습니다.',
    jailBody: 'Vault를 읽고 답할 뿐입니다. 두 번째 모드는 없습니다. 실행 루프에는 HTTP 클라이언트가 없고, 셸이나 파일 시스템 도구도 없습니다. 빌드 규칙이 이런 도구의 이름을 감지하면 실패합니다.', jailProof: '의존성 세 개와 빌드 규칙 하나. 1분이면 확인할 수 있습니다.', jailCaveat: '로컬 모델은 내용을 Mac에 남깁니다. 클라우드 엔드포인트를 선택하면 프롬프트와 필요한 증거가 해당 서비스로 전송됩니다.',
  },
  privacy: {
    statementA: '바이트도', statementB: 'Mac 밖으로 나가지 않습니다.', pillars: [
      { title: '로컬 캡처', body: '화면, 시스템 오디오, 마이크, Accessibility 의미 정보와 입력 내용을 Mac의 암호화 vault에 저장합니다. 보안 필드와 암호 관리자는 읽지 않으며 원시 입력 이벤트는 48시간 후 삭제합니다.' },
      { title: '로컬 인덱싱', body: 'OCR, 음성 인식, 시맨틱 임베딩이 기기에서 실행되며 원문과 벡터는 외부로 나가지 않습니다.' },
      { title: '로컬 모델', body: '요약과 답변은 이 기기에서 실행되는 모델에서 나옵니다. 내장 MLX 팩 또는 사용자의 Ollama입니다.' },
      { title: '저장 시 암호화', body: 'SQLCipher와 XChaCha20-Poly1305로 각 기록을 암호화하고 키는 macOS Keychain에 보관합니다.' },
    ],
  },
  specs: { steps: ['캡처', 'OCR / ASR', 'Embedding', '암호화 Vault', '로컬 LLM', '회상'], rows: [['플랫폼', 'macOS 15+ · Apple Silicon(M3 권장)'], ['저장소', 'SQLCipher + XChaCha20-Poly1305, Keychain에 키 보관'], ['디스크', '오래된 캡처는 closed-GOP AV1로 재압축되어 원본 JPEG의 7–10%'], ['보존', '기본 100GB 저장 예산. 한도 도달 시 가장 오래된 항목부터 삭제'], ['모델', '기기 내 ASR·임베딩·LLM 또는 Ollama / OpenAI 호환 엔드포인트'], ['업로드', '계정·텔레메트리·클라우드 동기화 없음. 원격 모델을 선택하지 않으면 전송 없음']] },
  final: { titleA: ['Mac에'], titleB: [{ em: '잊지 않는 기억' }, '을.'], ctaPrimary: 'macOS용 다운로드', ctaSecondary: 'GitHub' }, footer: { tagline: '하루가 지나도 남는 빛.', rights: '© 2026' },
}

const es: LocaleText = {
  nav: { language: 'Idioma', skip: 'Ir al contenido' },
  hero: { eyebrow: 'Historial privado, primero local, para Mac', titleA: ['La memoria'], titleB: ['privada y ', { em: 'buscable de tu Mac.' }], sub: 'AfterRay registra pantalla y audio en tu Mac para que puedas volver a cualquier momento, buscar lo que viste u oíste y dejar que tu agente lo consulte.', ctaPrimary: 'Descargar para macOS', ctaSecondary: 'Ver lo que recuerda', facts: ['macOS 15+', 'Excluye apps y sitios', 'Pausa o borra cuando quieras', 'Nada sale de este Mac'] },
  jtbd: [{ title: 'Continúa donde lo dejaste', body: 'Pídele que termine la migración que dejaste a medias el martes. Sabe qué archivos tocaste y cuándo.' }, { title: 'Responde desde lo ocurrido', body: '«¿Qué decidimos sobre la retención?» vuelve con el momento original, no con una suposición.' }, { title: 'Redacta desde tu trabajo', body: 'La nota diaria, la descripción del PR o el traspaso se escriben desde la semana real, no de memoria.' }],
  recall: { body: 'Pulsa ⇧⌘Espacio desde cualquier app. Arrastra la línea temporal hasta cualquier momento.', status: 'Grabando', searchHint: 'Busca en tu día — Tab para chat con IA', date: 'Viernes, 14 de agosto', hint: 'Arrastra para ampliar · Desliza para viajar · Esc para cerrar', heardLabel: 'Oído', openLabel: 'Abrir', you: 'Tú', transcript: ['El zoom de la línea temporal debe sentirse como una cámara, no como una barra.', '¿Podemos fijar el cabezal y mover la pista por debajo?', 'Sí: eso es lo que hace que parezca una cámara.', 'Al desplazar solo necesitamos el fotograma de muestra; completamos al parar.', 'El pico es una copia duplicada en el empaquetado cold-still.', 'Los favoritos nunca caducan; el resto queda limitado.', 'La prueba da 41 ms para HEIF y 63 para JPEG.'], recordTitles: ['afterrayd — agent.rs', 'hot-stills-cold-gop.md', 'ideas de retención', 'revisión de diseño — grabación', 'revisión de diseño — grabación', 'PR #128 — debate de retención', 'bench-codec — HEIF frente a JPEG'] },
  memories: { titleA: ['Hoy hiciste mucho.'], titleB: ['Aquí está ', { em: 'tu día.' }], body: 'AfterRay reconstruye tu día en bloques de media hora. El modelo se ejecuta aquí y no inventa archivos, URL ni tareas que no haya visto.', points: ['Se escribe mientras trabajas, sin pedirlo', 'Cada línea abre el momento que la originó'], head: 'Viernes, 14 de agosto', label: 'Recuerdos', rows: ['Seguí el bucle del agente en afterrayd y empecé una nota sobre retención.', 'Leí hot-stills-cold-gop.md y comparé las rutas de decodificación HEIF y JPEG.', 'Terminé el capítulo de disco de la especificación v1.', 'Depuré el pico de memoria del codificador GOP durante una llamada y abrí el PR #128.'] },
  searchAsk: { titleA: ['Recuérdalo a medias.'], titleB: ['Encuéntralo ', { em: 'exactamente.' }], body: 'Olvida el nombre del archivo y la app. Basta una frase aproximada, o pregunta directamente.', points: ['Búsqueda conjunta en OCR y transcripciones', 'Búsqueda por significado, no solo palabras', 'Respuestas con citas a los momentos originales'], tryLabel: 'Prueba', searchHead: 'Lo recuerdas a medias', foundHead: 'Lo encuentra', askHead: 'O pregunta', screenLabel: 'En pantalla', heardLabel: 'Oído', replay: 'Reproducir', scenarios: [
    { chip: 'Conservar favoritos', keys: ['favoritos', 'conservar', 'estrella'], query: 'aquello sobre conservar favoritos', results: ['los favoritos nunca caducan; el resto queda limitado', 'PR #128 — el presupuesto solo afecta a momentos sin estrella'], matches: ['favoritos nunca caducan', 'presupuesto'], answer: 'Todo lo marcado con estrella queda exento y no caduca. Lo demás usa el presupuesto que configures.' },
    { chip: 'El pico de memoria', keys: ['pico', 'memoria', 'codificador', 'gop'], query: 'el pico de memoria que mencionaron', results: ['el pico es una copia duplicada en cold-still packing', 'bench-codec — HEIF 41 ms frente a JPEG 63 ms'], matches: ['copia duplicada', 'bench-codec'], answer: 'Era una copia duplicada en cold-still packing. Se detectó el jueves y se eliminó esa misma tarde.' },
    { chip: 'La nota de la clave', keys: ['vault', 'clave', 'nota', 'anoté'], query: 'dónde anoté la idea de la clave del vault', results: ['pendiente: escribir primero la prueba de bloqueo del vault', 'docs/vault-encryption-design.md — jerarquía de claves'], matches: ['bloqueo del vault', 'jerarquía de claves'], answer: 'En Notes el martes por la tarde, con el documento de diseño abierto en Safari.' },
  ] },
  agents: { titleA: ['Un comando,'], titleB: ['cualquier ', { em: 'agente.' }], body: 'Instala el skill una vez. Claude Code, Codex y cualquier herramienta compatible con Agent Skills podrán consultar tu historial sin MCP ni credenciales.', toolsLabel: 'Funciona con los agentes que ya utilizas', note: 'Solo lectura. La clave del vault nunca sale del daemon.', jailTitle: 'El asistente de AfterRay tiene un límite explícito.', jailBody: 'Solo lee el vault y responde, y no tiene un segundo modo. Su bucle no incluye cliente HTTP ni herramientas de shell o de sistema de archivos; una regla de compilación falla si una herramienta llega a nombrarlas.', jailProof: 'Tres dependencias y una regla de compilación. Se comprueba en un minuto.', jailCaveat: 'Con un modelo local, el contenido permanece en el Mac. Si eliges un endpoint remoto, el prompt y las pruebas necesarias se envían a ese servicio.' },
  privacy: { statementA: ' bytes', statementB: 'salen de tu Mac.', pillars: [{ title: 'Captura local', body: 'Pantalla, audio del sistema, micrófono, semántica de Accessibility y entradas se guardan en un vault cifrado del Mac. No se leen campos seguros ni gestores de contraseñas; los eventos de entrada sin procesar se eliminan tras 48 horas.' }, { title: 'Índice local', body: 'OCR, reconocimiento de voz y embeddings semánticos se ejecutan en el dispositivo. El contenido y los vectores no salen.' }, { title: 'Modelos locales', body: 'Los resúmenes y las respuestas salen de un modelo que corre en tu máquina: el paquete MLX incluido o tu propio Ollama.' }, { title: 'Cifrado en reposo', body: 'SQLCipher y XChaCha20-Poly1305 cifran cada registro. La clave vive en el llavero de macOS.' }] },
  specs: { steps: ['Captura', 'OCR / ASR', 'Embedding', 'Vault cifrado', 'LLM local', 'Recuerdo'], rows: [['Plataforma', 'macOS 15+ · Apple silicon (M3 recomendado)'], ['Almacenamiento', 'SQLCipher + XChaCha20-Poly1305, clave en el llavero'], ['En disco', 'Las capturas antiguas se convierten a AV1 closed-GOP: 7–10 % del JPEG'], ['Retención', 'Presupuesto configurable, 100 GB por defecto; se borra primero lo más antiguo'], ['Modelos', 'ASR, embeddings y LLM locales, o endpoint Ollama / OpenAI compatible'], ['Subidas', 'Sin cuenta, sin telemetría y sin sincronización en la nube; nada sale salvo que elijas un modelo remoto']] },
  final: { titleA: ['Dale a tu Mac'], titleB: ['una memoria que ', { em: 'no olvida.' }], ctaPrimary: 'Descargar para macOS', ctaSecondary: 'GitHub' }, footer: { tagline: 'Una luz que permanece cuando termina el día.', rights: '© 2026' },
}

const de: LocaleText = {
  nav: { language: 'Sprache', skip: 'Zum Inhalt springen' },
  hero: { eyebrow: 'Privater, zuerst lokaler Computerverlauf für den Mac', titleA: ['Das private,'], titleB: [{ em: 'durchsuchbare Gedächtnis' }, ' deines Mac.'], sub: 'AfterRay zeichnet Bildschirm und Audio lokal auf. So kannst du Momente wiedergeben, Erlebtes durchsuchen und deinen Agenten nachsehen lassen.', ctaPrimary: 'Für macOS laden', ctaSecondary: 'Sehen, woran AfterRay sich erinnert', facts: ['macOS 15+', 'Apps und Websites ausschließen', 'Jederzeit pausieren oder löschen', 'Nichts verlässt diesen Mac'] },
  jtbd: [{ title: 'Dort weitermachen, wo du aufgehört hast', body: 'Lass die am Dienstag unterbrochene Migration fortsetzen. AfterRay kennt die bearbeiteten Dateien und Zeitpunkte.' }, { title: 'Aus Geschehenem antworten', body: '„Was haben wir zur Aufbewahrung beschlossen?“ kommt mit dem ursprünglichen Moment zurück, nicht als Vermutung.' }, { title: 'Aus der Arbeit formulieren', body: 'Stand-up, PR-Beschreibung und Übergabe entstehen aus der echten Woche statt aus dem Gedächtnis.' }],
  recall: { body: '⇧⌘Leertaste aus jeder App. Ziehe die Zeitleiste zu einem beliebigen Moment.', status: 'Aufnahme', searchHint: 'Tag durchsuchen — Tab für KI-Chat', date: 'Freitag, 14. August', hint: 'Ziehen zum Zoomen · Wischen zum Reisen · Esc zum Schließen', heardLabel: 'Gehört', openLabel: 'Öffnen', you: 'Du', transcript: ['Der Zoom der Zeitleiste muss sich wie eine Kamera anfühlen, nicht wie eine Scrollleiste.', 'Können wir den Abspielkopf fixieren und die Spur darunter bewegen?', 'Ja — genau dadurch fühlt es sich wie eine Kamera an.', 'Beim Scrubben genügt das Vorschaubild; den Rest laden wir danach.', 'Der Peak ist eine doppelte Kopie beim cold-still packing.', 'Favoriten laufen nie ab. Alles andere bleibt begrenzt.', 'Der Benchmark sagt HEIF 41 ms, JPEG 63 ms.'], recordTitles: ['afterrayd — agent.rs', 'hot-stills-cold-gop.md', 'Ideen zur Aufbewahrung', 'Design-Review — Aufnahme', 'Design-Review — Aufnahme', 'PR #128 — Aufbewahrungsdiskussion', 'bench-codec — HEIF gegen JPEG'] },
  memories: { titleA: ['Heute hast du viel geschafft.'], titleB: ['Das war ', { em: 'dein Tag.' }], body: 'AfterRay schreibt den Tag in halbstündigen Abschnitten zurück. Das lokale Modell erfindet keine Dateien, URLs oder Aufgaben, die es nicht gesehen hat.', points: ['Entsteht während der Arbeit, ohne Nachfrage', 'Jede Zeile öffnet den ursprünglichen Moment'], head: 'Freitag, 14. August', label: 'Erinnerungen', rows: ['Agent-Schleife in afterrayd verfolgt und eine Notiz zur Aufbewahrung begonnen.', 'hot-stills-cold-gop.md gelesen und HEIF- mit JPEG-Decodierung verglichen.', 'Das Festplattenkapitel der v1-Spezifikation abgeschlossen.', 'Im Gespräch den Speicher-Peak des GOP-Encoders untersucht und PR #128 erstellt.'] },
  searchAsk: { titleA: ['Nur halb erinnert.'], titleB: [{ em: 'Trotzdem genau gefunden.' }], body: 'Dateiname und App vergessen? Eine ungefähre Formulierung reicht — oder du fragst direkt.', points: ['Gemeinsame Suche in OCR und Transkripten', 'Semantische Suche nach Bedeutung', 'Antworten mit Verweisen auf Originalmomente'], tryLabel: 'Ausprobieren', searchHead: 'Du erinnerst dich', foundHead: 'AfterRay findet', askHead: 'Oder frag direkt', screenLabel: 'Auf dem Bildschirm', heardLabel: 'Gehört', replay: 'Wiedergeben', scenarios: [
    { chip: 'Favoriten behalten', keys: ['favoriten', 'behalten', 'stern'], query: 'die Sache mit dem Behalten von Favoriten', results: ['Favoriten laufen nie ab — alles andere bleibt begrenzt', 'PR #128 — das Speicherbudget gilt nur für Momente ohne Stern'], matches: ['Favoriten laufen nie ab', 'Speicherbudget'], answer: 'Markierte Inhalte sind ausgenommen und laufen nie ab. Alles andere nutzt dein festgelegtes Speicherbudget.' },
    { chip: 'Der Speicher-Peak', keys: ['peak', 'speicher', 'encoder', 'gop'], query: 'der erwähnte Speicher-Peak', results: ['der Peak ist eine doppelte Kopie beim cold-still packing', 'bench-codec — HEIF 41 ms, JPEG 63 ms'], matches: ['doppelte Kopie', 'bench-codec'], answer: 'Eine doppelte Kopie beim cold-still packing. Donnerstagnachmittag gefunden und am selben Abend entfernt.' },
    { chip: 'Notiz zum Vault-Schlüssel', keys: ['vault', 'schlüssel', 'notiz', 'notiert'], query: 'wo ich die Idee zum Vault-Schlüssel notiert habe', results: ['TODO: zuerst den Vault-Locking-Test schreiben', 'docs/vault-encryption-design.md — Schlüsselhierarchie'], matches: ['Vault-Locking', 'Schlüsselhierarchie'], answer: 'Dienstagabend in Notes, während das Vault-Design in Safari geöffnet war.' },
  ] },
  agents: { titleA: ['Ein Befehl,'], titleB: ['jeder ', { em: 'Agent.' }], body: 'Installiere den Skill einmal. Claude Code, Codex und andere Agent-Skills-Tools können den Verlauf dann ohne MCP-Server oder Zugangsdaten abfragen.', toolsLabel: 'Passt zu deinen vorhandenen Agenten', note: 'Schreibgeschützt. Der Vault-Schlüssel verlässt den Daemon nie.', jailTitle: 'Der integrierte Assistent hat eine klare Grenze.', jailBody: 'Er liest den Vault und antwortet, und er hat keinen zweiten Modus. Seine Laufzeit enthält keinen HTTP-Client und keine Shell- oder Dateisystem-Werkzeuge; eine Build-Regel schlägt fehl, wenn ein Werkzeug sie auch nur nennt.', jailProof: 'Drei Abhängigkeiten und eine Build-Regel. In einer Minute prüfbar.', jailCaveat: 'Mit lokalem Modell bleibt alles auf dem Mac. Bei einem Cloud-Endpoint gehen Prompt und benötigte Belege an diesen Dienst.' },
  privacy: { statementA: ' Bytes', statementB: 'verlassen deinen Mac.', pillars: [{ title: 'Lokal erfasst', body: 'Bildschirm, Systemaudio, Mikrofon, Accessibility-Semantik und Eingaben landen im verschlüsselten Vault auf dem Mac. Sichere Felder und Passwortmanager werden nicht gelesen; rohe Eingabeereignisse werden nach 48 Stunden gelöscht.' }, { title: 'Lokal indexiert', body: 'OCR, Spracherkennung und semantische Embeddings laufen auf dem Gerät. Inhalte und Vektoren bleiben dort.' }, { title: 'Lokal modelliert', body: 'Zusammenfassungen und Antworten stammen von einem Modell, das auf deinem Rechner läuft — dem mitgelieferten MLX-Paket oder deinem eigenen Ollama.' }, { title: 'Verschlüsselt gespeichert', body: 'SQLCipher und XChaCha20-Poly1305 verschlüsseln jeden Eintrag. Der Schlüssel liegt im macOS-Schlüsselbund.' }] },
  specs: { steps: ['Erfassen', 'OCR / ASR', 'Embedding', 'Verschlüsselter Vault', 'Lokales LLM', 'Rückblick'], rows: [['Plattform', 'macOS 15+ · Apple Silicon (M3 empfohlen)'], ['Speicher', 'SQLCipher + XChaCha20-Poly1305, Schlüssel im Schlüsselbund'], ['Auf Platte', 'Ältere Aufnahmen werden zu closed-GOP AV1: 7–10 % der JPEG-Größe'], ['Aufbewahrung', 'Konfigurierbares Budget, standardmäßig 100 GB; älteste Daten zuerst'], ['Modelle', 'Lokale ASR, Embeddings und LLM oder Ollama / OpenAI-kompatibler Endpoint'], ['Upload', 'Kein Konto, keine Telemetrie, kein Cloud-Sync — es verlässt nichts den Mac, außer du richtest es auf ein Remote-Modell']] },
  final: { titleA: ['Gib deinem Mac'], titleB: ['ein Gedächtnis, das ', { em: 'nichts vergisst.' }], ctaPrimary: 'Für macOS laden', ctaSecondary: 'GitHub' }, footer: { tagline: 'Ein Licht, das bleibt, wenn der Tag vergangen ist.', rights: '© 2026' },
}

const fr: LocaleText = {
  nav: { language: 'Langue', skip: 'Aller au contenu' },
  hero: { eyebrow: 'Historique privé, local, sur l’appareil, pour Mac', titleA: ['La mémoire'], titleB: ['privée et ', { em: 'consultable de votre Mac.' }], sub: 'AfterRay enregistre l’écran et le son sur votre Mac afin de revoir n’importe quel instant, rechercher ce que vous avez vu ou entendu et laisser votre agent le consulter.', ctaPrimary: 'Télécharger pour macOS', ctaSecondary: 'Voir ce qu’AfterRay mémorise', facts: ['macOS 15+', 'Exclure apps et sites', 'Suspendre ou supprimer à tout moment', 'Rien ne quitte ce Mac'] },
  jtbd: [{ title: 'Reprendre là où vous étiez', body: 'Demandez-lui de terminer la migration laissée en suspens mardi. Il sait quels fichiers ont été touchés et quand.' }, { title: 'Répondre depuis les faits', body: '« Qu’avons-nous décidé pour la rétention ? » revient avec l’instant d’origine, pas une supposition.' }, { title: 'Rédiger depuis le travail réel', body: 'Compte rendu, description de PR et passation sont écrits depuis la semaine vécue, pas de mémoire.' }],
  recall: { body: '⇧⌘Espace depuis n’importe quelle app. Faites glisser la chronologie vers l’instant voulu.', status: 'Enregistrement', searchHint: 'Rechercher dans la journée — Tab pour le chat IA', date: 'Vendredi 14 août', hint: 'Glisser pour zoomer · Balayer pour voyager · Échap pour fermer', heardLabel: 'Entendu', openLabel: 'Ouvrir', you: 'Vous', transcript: ['Le zoom de la chronologie doit ressembler à une caméra, pas à une barre de défilement.', 'Peut-on fixer la tête de lecture et déplacer la piste dessous ?', 'Oui — c’est ce qui donne l’impression d’une caméra.', 'Pendant le défilement, l’image d’aperçu suffit ; on complète à l’arrêt.', 'Le pic vient d’une copie en double dans le cold-still packing.', 'Les favoris n’expirent jamais. Le reste reste limité.', 'Le test donne 41 ms pour HEIF et 63 pour JPEG.'], recordTitles: ['afterrayd — agent.rs', 'hot-stills-cold-gop.md', 'idées de rétention', 'revue de conception — enregistrement', 'revue de conception — enregistrement', 'PR #128 — discussion sur la rétention', 'bench-codec — HEIF contre JPEG'] },
  memories: { titleA: ['Vous avez beaucoup fait aujourd’hui.'], titleB: ['Voici ', { em: 'votre journée.' }], body: 'AfterRay restitue votre journée par tranches de trente minutes. Le modèle local n’invente aucun fichier, URL ou tâche qu’il n’a pas vu.', points: ['Écrit au fil du travail, sans demande', 'Chaque ligne ouvre l’instant qui l’a produite'], head: 'Vendredi 14 août', label: 'Souvenirs', rows: ['Suivi la boucle agent dans afterrayd, puis commencé une note sur la rétention.', 'Lu hot-stills-cold-gop.md et comparé les chemins de décodage HEIF et JPEG.', 'Terminé le chapitre disque de la spécification v1.', 'Débogué le pic mémoire de l’encodeur GOP pendant un appel, puis ouvert la PR #128.'] },
  searchAsk: { titleA: ['Un souvenir imprécis.'], titleB: ['Retrouvé ', { em: 'exactement.' }], body: 'Oubliez le nom du fichier et l’app. Une phrase approximative suffit — ou posez directement la question.', points: ['Recherche conjointe dans OCR et transcriptions', 'Recherche par sens, pas seulement par mots', 'Réponses citées vers les instants d’origine'], tryLabel: 'Essayer', searchHead: 'Vous vous souvenez', foundHead: 'AfterRay retrouve', askHead: 'Ou demandez', screenLabel: 'À l’écran', heardLabel: 'Entendu', replay: 'Revoir', scenarios: [
    { chip: 'Conserver les favoris', keys: ['favoris', 'conservation', 'étoile'], query: 'ce passage sur la conservation des favoris', results: ['les favoris n’expirent jamais — le reste reste limité', 'PR #128 — le budget ne concerne que les instants sans étoile'], matches: ['favoris n’expirent jamais', 'budget'], answer: 'Tout élément étoilé est exempté et n’expire jamais. Le reste utilise le budget de stockage défini.' },
    { chip: 'Le pic mémoire', keys: ['pic', 'mémoire', 'encodeur', 'gop'], query: 'le pic mémoire dont quelqu’un a parlé', results: ['le pic est une copie en double dans le cold-still packing', 'bench-codec — HEIF 41 ms contre JPEG 63 ms'], matches: ['copie en double', 'bench-codec'], answer: 'Une copie en double dans le cold-still packing, détectée jeudi après-midi et retirée le soir même.' },
    { chip: 'La note sur la clé', keys: ['vault', 'clé', 'note', 'noté'], query: 'où j’ai noté l’idée de clé du vault', results: ['à faire : écrire d’abord le test de verrouillage du vault', 'docs/vault-encryption-design.md — hiérarchie des clés'], matches: ['verrouillage du vault', 'hiérarchie des clés'], answer: 'Dans Notes mardi soir, avec le document de conception du vault ouvert dans Safari.' },
  ] },
  agents: { titleA: ['Une commande,'], titleB: ['n’importe quel ', { em: 'agent.' }], body: 'Installez le skill une fois. Claude Code, Codex et tout outil compatible Agent Skills peuvent ensuite consulter votre historique, sans serveur MCP ni identifiants.', toolsLabel: 'S’intègre aux agents que vous utilisez déjà', note: 'Lecture seule. La clé du vault ne quitte jamais le daemon.', jailTitle: 'L’assistant intégré reste dans une frontière explicite.', jailBody: 'Il lit le vault et répond, sans second mode. Sa boucle n’a ni client HTTP ni outils de shell ou de système de fichiers ; une règle de build échoue si un outil les nomme seulement.', jailProof: 'Trois dépendances et une règle de build, vérifiables en une minute.', jailCaveat: 'Avec un modèle local, tout reste sur le Mac. Avec un endpoint distant, le prompt et les preuves nécessaires sont envoyés à ce service.' },
  privacy: { statementA: ' octet', statementB: 'ne quitte pas votre Mac.', pillars: [{ title: 'Capture locale', body: 'Écran, audio système, micro, sémantique Accessibility et saisies sont écrits dans un vault chiffré sur le Mac. Les champs sécurisés et gestionnaires de mots de passe ne sont pas lus ; les événements de saisie bruts sont supprimés après 48 heures.' }, { title: 'Indexation locale', body: 'OCR, reconnaissance vocale et embeddings sémantiques s’exécutent sur l’appareil. Contenu brut et vecteurs n’en sortent pas.' }, { title: 'Modèles locaux', body: 'Les résumés et réponses viennent d’un modèle qui s’exécute sur votre machine — le pack MLX intégré ou votre propre Ollama.' }, { title: 'Chiffrement au repos', body: 'SQLCipher et XChaCha20-Poly1305 chiffrent chaque élément. La clé reste dans le trousseau macOS.' }] },
  specs: { steps: ['Enregistrement', 'OCR / ASR', 'Embedding', 'Vault chiffré', 'LLM local', 'Rappel'], rows: [['Plateforme', 'macOS 15+ · Apple silicon (M3 recommandé)'], ['Stockage', 'SQLCipher + XChaCha20-Poly1305, clé dans le trousseau'], ['Sur disque', 'Les anciennes captures passent en AV1 closed-GOP : 7 à 10 % du JPEG'], ['Rétention', 'Budget réglable, 100 Go par défaut ; les plus anciennes données partent d’abord'], ['Modèles', 'ASR, embeddings et LLM locaux ou endpoint Ollama / compatible OpenAI'], ['Envoi', 'Sans compte, sans télémétrie, sans synchronisation cloud ; rien ne sort sauf si vous pointez un modèle distant']] },
  final: { titleA: ['Donnez à votre Mac'], titleB: ['une mémoire qui ', { em: 'n’oublie rien.' }], ctaPrimary: 'Télécharger pour macOS', ctaSecondary: 'GitHub' }, footer: { tagline: 'Une lueur qui demeure une fois la journée passée.', rights: '© 2026' },
}

export function makeExtraCopies(base: Copy): Omit<Record<Lang, Copy>, 'en' | 'zh-Hans'> {
  return {
    'zh-Hant': localizedCopy(base, zhHant),
    ja: localizedCopy(base, ja),
    ko: localizedCopy(base, ko),
    es: localizedCopy(base, es),
    de: localizedCopy(base, de),
    fr: localizedCopy(base, fr),
  }
}
