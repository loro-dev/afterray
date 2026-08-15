import { useEffect, useState } from 'react'
import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

const reduced = () =>
  typeof window !== 'undefined' &&
  window.matchMedia('(prefers-reduced-motion: reduce)').matches

/** The CLI and the Agent Skill are one story: the same read-only surface. */
export default function Agents() {
  const t = useCopy().agents
  const [activeIdx, setActiveIdx] = useState(0)
  const [typed, setTyped] = useState(t.mock[0].cmd.length)
  const [showOut, setShowOut] = useState(true)

  // typewriter: type the command, then reveal the output
  useEffect(() => {
    if (reduced()) {
      setTyped(t.mock[activeIdx].cmd.length)
      setShowOut(true)
      return
    }
    setTyped(0)
    setShowOut(false)
    const cmd = t.mock[activeIdx].cmd
    const id = window.setInterval(() => {
      setTyped((n) => {
        if (n >= cmd.length) {
          window.clearInterval(id)
          window.setTimeout(() => setShowOut(true), 220)
          return n
        }
        return n + 1
      })
    }, 18)
    return () => window.clearInterval(id)
  }, [activeIdx, t.mock])

  const active = t.mock[activeIdx]

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
          <p className="agents-label dim">{t.toolsLabel}</p>
          <p className="agents-tools">{t.tools.join(' · ')}</p>
        </Reveal>
        {/* The counterpart to the section above it: that one is the agent we
            open the vault to, this one is the agent we keep in a cage. Read
            together they say what the boundary is in both directions. */}
        <Reveal delay={90}>
          <div className="agents-jail">
            <p className="agents-jail-title">{t.jailTitle}</p>
            <p className="agents-jail-body">{t.jailBody}</p>
            <a
              className="agents-jail-proof mono"
              href={t.jailProofHref}
              target="_blank"
              rel="noreferrer"
            >
              {t.jailProof}
            </a>
            {/* Said plainly rather than buried: a privacy claim that is false
                in a configuration we ship is worse than no claim. */}
            <p className="agents-jail-caveat dim">{t.jailCaveat}</p>
          </div>
        </Reveal>
      </div>
      <Reveal className="feature-mock" delay={150}>
        <div className="mock cli-mock mono agents-install">
          <div className="cli-line">
            <span className="accent">$ </span>
            {t.install}
          </div>
          <pre className="cli-out">{t.installOut}</pre>
        </div>
        <div className="cli-cmds">
          {t.mock.map((b, i) => (
            <button
              type="button"
              key={b.cmd}
              className={`sa-chip mono ${i === activeIdx ? 'sa-chip-active' : ''}`}
              onClick={() => setActiveIdx(i)}
            >
              {b.cmd.split(' ')[1]}
            </button>
          ))}
        </div>
        <div className="mock cli-mock mono">
          <div className="cli-line">
            <span className="accent">$ </span>
            {active.cmd.slice(0, typed)}
            {!showOut && <span className="cli-caret" />}
          </div>
          {showOut && <pre className="cli-out">{active.out}</pre>}
          {showOut && <span className="cli-caret" />}
        </div>
        <p className="agents-note dim">{t.note}</p>
      </Reveal>
    </section>
  )
}
