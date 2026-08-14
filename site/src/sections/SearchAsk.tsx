import { useEffect, useMemo, useState } from 'react'
import Reveal from '../components/Reveal'
import { AppGlyph } from '../appIcons'
import { Rich, useCopy, useLang } from '../i18n'

type Scenario = ReturnType<typeof useCopy>['searchAsk']['mock']['scenarios'][number]
type Result = Scenario['results'][number]

/** A postage-stamp of the captured window, so a hit reads as a moment, not a log line. */
function Frame({ r }: { r: Result }) {
  return (
    <span className="sa-frame" style={{ ['--tint' as string]: r.c }} aria-hidden="true">
      <span className="sa-frame-bar">
        <AppGlyph app={r.app} />
      </span>
      <span className="sa-frame-body">
        <i style={{ width: '82%' }} />
        <i style={{ width: '58%' }} />
      </span>
    </span>
  )
}

/** Bolds the phrase the query actually landed on. */
function Matched({ text, match }: { text: string; match: string }) {
  const at = text.indexOf(match)
  if (at < 0) return <>{text}</>
  return (
    <>
      {text.slice(0, at)}
      <mark>{match}</mark>
      {text.slice(at + match.length)}
    </>
  )
}

export default function SearchAsk() {
  const t = useCopy().searchAsk
  const { lang } = useLang()
  const [queryText, setQueryText] = useState(t.mock.scenarios[0].query)

  useEffect(() => {
    setQueryText(t.mock.scenarios[0].query)
  }, [lang, t.mock.scenarios])

  // one query drives both panels, so the evidence and the answer stay tied together
  const active = useMemo(() => {
    const q = queryText.toLowerCase()
    return (
      t.mock.scenarios.find((s) => s.keys.some((k) => q.includes(k.toLowerCase()))) ??
      t.mock.scenarios[0]
    )
  }, [queryText, t.mock.scenarios])

  return (
    <section className="section feature feature-flip">
      <Reveal className="feature-mock" delay={150}>
        <div className="sa-try">
          <span className="mono dim">{t.mock.tryLabel}</span>
          {t.mock.scenarios.map((s) => (
            <button
              type="button"
              key={s.chip}
              className={`sa-chip mono ${s === active ? 'sa-chip-active' : ''}`}
              onClick={() => setQueryText(s.query)}
            >
              {s.chip}
            </button>
          ))}
        </div>

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

            <div className="sa-head mono dim sa-found">{t.mock.foundHead}</div>
            {active.results.map((r) => (
              <div key={`${r.app}-${r.time}`} className="sa-hit">
                <Frame r={r} />
                <div className="sa-hit-text">
                  <div className="sa-hit-head">
                    <span className="sa-src mono">
                      {r.src === 'heard' ? t.mock.heardLabel : t.mock.screenLabel}
                    </span>
                    <span className="mono dim">
                      {r.app} · {r.time}
                    </span>
                  </div>
                  <p>
                    <Matched text={r.text} match={r.match} />
                  </p>
                </div>
                <span className="sa-replay mono" aria-hidden="true">
                  ▶ {t.mock.replay}
                </span>
              </div>
            ))}
          </div>

          <div className="mock sa-panel sa-answer">
            <div className="sa-head mono accent">{t.mock.askHead}</div>
            <p className="sa-a">{active.answer}</p>
            <div className="sa-cites">
              {active.results.map((r) => (
                <span key={`${r.app}-${r.time}`} className="sa-cite mono">
                  ▶ {r.app} · {r.time}
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
