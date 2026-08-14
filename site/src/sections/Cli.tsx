import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Cli() {
  const t = useCopy().cli
  return (
    <section className="section feature" id="cli">
      <div className="feature-text">
        <Reveal>
          <h2 className="feature-title">
            <Rich parts={t.titleA} />
            <br />
            <Rich parts={t.titleB} />
          </h2>
          <p className="feature-body">{t.body}</p>
          <ul className="feature-points">
            {t.points.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </Reveal>
      </div>
      <Reveal className="feature-mock" delay={150}>
        <div className="mock cli-mock mono">
          {t.mock.map((b) => (
            <div key={b.cmd} className="cli-block">
              <div className="cli-line">
                <span className="accent">$ </span>
                {b.cmd}
              </div>
              <pre className="cli-out">{b.out}</pre>
            </div>
          ))}
          <span className="cli-caret" />
        </div>
      </Reveal>
    </section>
  )
}
