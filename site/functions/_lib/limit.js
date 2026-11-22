// Per-IP rate limits for the site's endpoints, in D1 (report_rate_limit; hashed IPs only, never raw).
// Skipped with a warning when the DB binding is missing, so a deploy works either way.

async function hashIp(ip) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(ip || 'unknown'))
  return Array.from(new Uint8Array(buf)).slice(0, 8).map((b) => b.toString(16).padStart(2, '0')).join('')
}

// kind: a short prefix keeping each endpoint's counts apart. Returns an error string when over the limit.
export async function rateLimited(env, ip, kind, { perDay, cooldownMs }) {
  if (!env.DB) {
    console.warn(kind + ': no D1 binding, rate limit skipped')
    return null
  }
  const key = kind + ':' + (await hashIp(ip))
  const now = Date.now()
  const day = 24 * 60 * 60 * 1000
  const row = await env.DB.prepare(
    'SELECT request_count, window_start_ts, last_request_ts FROM report_rate_limit WHERE ip_hash = ?',
  ).bind(key).first()
  if (row && now - row.last_request_ts < cooldownMs) return 'rate_limited_cooldown'
  if (row && now - row.window_start_ts < day && row.request_count >= perDay) return 'rate_limited'
  const fresh = !row || now - row.window_start_ts >= day
  await env.DB.prepare(
    'INSERT INTO report_rate_limit (ip_hash, request_count, window_start_ts, last_request_ts) VALUES (?, ?, ?, ?) ' +
      'ON CONFLICT(ip_hash) DO UPDATE SET request_count = ?, window_start_ts = ?, last_request_ts = ?',
  ).bind(key, 1, now, now, fresh ? 1 : row.request_count + 1, fresh ? now : row.window_start_ts, now).run()
  return null
}

// lb.frogwizard.net is the site; lm.frogwizard.net (its name before the rename) sends visitors on to it.
const ALLOWED_HOSTNAMES = new Set(['lb.frogwizard.net', 'lm.frogwizard.net', 'frogwizard.net', 'www.frogwizard.net'])

// Browsers' cross-site posts are refused; curl can fake Origin, which the rate limits and checks cover.
export function allowedOrigin(request) {
  const origin = request.headers.get('origin')
  if (!origin) return true
  try {
    const host = new URL(origin).hostname
    return ALLOWED_HOSTNAMES.has(host) || host === 'loremaster-report.pages.dev' || host.endsWith('.loremaster-report.pages.dev')
  } catch {
    return false
  }
}

export const json = (status, payload) =>
  new Response(JSON.stringify(payload), { status, headers: { 'Content-Type': 'application/json' } })
