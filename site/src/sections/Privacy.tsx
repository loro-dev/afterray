import Reveal from '../components/Reveal'
import { useCopy } from '../i18n'

export default function Privacy() {
  const t = useCopy().privacy
  return (
    <section className="section privacy" id="privacy">
      <Reveal className="privacy-statement">
        <h2 className="statement">
          <span className="zero mono">0</span>
          {t.statementA}
          <br />
          {t.statementB}
        </h2>
        <p className="statement-sub">{t.sub}</p>
      </Reveal>
      <div className="pillar-grid">
        {t.pillars.map((p, i) => (
          <Reveal key={p.title} className="pillar" delay={i * 90}>
            <h3>{p.title}</h3>
            <p>{p.body}</p>
          </Reveal>
        ))}
      </div>
    </section>
  )
}
