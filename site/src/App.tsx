import { LangProvider, useLang, useCopy } from './i18n'
import Hero from './sections/Hero'
import Agents from './sections/Agents'
import Jtbd from './sections/Jtbd'
import Recall from './sections/Recall'
import Memories from './sections/Memories'
import SearchAsk from './sections/SearchAsk'
import Closer from './sections/Closer'

function Nav() {
  const { lang, setLang } = useLang()
  const t = useCopy().nav
  return (
    <nav className="nav">
      <a className="nav-logo" href="#top">
        <img src="/logo.png" alt="" className="logo-img" />
        <span className="mono">AfterRay</span>
      </a>
      <div className="nav-links">
        <a href="#cli">{t.cli}</a>
        <a href="#features">{t.features}</a>
        <a href="#privacy">{t.privacy}</a>
      </div>
      <div className="nav-actions">
        <button
          type="button"
          className="lang-toggle"
          onClick={() => setLang(lang === 'en' ? 'zh' : 'en')}
          aria-label={lang === 'en' ? 'Switch to Chinese' : '切换到英文'}
        >
          {lang === 'en' ? '中文' : 'EN'}
        </button>
        <a className="btn btn-small" href="#download">
          {t.download}
        </a>
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

export default function App() {
  return (
    <LangProvider>
      <div className="app" id="top">
        <SkipLink />
        <Nav />
        <Hero />
        <main id="main">
          {/* the hero promises the agent already knows; cash that out first */}
          <Agents />
          <Jtbd />
          <Recall />
          <Memories />
          <SearchAsk />
          <Closer />
        </main>
        <div className="grain" aria-hidden="true" />
      </div>
    </LangProvider>
  )
}
