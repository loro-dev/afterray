import { useEffect, useRef, useState } from 'react'
import { LANGS, useCopy, useLang } from '../i18n'

export default function LangMenu() {
  const { lang, setLang } = useLang()
  const label = useCopy().nav.language
  const [open, setOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)
  const btnRef = useRef<HTMLButtonElement>(null)

  // dismiss on outside press or Escape, returning focus to the trigger
  useEffect(() => {
    if (!open) return
    const onPointer = (e: PointerEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpen(false)
        btnRef.current?.focus()
      }
    }
    document.addEventListener('pointerdown', onPointer)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('pointerdown', onPointer)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <div className="lang-menu" ref={wrapRef}>
      <button
        ref={btnRef}
        type="button"
        className="lang-btn"
        aria-label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.7"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <circle cx="12" cy="12" r="9" />
          <path d="M3.6 9h16.8M3.6 15h16.8" />
          <path d="M12 3c-2.3 2.5-3.5 5.6-3.5 9s1.2 6.5 3.5 9c2.3-2.5 3.5-5.6 3.5-9s-1.2-6.5-3.5-9z" />
        </svg>
      </button>
      {open && (
        <div className="lang-list" role="menu" aria-label={label}>
          {LANGS.map((l) => (
            <button
              key={l.code}
              type="button"
              role="menuitemradio"
              aria-checked={l.code === lang}
              className={`lang-item ${l.code === lang ? 'lang-item-on' : ''}`}
              onClick={() => {
                setLang(l.code)
                setOpen(false)
                btnRef.current?.focus()
              }}
            >
              {l.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
