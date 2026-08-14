import Reveal from '../components/Reveal'
import { useCopy } from '../i18n'

/** Three named jobs, straight under the hero — what people actually use it for. */
export default function Jtbd() {
  const items = useCopy().jtbd
  return (
    <section className="section jtbd">
      {items.map((item, i) => (
        <Reveal key={item.title} className="jtbd-item" delay={i * 90}>
          <h2>{item.title}</h2>
          <p>{item.body}</p>
        </Reveal>
      ))}
    </section>
  )
}
