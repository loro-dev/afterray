import { StrictMode } from 'react'
import { renderToString } from 'react-dom/server'
import App from './App'

/** Build-time only: scripts/prerender.mjs bakes this into dist/index.html. */
export function render(): string {
  return renderToString(
    <StrictMode>
      <App />
    </StrictMode>,
  )
}
