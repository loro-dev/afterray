import type { ReactNode } from 'react'

/** Generic glyphs standing in for the real app icons, shared by the mocks. */
export const ICONS: Record<string, ReactNode> = {
  Xcode: <path d="m8.5 7-4 5 4 5M15.5 7l4 5-4 5" />,
  Safari: (
    <>
      <circle cx="12" cy="12" r="8" />
      <path d="m15 9-1.8 4.2L9 15l1.8-4.2z" />
    </>
  ),
  Zoom: (
    <>
      <rect x="3" y="7" width="12" height="10" rx="2" />
      <path d="m15 10.5 6-3v9l-6-3z" />
    </>
  ),
  Slack: <path d="M9 4v16M15 4v16M4 9h16M4 15h16" />,
  Notes: (
    <>
      <rect x="5" y="4" width="14" height="16" rx="2" />
      <path d="M8.5 9h7M8.5 13h7" />
    </>
  ),
  GitHub: (
    <>
      <circle cx="7" cy="7" r="2.4" />
      <circle cx="7" cy="17" r="2.4" />
      <circle cx="17" cy="9" r="2.4" />
      <path d="M7 9.4v5.2M17 11.4c0 3-3.5 3.1-7.4 3.2" />
    </>
  ),
}

export function AppGlyph({ app }: { app: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {ICONS[app]}
    </svg>
  )
}
