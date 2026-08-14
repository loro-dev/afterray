import { Rich, useCopy } from '../i18n'

export default function Hero() {
  const t = useCopy().hero
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
          <a className="btn btn-ghost" href="#features">
            {t.ctaSecondary}
          </a>
        </div>
      </div>
    </header>
  )
}
