import { LangProvider, useLang, useCopy } from './i18n'
import Hero from './sections/Hero'
import Recall from './sections/Recall'
import Privacy from './sections/Privacy'
import SearchAsk from './sections/SearchAsk'
import Cli from './sections/Cli'
import Agents from './sections/Agents'
import Specs from './sections/Specs'

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
        <a href="#features">{t.features}</a>
        <a href="#cli">{t.cli}</a>
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
          <Recall />
          <Privacy />
          <SearchAsk />
          <Cli />
          <Agents />
          <Specs />
        </main>
        <div className="grain" aria-hidden="true" />
      </div>
    </LangProvider>
  )
}
