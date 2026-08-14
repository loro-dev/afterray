import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Agents() {
  const t = useCopy().agents
  return (
    <section className="section agents">
      <Reveal className="agents-head">
        <h2 className="feature-title">
          <Rich parts={t.titleA} />
          <br />
          <Rich parts={t.titleB} />
        </h2>
        <p className="feature-body">{t.body}</p>
      </Reveal>
      <Reveal delay={120}>
        <p className="mono dim agents-label">{t.toolsLabel}</p>
        <div className="agents-chips">
          {t.tools.map((tool) => (
            <span key={tool} className="agents-chip mono">
              {tool}
            </span>
          ))}
        </div>
      </Reveal>
      <Reveal delay={200}>
        <div className="mock cli-mock mono agents-mock">
          <div className="dim">{t.mock.context}</div>
          <div className="cli-line">
            <span className="accent">▸ </span>
            {t.mock.cmd}
          </div>
          <div className="agents-reply">{t.mock.reply}</div>
        </div>
        <p className="mono dim agents-note">{t.note}</p>
      </Reveal>
    </section>
  )
}
