import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

/** The passive half of the product: the day written back to you, unprompted. */
export default function Memories() {
  const t = useCopy().memories
  return (
    <section className="section feature" id="memories">
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
        <div className="mock mem-panel">
          <div className="mem-head">
            <span className="mono accent">{t.mock.label}</span>
            <span className="mono dim">{t.mock.head}</span>
          </div>
          {t.mock.rows.map((r) => (
            <div key={r.span} className="mem-row">
              <span className="mem-span mono">{r.span}</span>
              <div className="mem-body">
                <p>{r.summary}</p>
                <span className="mono dim mem-apps">{r.apps}</span>
              </div>
            </div>
          ))}
        </div>
      </Reveal>
    </section>
  )
}
