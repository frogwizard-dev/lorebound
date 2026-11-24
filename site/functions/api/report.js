// functions/api/report.js
//
// Lorebound's anonymous quest reports (the same shape as Warscribe's feedback endpoint). The page at
// lb.frogwizard.net posts the code from Lorebound's "Share new quests" box here; this turns it into a
// GitHub issue (label quest-report) in the reports repository through a service account's token. No
// sign-in for players. Once you've read a report and labelled it `approved`, `tools/make_lore.py --pull`
// reads it into `tools/lore_reports`.
//
// Only Lorebound's own lines get through: the issue's body is rebuilt from the valid `LM1^...` lines (a quest
// met in game: 15 fields, a numeric quest ID), `LT1^id^field^text` lines (a quest's Forever text: field d, o, c
// or p) and `LR1^id^choose^receive^money` lines (its rewards: numbers only), none with backticks, inside a code
// block, so nothing else a visitor types reaches a public issue.
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
const MAX_TEXT_LINE = 4000 // a quest's text (Share.lua keeps its lines under this)
const QUEST_ID = /^[1-9]\d{0,6}$/ // no leading zeros, so one quest can't pass as two
const REWARD_ITEMS = /^([1-9]\d{0,6}:[1-9]\d{0,3}(,[1-9]\d{0,6}:[1-9]\d{0,3}){0,9})?$/ // item:count, up to ten
// Control characters and the line breaks other readers split on (U+2028 and the like): a line could hide another.
const HIDDEN_BREAKS = /[\u0000-\u0008\u000b-\u001f\u007f\u0085\u2028\u2029]/
const ALLOWED = { perDay: 10, cooldownMs: 10 * 1000 } // reports from one address

// The code's valid lines: its "Lorebound quests (client ...)" heading, each well-formed LM1 line (quests met) and
// each well-formed LT1 line (their text).
function cleanLines(code) {
  let client = ''
  const lines = []
  const texts = []
  const seen = new Set()
  const textSeen = new Set()
  for (const raw of code.split(/\r?\n/)) {
    const line = raw.trim().replace(/@/g, '') // an @name would notify that GitHub user
    const heading = line.match(/^Lore(?:bound|master) quests \(client ([0-9.]{1,24})\)/) // codes from before the rename too
    if (heading) client = heading[1]
    if (line.includes('`') || HIDDEN_BREAKS.test(line)) continue
    const parts = line.split('^')
    if (line.startsWith('LM1^') && line.length <= MAX_LINE) {
      if (parts.length !== 15 || !QUEST_ID.test(parts[1]) || seen.has(parts[1])) continue
      seen.add(parts[1])
      lines.push(line)
    } else if (line.startsWith('LR1^') && line.length <= MAX_LINE) {
      const key = 'R' + parts[1]
      if (parts.length !== 5 || !QUEST_ID.test(parts[1]) || !REWARD_ITEMS.test(parts[2]) || !REWARD_ITEMS.test(parts[3]) ||
        !/^\d{1,9}$/.test(parts[4]) || textSeen.has(key)) continue
      textSeen.add(key)
      texts.push(line)
    } else if (line.startsWith('LT1^') && line.length <= MAX_TEXT_LINE) {
      const key = parts[1] + parts[2]
      if (parts.length !== 4 || !QUEST_ID.test(parts[1]) || !/^[docp]$/.test(parts[2]) || !parts[3].trim() || textSeen.has(key)) continue
      textSeen.add(key)
      texts.push(line)
    }
  }
  const textIds = [...new Set(texts.map((line) => line.split('^')[1]))]
  return { client, lines, texts, ids: [...seen], textIds, tooMany: lines.length + texts.length > MAX_LINES }
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
  const { client, lines, texts, ids, textIds, tooMany } = cleanLines(payload.code)
  if (lines.length === 0 && texts.length === 0) return json(400, { error: 'no_report_lines' })
  if (tooMany) return json(400, { error: 'too_long' }) // refused whole rather than cut short: nothing is lost

  const limited = await rateLimited(env, request.headers.get('cf-connecting-ip'), 'report', ALLOWED)
  if (limited) return json(429, { error: limited })

  const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`
  const names = lines.slice(0, 3).map((line) => line.split('^')[2]).join(', ')
  const about = [
    lines.length ? `${plural(lines.length, 'quest')} (${names}${lines.length > 3 ? ', ...' : ''})` : '',
    textIds.length ? `text or rewards for ${plural(textIds.length, 'quest')}` : '',
  ].filter(Boolean).join(', ')
  const title = `Quest report: ${about}`
  const body = [
    `Client ${client || 'unknown'}.`,
    lines.length ? `Quests met: ${ids.join(', ')}` : '',
    textIds.length ? `Text or rewards for: ${textIds.join(', ')}` : '',
    '',
    '```',
    ...lines,
    ...texts,
    '```',
  ].filter((part, i) => part !== '' || i === 3).join('\n')
  const res = await fetch(`${GITHUB_API}/repos/${env.REPORT_REPO}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.REPORT_GH_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'lorebound-report',
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
