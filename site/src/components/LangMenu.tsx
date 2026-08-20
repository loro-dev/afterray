import { LANGS, useCopy, useLang } from '../i18n'
import { pathFor, type SiteRoute } from '../routes'

export default function LangMenu({ route }: { route: SiteRoute }) {
  const { lang } = useLang()
  const label = useCopy().nav.language

  return (
    <details className="lang-menu">
      <summary className="lang-btn" aria-label={label}>
        {/* Lucide "languages" — the conventional translate mark */}
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="m5 8l6 6m-7 0l6-6l2-3M2 5h12M7 2h1m14 20l-5-10l-5 10m2-4h6" />
        </svg>
      </summary>
      <nav className="lang-list" aria-label={label}>
        {LANGS.map((candidate) => (
          <a
            key={candidate.code}
            href={pathFor(route.page, candidate.code)}
            hrefLang={candidate.htmlLang}
            aria-current={candidate.code === lang ? 'page' : undefined}
            className={`lang-item ${candidate.code === lang ? 'lang-item-on' : ''}`}
          >
            {candidate.label}
          </a>
        ))}
      </nav>
    </details>
  )
}
