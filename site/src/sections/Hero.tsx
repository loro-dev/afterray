import RecallStage from '../components/RecallStage'
import { Rich, useCopy } from '../i18n'

export default function Hero() {
  const t = useCopy().hero
  const recall = useCopy().recall
  return (
    <header className="hero">
      <div className="hero-ray" aria-hidden="true" />
      <div className="hero-content">
        <p className="hero-eyebrow anim-in">{t.eyebrow}</p>
        <h1 className="hero-title">
          <span className="anim-in" style={{ animationDelay: '0.1s' }}>
            <Rich parts={t.titleA} />
          </span>
          <span className="anim-in" style={{ animationDelay: '0.2s' }}>
            <Rich parts={t.titleB} />
          </span>
        </h1>
        <p className="hero-sub anim-in" style={{ animationDelay: '0.3s' }}>
          {t.sub}
        </p>
        <div className="hero-ctas anim-in" style={{ animationDelay: '0.4s' }}>
          <a className="btn btn-primary" href="#download">
            {t.ctaPrimary}
          </a>
          <a className="btn btn-ghost" href="#memories">
            {t.ctaSecondary}
          </a>
        </div>
        <ul className="hero-facts mono dim anim-in" style={{ animationDelay: '0.5s' }}>
          {t.facts.map((f) => (
            <li key={f}>{f}</li>
          ))}
        </ul>
      </div>

      {/* the product itself, in the first screen — a page about seeing your
          past should not open with nothing to look at */}
      <div className="hero-stage anim-in" id="features" style={{ animationDelay: '0.55s' }}>
        <RecallStage />
        <p className="hero-caption">{recall.body}</p>
      </div>
    </header>
  )
}
