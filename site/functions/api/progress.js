// functions/api/progress.js
//
// Private progress links for lb.frogwizard.net/p/<id>: the page posts a character's Lorebound export code
// (Export.lua, "LMP1~...") and gets back a random id, plus a token kept only in that browser so a newer code
// for the same character can update the same link. Nothing is listed or searchable; anyone with the link
// can view it.
//
// POST   /api/progress  { code, id?, token? }  201 { id, token? }  (token only when a link is made)
// GET    /api/progress?id=<id>                  200 { code, updated }
// DELETE /api/progress  { id, token }           200 { deleted: true }  (only with the link's token)
//
// Needs the DB binding (D1, schema.sql: progress and report_rate_limit).

import { allowedOrigin, json, rateLimited } from '../_lib/limit.js'

const MAX_CODE = 30000
const ID = /^[A-Za-z0-9]{10}$/

function random(length) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  const bytes = crypto.getRandomValues(new Uint8Array(length))
  return Array.from(bytes, (b) => chars[b % chars.length]).join('')
}

async function sha256(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

const MAX_QUESTS = 20000 // far more than any quest list: the statuses' runs may not add up to more

// Only Lorebound's progress codes: LMP1, a list version, fifteen ~-separated sections, plain characters,
// and statuses whose runs stay within a quest list's length (a huge run would hang the page reading it).
function validCode(code) {
  if (typeof code !== 'string' || code.length > MAX_CODE) return false
  const parts = code.trim().split('~')
  if (parts[0] !== 'LMP1' || parts.length !== 15 || !/^[0-9a-f]{10}$/.test(parts[1]) || /[<>`]/.test(code)) return false
  if (!/^([a-g]\d{0,5})*$/.test(parts[11])) return false
  let quests = 0
  for (const [, length] of parts[11].matchAll(/[a-g](\d*)/g)) quests += length ? Number(length) : 1
  return quests <= MAX_QUESTS
}

async function ownedRow(env, id, token) {
  if (typeof id !== 'string' || !ID.test(id) || typeof token !== 'string') return false
  const row = await env.DB.prepare('SELECT token_hash FROM progress WHERE id = ?').bind(id).first()
  return !!row && row.token_hash === (await sha256(token))
}

export async function onRequestPost({ request, env }) {
  if (!allowedOrigin(request)) return json(403, { error: 'origin_not_allowed' })
  if (!env.DB) return json(503, { error: 'not_configured' })
  let body
  try {
    body = await request.json()
  } catch {
    return json(400, { error: 'invalid_json' })
  }
  if (!body || typeof body !== 'object') return json(400, { error: 'invalid_json' })
  if (!validCode(body.code)) return json(400, { error: 'not_a_progress_code' })
  const code = body.code.trim()
  const now = Date.now()

  // Updating a link this browser made.
  if (await ownedRow(env, body.id, body.token)) {
    const limited = await rateLimited(env, request.headers.get('cf-connecting-ip'), 'progress-update', { perDay: 60, cooldownMs: 3000 })
    if (limited) return json(429, { error: limited })
    await env.DB.prepare('UPDATE progress SET code = ?, updated = ? WHERE id = ?').bind(code, now, body.id).run()
    return json(201, { id: body.id })
  }

  // A new link.
  const limited = await rateLimited(env, request.headers.get('cf-connecting-ip'), 'progress-new', { perDay: 30, cooldownMs: 3000 })
  if (limited) return json(429, { error: limited })
  const id = random(10)
  const token = random(24)
  await env.DB.prepare('INSERT INTO progress (id, token_hash, code, updated) VALUES (?, ?, ?, ?)')
    .bind(id, await sha256(token), code, now).run()
  return json(201, { id, token })
}

export async function onRequestDelete({ request, env }) {
  if (!allowedOrigin(request)) return json(403, { error: 'origin_not_allowed' })
  if (!env.DB) return json(503, { error: 'not_configured' })
  let body
  try {
    body = await request.json()
  } catch {
    return json(400, { error: 'invalid_json' })
  }
  if (!body || typeof body !== 'object' || !(await ownedRow(env, body.id, body.token))) return json(404, { error: 'not_found' })
  await env.DB.prepare('DELETE FROM progress WHERE id = ?').bind(body.id).run()
  return json(200, { deleted: true })
}

export async function onRequestGet({ request, env }) {
  if (!env.DB) return json(503, { error: 'not_configured' })
  const id = new URL(request.url).searchParams.get('id') || ''
  if (!ID.test(id)) return json(404, { error: 'not_found' })
  const row = await env.DB.prepare('SELECT code, updated FROM progress WHERE id = ?').bind(id).first()
  if (!row) return json(404, { error: 'not_found' })
  return json(200, { code: row.code, updated: row.updated })
}
