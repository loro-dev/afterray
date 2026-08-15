import { StrictMode } from 'react'
import { hydrateRoot } from 'react-dom/client'
import App from './App'
import './styles.css'

// The markup is prerendered at build time, so attach to it rather than
// throwing it away and rendering again.
hydrateRoot(
  document.getElementById('root')!,
  <StrictMode>
    <App />
  </StrictMode>,
)
