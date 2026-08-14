import { useEffect, useMemo, useState } from 'react'
import Reveal from '../components/Reveal'
import { Rich, useCopy, useLang } from '../i18n'

export default function SearchAsk() {
  const t = useCopy().searchAsk
  const { lang } = useLang()
  const [queryText, setQueryText] = useState(t.mock.queries[0].query)
  const [presetIdx, setPresetIdx] = useState(0)

  useEffect(() => {
    setQueryText(t.mock.queries[0].query)
    setPresetIdx(0)
  }, [lang, t.mock.queries])

  const active = useMemo(() => {
    const q = queryText.toLowerCase()
    return (
      t.mock.queries.find((c) => c.keys.some((k) => q.includes(k.toLowerCase()))) ??
      t.mock.queries[0]
    )
  }, [queryText, t.mock.queries])

  const preset = t.mock.presets[presetIdx]

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
              <input
                className="sa-input"
                value={queryText}
                onChange={(e) => setQueryText(e.target.value)}
                aria-label={t.mock.searchHead}
                spellCheck={false}
              />
            </div>
            {active.results.map((r) => (
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
            <div className="sa-cites sa-presets">
              {t.mock.presets.map((p, i) => (
                <button
                  type="button"
                  key={p.q}
                  className={`sa-chip mono ${i === presetIdx ? 'sa-chip-active' : ''}`}
                  onClick={() => setPresetIdx(i)}
                >
                  {p.q}
                </button>
              ))}
            </div>
            <p className="sa-a">{preset.a}</p>
            <div className="sa-cites">
              {preset.cites.map((c) => (
                <span key={c} className="sa-cite mono">
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
