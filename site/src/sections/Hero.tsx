import { Rich, useCopy } from '../i18n'

export default function Hero() {
  const t = useCopy().hero
  return (
    <header className="hero">
      <div className="hero-content">
        <p className="hero-eyebrow anim-in" style={{ animationDelay: '0.1s' }}>
          {t.eyebrow}
        </p>
        <h1 className="hero-title">
          <span className="anim-in" style={{ animationDelay: '0.25s' }}>
            <Rich parts={t.titleA} />
          </span>
          <span className="anim-in" style={{ animationDelay: '0.45s' }}>
            <Rich parts={t.titleB} />
          </span>
        </h1>
        <p className="hero-sub anim-in" style={{ animationDelay: '0.7s' }}>
          {t.sub}
        </p>
        <div className="hero-ctas anim-in" style={{ animationDelay: '0.9s' }}>
          <a className="btn btn-primary" href="#download">
            {t.ctaPrimary}
          </a>
          <a className="btn btn-ghost" href="#features">
            {t.ctaSecondary}
          </a>
        </div>
      </div>
      <div className="hero-foot anim-in" style={{ animationDelay: '1.2s' }}>
        <span className="mono">{t.scroll}</span>
        <span className="hero-foot-line" />
        <span className="mono dim">{t.scrollHint}</span>
      </div>
    </header>
  )
}
