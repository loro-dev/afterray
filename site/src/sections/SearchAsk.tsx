import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function SearchAsk() {
  const t = useCopy().searchAsk
  return (
    <section className="section feature feature-flip">
      <Reveal className="feature-mock" delay={150}>
        <div className="sa-stack">
          <div className="mock sa-panel">
            <div className="sa-head mono dim">{t.mock.searchHead}</div>
            <div className="sa-query">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <circle cx="11" cy="11" r="7" />
                <path d="m20 20-3.8-3.8" />
              </svg>
              {t.mock.query}
            </div>
            {t.mock.results.map((r) => (
              <div key={r.time} className="sa-row">
                <div className="sa-row-head">
                  <span className="sa-src mono">{r.src}</span>
                  <span className="mono dim">{r.time}</span>
                </div>
                <p>{r.text}</p>
              </div>
            ))}
          </div>
          <div className="mock sa-panel sa-answer">
            <div className="sa-head mono accent">{t.mock.askHead}</div>
            <p className="sa-q mono dim">✦ {t.mock.question}</p>
            <p className="sa-a">{t.mock.answer}</p>
            <div className="sa-cites">
              {t.mock.citations.map((c) => (
                <span key={c} className="sa-chip mono">
                  {c}
                </span>
              ))}
            </div>
          </div>
        </div>
      </Reveal>
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
    </section>
  )
}
