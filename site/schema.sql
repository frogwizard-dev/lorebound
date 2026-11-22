-- D1 schema: the endpoints' per-IP rate limit (hashed IPs only) and the progress links.
--   wrangler d1 execute loremaster-report --remote --file=schema.sql
-- Without the binding the endpoint skips rate limiting (and logs a warning).

CREATE TABLE IF NOT EXISTS report_rate_limit (
  ip_hash TEXT PRIMARY KEY,
  request_count INTEGER NOT NULL,
  window_start_ts INTEGER NOT NULL,
  last_request_ts INTEGER NOT NULL
);

-- Private progress links (/p/<id>): a character's export code; the token's hash lets the browser that made
-- the link update it.
CREATE TABLE IF NOT EXISTS progress (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL,
  code TEXT NOT NULL,
  updated INTEGER NOT NULL
);
