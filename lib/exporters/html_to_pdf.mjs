// HTML ファイルを PDF に変換 (Playwright Chromium)
// usage: node html_to_pdf.mjs <input.html> <output.pdf>
import { chromium } from '@playwright/test'
import { pathToFileURL } from 'node:url'
import path from 'node:path'

const [, , input, output, orientation] = process.argv
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
  landscape: orientation === 'landscape', // 第3引数: 'landscape'=横向き / 'full'=縦・余白なし (公式様式の全面刷り用)
  printBackground: true,
  margin: (orientation === 'landscape' || orientation === 'full')
    ? { top: '0mm', right: '0mm', bottom: '0mm', left: '0mm' }
    : { top: '12mm', right: '12mm', bottom: '12mm', left: '12mm' },
})
await browser.close()
console.log(output)
