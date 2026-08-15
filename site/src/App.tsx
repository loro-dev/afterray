import { LangProvider, useCopy } from './i18n'
import LangMenu from './components/LangMenu'
import Hero from './sections/Hero'
import Agents from './sections/Agents'
import Jtbd from './sections/Jtbd'
import Memories from './sections/Memories'
import SearchAsk from './sections/SearchAsk'
import Closer from './sections/Closer'

function Nav() {
  return (
    <nav className="nav">
      <a className="nav-logo" href="#top">
        <img src="/logo.png" alt="" className="logo-img" />
        <span className="mono">AfterRay</span>
      </a>
      <div className="nav-actions">
        <a
          className="nav-repo mono"
          href="https://github.com/loro-dev/afterray"
          target="_blank"
          rel="noreferrer"
          aria-label="GitHub repository"
        >
          GitHub
          <span aria-hidden="true">↗</span>
        </a>
        <LangMenu />
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
          <Memories />
          <SearchAsk />
          <Closer />
        </main>
        <div className="grain" aria-hidden="true" />
      </div>
    </LangProvider>
  )
}
