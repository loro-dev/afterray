import { LangProvider, useCopy, useLang, type Lang } from './i18n'
import LangMenu from './components/LangMenu'
import Hero from './sections/Hero'
import Agents from './sections/Agents'
import Jtbd from './sections/Jtbd'
import Memories from './sections/Memories'
import SearchAsk from './sections/SearchAsk'
import Closer from './sections/Closer'
import InfoPage from './pages/InfoPage'
import { pathFor, type SiteRoute } from './routes'

const FOOTER_LABELS: Record<Lang, {
  home: string
  privacy: string
  security: string
  download: string
  source: string
  nav: string
  github: string
}> = {
  en: { home: 'Home', privacy: 'Privacy', security: 'Security', download: 'Download', source: 'Source', nav: 'Footer', github: 'GitHub repository' },
  'zh-Hans': { home: '首页', privacy: '隐私', security: '安全', download: '下载', source: '源码', nav: '页脚导航', github: 'GitHub 仓库' },
  'zh-Hant': { home: '首頁', privacy: '隱私', security: '安全', download: '下載', source: '原始碼', nav: '頁尾導覽', github: 'GitHub 儲存庫' },
  ja: { home: 'ホーム', privacy: 'プライバシー', security: 'セキュリティ', download: 'ダウンロード', source: 'ソース', nav: 'フッター', github: 'GitHubリポジトリ' },
  ko: { home: '홈', privacy: '개인정보', security: '보안', download: '다운로드', source: '소스', nav: '바닥글', github: 'GitHub 저장소' },
  es: { home: 'Inicio', privacy: 'Privacidad', security: 'Seguridad', download: 'Descargar', source: 'Código', nav: 'Pie de página', github: 'Repositorio de GitHub' },
  de: { home: 'Start', privacy: 'Datenschutz', security: 'Sicherheit', download: 'Download', source: 'Quellcode', nav: 'Fußzeile', github: 'GitHub-Repository' },
  fr: { home: 'Accueil', privacy: 'Confidentialité', security: 'Sécurité', download: 'Télécharger', source: 'Code source', nav: 'Pied de page', github: 'Dépôt GitHub' },
}

function Nav({ route }: { route: SiteRoute }) {
  const labels = FOOTER_LABELS[route.lang]
  return (
    <nav className="nav">
      <a className="nav-logo" href={pathFor('home', route.lang)}>
        <img src="/logo.png" alt="" className="logo-img" width="22" height="22" />
        <span className="mono">AfterRay</span>
      </a>
      <div className="nav-actions">
        <a
          className="nav-repo mono"
          href="https://github.com/loro-dev/afterray"
          target="_blank"
          rel="noreferrer"
          aria-label={labels.github}
        >
          GitHub
          <span aria-hidden="true">↗</span>
        </a>
        <LangMenu route={route} />
      </div>
    </nav>
  )
}

function SkipLink() {
  return (
    <a className="skip-link" href="#main">
      {useCopy().nav.skip}
    </a>
  )
}

function SiteFooter() {
  const { lang } = useLang()
  const t = useCopy()
  const labels = FOOTER_LABELS[lang]

  return (
    <footer className="footer">
      <div className="footer-main">
        <p className="footer-brand">
          <span className="mono">AfterRay</span>
          <span className="dim">{t.footer.tagline}</span>
        </p>
        <nav className="footer-links" aria-label={labels.nav}>
          <a href={pathFor('home', lang)}>{labels.home}</a>
          <a href={pathFor('privacy', lang)}>{labels.privacy}</a>
          <a href={pathFor('security', lang)}>{labels.security}</a>
          <a href={pathFor('download', lang)}>{labels.download}</a>
          <a href="https://github.com/loro-dev/afterray">{labels.source}</a>
        </nav>
      </div>
      <span className="mono dim">{t.footer.rights}</span>
    </footer>
  )
}

function Page({ route }: { route: SiteRoute }) {
  const isHome = route.page === 'home'
  return (
    <div className="app" id="top">
      <SkipLink />
      <Nav route={route} />
      {isHome ? (
        <>
          <Hero />
          <main id="main">
            {/* the hero promises the agent already knows; cash that out first */}
            <Agents />
            <Jtbd />
            <Memories />
            <SearchAsk />
            <Closer />
          </main>
        </>
      ) : (
        <InfoPage route={route} />
      )}
      <SiteFooter />
      <div className="grain" aria-hidden="true" />
    </div>
  )
}

export default function App({ route }: { route: SiteRoute }) {
  return (
    <LangProvider lang={route.lang}>
      <Page route={route} />
    </LangProvider>
  )
}
