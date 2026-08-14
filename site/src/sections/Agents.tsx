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
        <div className="mock cli-mock mono agents-mock">
          <div className="cli-line">
            <span className="accent">$ </span>
            {t.install}
          </div>
          <pre className="cli-out">{t.installOut}</pre>
          <div className="cli-line agents-ask">
            <span className="accent">$ </span>
            {t.mock.cmd}
          </div>
          <div className="agents-reply">{t.mock.reply}</div>
        </div>
        <p className="agents-label dim">{t.toolsLabel}</p>
        <p className="agents-tools">{t.tools.join(' · ')}</p>
        <p className="agents-note dim">{t.note}</p>
      </Reveal>
    </section>
  )
}
