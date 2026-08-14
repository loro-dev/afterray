import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Specs() {
  const t = useCopy()
  return (
    <>
      <section className="section pipeline">
        <Reveal>
          <h2 className="pipeline-title">
            <Rich parts={t.specs.title} />
          </h2>
        </Reveal>
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
          <p className="final-sub">{t.final.sub}</p>
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
        <span className="mono">AfterRay</span>
        <span className="dim">{t.footer.tagline}</span>
        <span className="mono dim">{t.footer.rights}</span>
      </footer>
    </>
  )
}
