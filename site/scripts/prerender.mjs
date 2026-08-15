// Bakes the app's markup into dist/index.html so the page has content before
// any JavaScript runs. Without this the served body is an empty <div id="root">,
// which is all a non-rendering crawler ever sees.
import { readFileSync, writeFileSync, rmSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import path from 'node:path'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const indexPath = path.join(root, 'dist/index.html')
const ssrEntry = path.join(root, 'dist-ssr/entry-server.js')

const { render } = await import(pathToFileURL(ssrEntry).href)
const markup = render()

if (!markup.trim()) {
  throw new Error('prerender produced empty markup')
}

const template = readFileSync(indexPath, 'utf8')
const target = '<div id="root"></div>'
if (!template.includes(target)) {
  throw new Error(`prerender could not find ${target} in dist/index.html`)
}

writeFileSync(indexPath, template.replace(target, `<div id="root">${markup}</div>`))
rmSync(path.join(root, 'dist-ssr'), { recursive: true, force: true })

const kb = (Buffer.byteLength(markup) / 1024).toFixed(1)
console.log(`prerendered ${kb} kB of markup into dist/index.html`)
