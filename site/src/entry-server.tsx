import { StrictMode } from 'react'
import { renderToString } from 'react-dom/server'
import App from './App'
import { LANGS } from './i18n'
import { pathFor, prerenderPaths, resolveRoute } from './routes'

export { prerenderPaths }

/** Build-time only: scripts/prerender.mjs bakes every public route into dist. */
export function render(pathname: string) {
  const route = resolveRoute(pathname)
  return {
    markup: renderToString(
      <StrictMode>
        <App route={route} />
      </StrictMode>,
    ),
    route,
    alternates: {
      localized: LANGS.map((language) => ({
        hreflang: language.htmlLang,
        ogLocale: language.ogLocale,
        path: pathFor(route.page, language.code),
      })),
      xDefault: pathFor(route.page, 'en'),
    },
  }
}
