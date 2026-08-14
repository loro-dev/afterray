import { useEffect, useMemo, useRef, useState } from 'react'
import Reveal from '../components/Reveal'
import { ICONS } from '../appIcons'
import { Rich, useCopy, useLang } from '../i18n'

type Rec = ReturnType<typeof useCopy>['recall']['mock']['records'][number]

/** A mock of the captured app window — the "screen still" of that moment. */
function AppWindow({ rec }: { rec: Rec }) {
  return (
    <div className="appwin">
      <div className="appwin-bar">
        <span className="appwin-dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
          {ICONS[rec.app]}
        </svg>
        <span className="appwin-name">{rec.app}</span>
        <span className="appwin-time mono">{rec.time}</span>
      </div>
      <div className="appwin-body">
        {rec.app === 'Safari' && (
          <>
            <div className="aw-url mono">{'url' in rec ? rec.url : rec.title}</div>
            <div className="aw-lines">
              <i style={{ width: '92%' }} />
              <i style={{ width: '78%' }} />
              <i className="aw-accent" style={{ width: '64%' }} />
              <i style={{ width: '85%' }} />
            </div>
          </>
        )}
        {rec.app === 'Xcode' && (
          <div className="aw-code mono">
            {[41, 42, 43, 44, 45].map((n, i) => (
              <div key={n}>
                <span className="aw-ln">{n}</span>
                <i
                  className={['aw-c3', '', 'aw-accent', 'aw-c2', ''][i]}
                  style={{ width: `${[58, 82, 46, 74, 63][i]}%` }}
                />
              </div>
            ))}
          </div>
        )}
        {rec.app === 'Zoom' && (
          <>
            <div className="aw-tiles">
              {['AL', 'JW', 'CY', '+2'].map((p) => (
                <span key={p} className="mono">
                  {p}
                </span>
              ))}
            </div>
            {'quote' in rec && rec.quote && <p className="aw-quote">{rec.quote}</p>}
          </>
        )}
        {rec.app === 'Notes' && (
          <div className="aw-lines aw-notes">
            <strong>{rec.title}</strong>
            <i style={{ width: '88%' }} />
            <i style={{ width: '72%' }} />
            <i style={{ width: '80%' }} />
          </div>
        )}
        {rec.app === 'GitHub' && (
          <>
            <div className="aw-pr">
              <span className="aw-pr-title">{rec.title}</span>
              <span className="aw-pr-chip mono">Open</span>
            </div>
            <div className="aw-lines">
              <i style={{ width: '90%' }} />
              <i className="aw-accent" style={{ width: '68%' }} />
              <i style={{ width: '76%' }} />
            </div>
          </>
        )}
      </div>
    </div>
  )
}

// the strip shows the day at ~3.2× its own width, like the in-app zoom
const ZOOM = 3.2

export default function Recall() {
  const t = useCopy().recall
  return (
    <section className="recall-section" id="features">
      <div className="section rail-head">
        <Reveal>
          <h2 className="feature-title">
            <Rich parts={t.titleA} />
            <br />
            <Rich parts={t.titleB} />
          </h2>
          <p className="feature-body">{t.body}</p>
        </Reveal>
      </div>
      <div className="recall-bleed">
        <RecallStage />
      </div>
    </section>
  )
}

function RecallStage() {
  const t = useCopy().recall
  const { lang } = useLang()
  const [pos, setPos] = useState(0.4)
  const [stripW, setStripW] = useState(0)
  const stripRef = useRef<HTMLDivElement>(null)

  // measure the strip so the track can be positioned in pixels
  useEffect(() => {
    const el = stripRef.current
    if (!el) return
    const measure = () => setStripW(el.clientWidth)
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [])

  // wheel over the strip slides the timeline under the fixed playhead,
  // like the in-app overlay; native listener because React's onWheel is
  // passive and can't preventDefault the page scroll
  useEffect(() => {
    const el = stripRef.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY
      setPos((p) => Math.min(1, Math.max(0, p + d / (stripW * ZOOM || 2600))))
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [stripW])

  const rec = useMemo(() => {
    const rs = t.mock.records
    let best = rs[0]
    for (const r of rs) if (Math.abs(r.pos - pos) < Math.abs(best.pos - pos)) best = r
    return best
  }, [pos, t.mock.records])

  // the track moves; the playhead stays dead center
  const trackW = stripW * ZOOM
  const tx = stripW / 2 - pos * trackW

  // the demo day runs 9:00 → 18:00
  const mins = 540 + pos * 540
  const h24 = Math.floor(mins / 60)
  const mm = String(Math.floor(mins % 60)).padStart(2, '0')
  const time =
    lang === 'zh' ? `${h24}:${mm}` : `${((h24 + 11) % 12) + 1}:${mm} ${h24 < 12 ? 'AM' : 'PM'}`

  return (
    <div className="mock rc-stage">
      {/* the captured screen of the pointed moment, dimmed under the overlay */}
      <div className="rc-window" key={rec.time}>
        <AppWindow rec={rec} />
      </div>
      <div className="rc-scrim" aria-hidden="true" />

          <div className="rc-search">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <circle cx="11" cy="11" r="7" />
              <path d="m20 20-3.8-3.8" />
            </svg>
            {t.mock.searchHint}
          </div>

          <div className="rc-cluster">
            <span className="rc-status mono">
              <i className="rc-dot" />
              {t.mock.status}
            </span>
            <span className="rc-gear" aria-hidden="true">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <circle cx="12" cy="12" r="3" />
                <path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1" />
              </svg>
            </span>
            <span className="rc-zoom" aria-hidden="true">
              <i />
            </span>
          </div>

          <div
            ref={stripRef}
            className="rc-strip"
            onPointerDown={(e) => e.currentTarget.setPointerCapture(e.pointerId)}
            onPointerMove={(e) => {
              // drag grabs the strip and pulls it under the needle
              if (e.buttons & 1) {
                setPos((p) =>
                  Math.min(1, Math.max(0, p - e.movementX / (trackW || 2600))),
                )
              }
            }}
            role="slider"
            aria-label={t.mock.hint}
            aria-valuenow={Math.round(pos * 100)}
            aria-valuemin={0}
            aria-valuemax={100}
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'ArrowLeft') setPos((p) => Math.max(0, p - 0.02))
              if (e.key === 'ArrowRight') setPos((p) => Math.min(1, p + 0.02))
            }}
          >
            <div className="rc-track" style={{ width: `${ZOOM * 100}%`, transform: `translateX(${tx}px)` }}>
              {t.mock.segments.map((s, i) => (
                <span
                  key={`${s.app}-${i}`}
                  className="rc-block"
                  style={{
                    left: `${s.from * 100}%`,
                    width: `calc(${(s.to - s.from) * 100}% - 4px)`,
                    background: s.c,
                  }}
                >
                  {s.to - s.from >= 0.09 && (
                    <>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                        {ICONS[s.app]}
                      </svg>
                      {s.app} · {s.dur}
                    </>
                  )}
                </span>
              ))}
            </div>
            <span className="rc-now mono" style={{ left: '50%' }}>
              {time} · {t.mock.date}
            </span>
            <i className="rc-head" style={{ left: '50%' }} />
          </div>
          <div className="rc-hintline mono">{t.mock.hint}</div>
    </div>
  )
}
