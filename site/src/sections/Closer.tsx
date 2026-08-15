import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

/**
 * The closer: privacy is the reason it is safe to say yes, so it lands here
 * rather than opening the page. Pipeline and specs fold in behind it.
 */
export default function Closer() {
  const t = useCopy()
  return (
    <>
      <section className="section privacy" id="privacy">
        <Reveal className="privacy-statement">
          <h2 className="statement">
            <span className="zero mono">0</span>
            {t.privacy.statementA}
            <br />
            {t.privacy.statementB}
          </h2>
        </Reveal>
        <div className="pillar-grid">
          {t.privacy.pillars.map((p, i) => (
            <Reveal key={p.title} className="pillar" delay={i * 90}>
              <h3>{p.title}</h3>
              <p>{p.body}</p>
            </Reveal>
          ))}
        </div>

        <Reveal delay={120}>
          <div className="pipe-row">
            {t.specs.steps.map((step, i) => (
              <div key={step} className="pipe-step">
                <span className="pipe-node mono">{step}</span>
                {i < t.specs.steps.length - 1 && <span className="pipe-arrow">→</span>}
              </div>
            ))}
          </div>
        </Reveal>
        <div className="spec-grid">
          {t.specs.rows.map(([k, v], i) => (
            <Reveal key={k} className="spec-row" delay={i * 70}>
              <span className="mono dim">{k}</span>
              <span>{v}</span>
            </Reveal>
          ))}
        </div>
      </section>

      <section className="final-cta" id="download">
        <Reveal>
          <h2 className="final-title">
            <Rich parts={t.final.titleA} />
            <br />
            <Rich parts={t.final.titleB} />
          </h2>
          <div className="hero-ctas">
            <a className="btn btn-primary" href="#download">
              {t.final.ctaPrimary}
            </a>
            <a
              className="btn btn-ghost"
              href="https://github.com/loro-dev/afterray"
              target="_blank"
              rel="noreferrer"
            >
              {t.final.ctaSecondary}
            </a>
          </div>
        </Reveal>
      </section>

      <footer className="footer">
        {/* the tagline explains the name, so the two belong together */}
        <p className="footer-brand">
          <span className="mono">AfterRay</span>
          <span className="dim">{t.footer.tagline}</span>
        </p>
        <span className="mono dim">{t.footer.rights}</span>
      </footer>
    </>
  )
}
