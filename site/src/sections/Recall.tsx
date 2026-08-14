import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Recall() {
  const t = useCopy().recall
  return (
    <section className="section feature" id="features">
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
        <div className="mock recall-mock">
          <div className="rc-still" aria-hidden="true" />
          <div className="rc-top">
            <span className="rc-status mono">
              <i className="rc-dot" />
              {t.mock.status}
            </span>
            <span className="rc-field">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <circle cx="11" cy="11" r="7" />
                <path d="m20 20-3.8-3.8" />
              </svg>
              {t.mock.search}
            </span>
            <span className="rc-field rc-ask-field">✦ {t.mock.ask}</span>
          </div>
          <div className="rc-caption">
            <span className="rc-play" aria-hidden="true">
              <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor">
                <path d="M8 5v14l11-7z" />
              </svg>
            </span>
            <div>
              <p>{t.mock.caption}</p>
              <span className="mono dim">{t.mock.captionMeta}</span>
            </div>
          </div>
          <div className="rc-bottom">
            <div className="rc-time mono">
              {t.mock.time} · {t.mock.date}
            </div>
            <div className="rc-timeline">
              {t.mock.segments.map((s) => (
                <span
                  key={s.app}
                  className="rc-seg"
                  style={{ width: `${s.w}%`, background: s.c }}
                >
                  {s.w >= 12 ? `${s.app} · ${s.dur}` : ''}
                </span>
              ))}
              <i className="rc-playhead" />
            </div>
            <div className="rc-hint mono">{t.mock.hint}</div>
          </div>
        </div>
      </Reveal>
    </section>
  )
}
