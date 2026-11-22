# lb.frogwizard.net: Lorebound's site

Three things: **browse** every quest (`/`, `/zone/<n>`), a character's **progress** from Lorebound's "Export to
website" code (`/me`, decoded in the browser; `/p/<id>` private links through `functions/api/progress.js`, stored
in D1 with a token only the saving browser has), and **quest reports**: players paste the code from Lorebound's
**Share new quests** box into `/report`; the function turns it
into a GitHub issue (label `quest-report`) in a reports repository, through a service account's token, so
nobody needs to sign in. It's the same shape as Warscribe's feedback endpoint: honeypot, origin check,
per-IP rate limit in D1 (hashed IPs), and only Lorebound's own `LM1^...` lines reach the issue.

- `public/index.html`, `app.js`, `style.css`: the site (one page, routes in `_redirects`); `report.html`: reports;
  `404.html`: missing pages and files (so a missing data file is a 404, not the app's HTML).
- `public/data/`: the quest list for each list version, written by `make_lore.py` (old versions stay, so old codes read).
- `public/art/`: the game's maps (fully revealed), the dungeon journal's paintings, the addon's badge frames and the
  class and profession icons, written by `make_lore_site_art.py`. `public/vendor/qrcode.min.js`: qrcode-generator
  1.4.4 (MIT), kept here rather than loaded from a CDN, since the page holds link tokens.
- `functions/api/report.js`: `POST /api/report`; `functions/api/progress.js`: progress links; `functions/_lib/limit.js`:
  rate limits and origin check.
- `schema.sql`: the rate limit's and progress links' tables.
- `wrangler.jsonc`: the Pages project.

## Setting it up (once)

1. **Reports repository**: create `frogwizard-dev/loremaster-reports` (public or private) with a
   `quest-report` label.
2. **Token**: a fine-grained personal access token on the account that should file the issues, with
   access to that one repository only and *Issues: Read and write*.
3. **Pages project**: `npx wrangler login`, then from this folder
   `npx wrangler pages project create loremaster-report`.
4. **Rate limit (optional but recommended)**: `npx wrangler d1 create loremaster-report`, put the printed
   `database_id` into `wrangler.jsonc`, then `npx wrangler d1 execute loremaster-report --remote --file=schema.sql`.
5. **Settings**: `npx wrangler pages secret put REPORT_GH_TOKEN --project-name loremaster-report` (paste the
   token), and in the dashboard (Pages > loremaster-report > Settings > Variables) add `REPORT_REPO` =
   `frogwizard-dev/loremaster-reports`.
6. **Deploy**: `npx wrangler pages deploy`.
7. **Domain**: Pages > loremaster-report > Custom domains > add `lb.frogwizard.net` (a CNAME to
   `loremaster-report.pages.dev`; automatic when frogwizard.net's DNS is on Cloudflare).

## Getting reports into Lorebound

`python make_lore.py --pull` (from `_tools`) saves every open `quest-report` issue as
`lore_reports/issue-<number>.txt` (through `gh`, signed in as an account that can read the repository:
`gh auth switch -u frogwizard-dev`), then builds the data as usual. Close the issues once that data is
released (`python make_lore.py --pull --close` closes the ones it read, with a thank-you).

Each reported quest is checked before it's taken: its ID must be in the game's own quest list, and its name must
match Wowhead's (Forever section, one cached lookup per quest). The rest go to `lore_reports/needs-a-look.txt`
with the reason (made-up IDs, quests Wowhead marks not yet implemented); `--trust` takes them anyway.

## Updating everything

`python update_lore.py` (from `_tools`) does the lot: pulls the open reports, builds the quest list (checking each
reported quest, and naming quest IDs a patch added in `lore_reports/new-in-client.txt`), makes any new art, copies
Lorebound_Data into the game and deploys this site. `--close` also closes the report issues it read.
