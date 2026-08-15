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
        {/* Lucide "languages" — the conventional translate mark */}
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="m5 8l6 6m-7 0l6-6l2-3M2 5h12M7 2h1m14 20l-5-10l-5 10m2-4h6" />
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
