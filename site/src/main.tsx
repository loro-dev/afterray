import { StrictMode } from 'react'
import { createRoot, hydrateRoot } from 'react-dom/client'
import App from './App'
import './styles.css'
import { resolveRoute } from './routes'

const route = resolveRoute(window.location.pathname)
const root = document.getElementById('root')!
const app = (
  <StrictMode>
    <App route={route} />
  </StrictMode>
)

// Production pages are prerendered; Vite's development shell is intentionally
// empty and needs an ordinary client render.
if (root.hasChildNodes()) hydrateRoot(root, app)
else createRoot(root).render(app)
