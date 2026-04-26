// HTML ファイルを PDF に変換 (Playwright Chromium)
// usage: node html_to_pdf.mjs <input.html> <output.pdf>
import { chromium } from '@playwright/test'
import { pathToFileURL } from 'node:url'
import path from 'node:path'

const [, , input, output] = process.argv
if (!input || !output) {
  console.error('usage: node html_to_pdf.mjs <input.html> <output.pdf>')
  process.exit(1)
}

const browser = await chromium.launch()
const ctx = await browser.newContext()
const page = await ctx.newPage()
await page.goto(pathToFileURL(path.resolve(input)).href)
await page.emulateMedia({ media: 'print' })
await page.pdf({
  path: output,
  format: 'A4',
  printBackground: true,
  margin: { top: '12mm', right: '12mm', bottom: '12mm', left: '12mm' },
})
await browser.close()
console.log(output)
