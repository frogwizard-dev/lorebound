// functions/api/report.js
//
// Lorebound's anonymous quest reports (the same shape as Warscribe's feedback endpoint). The page at
// lb.frogwizard.net posts the code from Lorebound's "Share new quests" box here; this turns it into a
// GitHub issue (label quest-report) in the reports repository through a service account's token. No
// sign-in for players. `_tools/make_lore.py --pull` reads the open issues into `_tools/lore_reports`.
//
// Only Lorebound's own lines get through: the issue's body is rebuilt from the valid `LM1^...` lines
// (15 fields, a numeric quest ID, no backticks), so nothing else a visitor types reaches a public issue.
//
// POST /api/report   { code: string, honeypot: string }
//   201 { url, number }   400 { error }   403 origin   429 rate limited   502/503 GitHub or config
//
// Environment (Cloudflare Pages project settings):
//   REPORT_GH_TOKEN  a fine-grained token with Issues: read and write on REPORT_REPO only (secret)
//   REPORT_REPO      "owner/name" of the reports repository (e.g. frogwizard-dev/loremaster-reports)
//   DB               optional D1 binding with schema.sql applied: per-IP rate limit (hashed IPs)

import { allowedOrigin, json, rateLimited } from '../_lib/limit.js'

const GITHUB_API = 'https://api.github.com'
const MAX_CODE = 40000
const MAX_LINES = 300
const MAX_LINE = 400
const ALLOWED = { perDay: 10, cooldownMs: 10 * 1000 } // reports from one address

// The code's valid lines: its "Lorebound quests (client ...)" heading and each well-formed LM1 line.
function cleanLines(code) {
  let client = ''
  const lines = []
  const seen = new Set()
  for (const raw of code.split(/\r?\n/)) {
    const line = raw.trim().replace(/@/g, '') // an @name would notify that GitHub user
    const heading = line.match(/^Lore(?:bound|master) quests \(client ([0-9.]{1,24})\)/) // codes from before the rename too
    if (heading) client = heading[1]
    if (!line.startsWith('LM1^') || line.length > MAX_LINE || line.includes('`')) continue
    const parts = line.split('^')
    if (parts.length !== 15 || !/^\d{1,7}$/.test(parts[1]) || seen.has(parts[1])) continue
    seen.add(parts[1])
    lines.push(line)
    if (lines.length >= MAX_LINES) break
  }
  return { client, lines, ids: [...seen] }
}

export async function onRequestPost({ request, env }) {
  if (!allowedOrigin(request)) return json(403, { error: 'origin_not_allowed' })
  if (!env.REPORT_GH_TOKEN || !env.REPORT_REPO) return json(503, { error: 'not_configured' })
  let payload
  try {
    payload = await request.json()
  } catch {
    return json(400, { error: 'invalid_json' })
  }
  if (!payload || typeof payload !== 'object') return json(400, { error: 'invalid_json' })
  if (typeof payload.honeypot === 'string' && payload.honeypot.length > 0) {
    return json(201, { url: '', number: 0 }) // a bot: pretend it worked
  }
  if (typeof payload.code !== 'string' || payload.code.length === 0) return json(400, { error: 'no_code' })
  if (payload.code.length > MAX_CODE) return json(400, { error: 'too_long' })
  const { client, lines, ids } = cleanLines(payload.code)
  if (lines.length === 0) return json(400, { error: 'no_loremaster_lines' })

  const limited = await rateLimited(env, request.headers.get('cf-connecting-ip'), 'report', ALLOWED)
  if (limited) return json(429, { error: limited })

  const names = lines.slice(0, 3).map((line) => line.split('^')[2]).join(', ')
  const title = `Quest report: ${lines.length} quest${lines.length === 1 ? '' : 's'} (${names}${lines.length > 3 ? ', ...' : ''})`
  const body = [
    `Client ${client || 'unknown'}, ${lines.length} quest${lines.length === 1 ? '' : 's'}: ${ids.join(', ')}`,
    '',
    '```',
    ...lines,
    '```',
  ].join('\n')
  const res = await fetch(`${GITHUB_API}/repos/${env.REPORT_REPO}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.REPORT_GH_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'loremaster-report',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ title: title.slice(0, 200), body, labels: ['quest-report'] }),
  })
  if (!res.ok) {
    console.warn('report: GitHub said', res.status, (await res.text()).slice(0, 200))
    return json(502, { error: 'github_failed' })
  }
  const issue = await res.json()
  return json(201, { url: issue.html_url, number: issue.number })
}
