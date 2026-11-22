# Routine notes

Each run of the routine (Warscribe's /the-routine, adapted: Lua addon, Python tools, the site): every step, what it
read, what it found, what it fixed, and what waits on Mike. Never "none" for a step that didn't run.

Last routine: (this one, 2026-11-22; scope: the whole repository, its first)

## 2026-11-22: the whole repository

Scope: the addon (Core, Lore, Ring, Badge, Toast, Share, Export, Journal, Quest, Pad), tools/ (make_lore,
lore_pages, lore_wowhead, make_lore_site_art, make_lore_art, game_files, bump_version, refresh_sources,
update_lore; casc.py and db2.py are copies of _tools' and reviewed there), site/ (app.js, style.css, the pages,
the functions), .github/workflows.

### Per file, as read

- **Core.lua** (whole): a comment orphaned above the wrong function (moved); the two load-on-demand loaders
  repeated the load call (LoadPart); `Text()` renamed `NonEmpty()` (it returns the string or nil, not text);
  `ns.text` renamed `ns.questText`. No bugs: combat-deferred chat, secret-value guards and the nil turn-in path hold.
- **Lore.lua** (whole): `Why()`'s 16-branch if ladder became a table of words plus three special cases; `AddTo()`
  was `table.insert` (removed); one-letter names (`s`, `o`, `c`, `g`) renamed (`state`, `otherState`, `tally`,
  `groupTally`, `needState`, `parentState`, `known`). Checked before calling it a bug: `needsAny` isn't run through
  `math.abs` like `needsAll`, but the data has no negative needsAny entries (0 of 4,691). Proof: new
  `tools/check_lore.py` runs the committed and the working Lore.lua for four characters: 4,691 quests each, every
  status and reason identical.
- **Ring.lua** (whole): names only (`p` the share, `k` the animation's progress, `m` a side mask, `t` the time
  spent). Logic sound: clockwise by construction, the OnUpdate cleared once still.
- **Badge.lua** (whole): a real waste: `Badge.GroupPainting(5)` built a new table on every call, so the art cache
  (keyed on the painting) missed and the Class heading redrew its texture on every refresh; now one table per class.
  The Seal's icon named once (`SEAL_ICON`). Names: `w`/`h` (width, height), the overlay loop's `r`/`c`
  (tileRow, tileCol), `d`/`t`/`l`/`z` in Stats, `k`, `v`, `mx`/`my`. Kept on purpose as standard names: `x`/`y`/`z`
  (geometry), `u`/`v` (texture coordinates), `r`/`g`/`b` (colour).
- **Toast.lua** (whole): the toast's counts table was built in two places (Show's other-zone branch, Test):
  `InfoFor()`; a local named `next` shadowed Lua's `next` (`queued`); names `z`, `r`, `of`; a broken header line.
  Waits on Mike: "complete!" and "Lorebound!" carry exclamation marks (anti-slop's word rule); it's the
  celebration's voice he liked, so not changed without asking.
- **Share.lua, Export.lua** (whole): a bug: Share's field cleaner left backticks in, and the report page drops any
  line holding one, so a learned quest with a backtick in its name vanished from a report silently. The two files'
  near-identical cleaners became one `ns.Plain()` in Core (every separator either code uses, and what the site
  refuses), tested on separators, nil, numbers and apostrophes. `Share.Code` worked the pending list out twice;
  Share's header still pointed at `_tools/` (now `tools/`, `site/`); names `e`, `i`, `s`, `z`.
- **Journal.lua** (whole, 1,861 lines): the header still said `/lore`; a local `Share()` (a done/total fraction)
  read as the Share module beside `ns.Share` (`Fraction`); the coalesced-refresh timer and Draw's count of quests
  to share were both `pending`, one shadowing the other (`refreshTimer`, `toShare`); `Inspect` worked out
  `view.index` and nothing read it (InspectStep finds its place itself: removed); one-letter names across the
  status, map and header code (`s`, `c`, `d`/`t`, `z`, `r`, `w`/`h`, `mw`/`mh`/`ox`/`oy`, `a`/`b`, `e`, `p`).
  Renames done with a Lua-aware tool that skips strings and comments (the Toast `of` lesson below), then checked
  token by token in the word diff.
- **Quest.lua** (whole): `Side` and `Step` each scanned all 4,691 quests for a chain's members and `Step`
  re-fetched rows inside its comparison: one `ChainSteps()`; the new `Step` tested against the old on a chain with
  gaps and a shared step (same quest reached every way). Its `Fill` renamed `Layout` (it lays out the page; the
  journal's `Fill` fills placeholders and both are used here); a local `min` shadowed WoW's global (`minLevel`).
- **Pad.lua** (whole): the header's key table still said "ring" for the overview's badges and missed A opening a
  quest's page. Logic sound: binds only out of combat and never with a key held, lets go a frame after closing.
- **tools/make_lore.py** (whole, 1,090 lines): the docstring still called Lorebound "personal and never released"
  and read the addons from the AddOns folder (now `sources/`), and the generated Data.lua said "Personal" and
  `_tools/`. Waste: the chains (lore_pages.chains) were worked out three times a build (site data, Data.lua,
  lore_pages.write), now once and passed down (`chain_field()` for the one shape both files use). A leftover
  `if True:` wrapped the reports loop; ten imports repeated inside functions; `LISTFILE`, `WAGO_FILE`, `SOURCES`
  unused; a `game_file()` wrapper that only called `read_fdid`; the comment on professions sat above the capitals;
  QuestieDB field numbers written bare (`n[9]`, `o[5]`, `it[14]`), now named from QuestieDB's own meta files
  (NPC zone 9, object zone 5, item vendors 14). The inner `build()` shadowed the outer `build()` (`make_row`); short
  names (`q`, `f`, `hq`, `n`, `o`, `it`, `z`, `d`, `zl`, `r`/`c`/`w`/`h`) renamed with a token-aware tool (never
  inside strings).
- **tools/lore_pages.py, game_files.py** (whole): lore_pages imported make_lore from inside a function (a circular
  import that ran make_lore's module code a second time) only for `wago_csv`, which now lives in game_files beside
  the other wago.tools fetches; one user agent (`game_files.AGENT`, now "lorebound-data"); `urllib.error` used
  without its import; the site path in the docstring; names (`nxt`/`prev`, `c`, `i`, `n`, `p`, `r`, `m`).
- **tools/lore_wowhead.py, make_lore_site_art.py, make_lore_art.py** (whole): the old user agent and paths; three
  unused imports and two inner ones; two constants' comments fused onto one line; the draw-at-4x-and-shrink step
  written out three times in make_lore_art (`shrink()`); its closing message missed Halo and Shine; names in the
  tile maths (`tw`/`th`/`ow`/`oh`/`pw`/`ph`/`px`/`py`, `r`/`c`).
- **tools/update_lore.py, check_lore.py, bump_version.py, refresh_sources.py** (whole): update_lore's docstring
  (`_tools`, `loremaster-report`, two steps missing); check_lore ran `main()` on import. The others sound.
- Proof for the tools: a baseline build from a copy of the tools before any change, then the same build after:
  Data.lua and Text.lua identical but for their header comments, site/public/data untouched. make_lore_art redrew
  every texture byte for byte (git sees no change in Media/). make_lore_site_art --force from the old and the new
  script: all 138 files identical to each other (nine committed screen paintings predate the current packaged
  TGAs; put back as committed, not part of this). pyflakes clean on every tool but casc.py and db2.py (_tools'
  copies).
- **site/public/app.js** (whole, 968 lines): reason codes checked against Lore.lua's (1 to 17, 6 unused in both:
  they match). The `share()` helper renamed `fraction()` (as in the addon), so the rings read `{ share }` straight
  instead of renaming it `s`; one-letter names across the views (`c`, `p`, `zc`/`gc`, `g`, `z`, `r`, `st`, `n`, `a`).
  Dead: the reward slot's `q<quality>` class (no rule matched it, below). Kept on purpose: the `lm:` localStorage
  keys (the old name), since renaming them would make every browser forget its saved code and phone link. The
  rename tool skipped quoted strings, which hid two `${}` uses inside double-quoted attributes (`st`, `r.spell`)
  and renamed `<p>` tags inside templates to `<progress>`: all caught by the page test below, fixed, and the lesson
  is under "For the routine".
- **site/public/style.css** (whole; the CSS check): every class checked against what app.js and the pages make.
  Dead: `.hidden` (the app uses the hidden attribute), `.paper .items`/`.item`/`.item.q0` to `.q5` and the four
  `--q2` to `--q5` colours (from the reward list before the game's plates; a plate's name is light text, as in the
  game). Template-built classes (`c-*`, `shape-*`, `st-*`) checked by their templates.
- **site/functions, wrangler.jsonc, schema.sql, package.json, README.md, report.html, index.html, 404.html,
  _headers, _redirects** (whole): `_middleware.js` only forwarded lm.frogwizard.net, which is gone; a root
  middleware also made every request, static files included, a Functions invocation: removed (deleted in the
  working copy, not staged), with lm dropped from the allowed origins. report.js's header (`_tools/`, no word of
  the approved label), its user agent and the shared `no_loremaster_lines` error code (`no_report_lines`, in both
  files); package.json's name and description (lm, Loremaster); wrangler's comment (one function, now two); the
  README's `_tools` paths and missing approval step; schema.sql's header. Kept: the Pages project, D1 database and
  reports repository names (renaming those is outside the code).
- **.github/workflows** (whole): sound (the Wowhead cache is tracked, the downloads ignored, so `git add -A` only
  takes the build's output); update.yml's header reflowed.
- Proof for the site: `wrangler pages dev` with a made-up progress code saved through the local API, then headless
  Edge on eight pages (overview, zone, quest, /me, a phone link's overview, zone and quest, /report): every page's
  drawn DOM identical to the committed app.js's (before the dead-class removal), no console errors after the fixes,
  reward slots drawn on a quest that has them; the report endpoint refuses a foreign origin and answers
  not_configured locally; progress links read back.

### Anti-slop (step 7), over every file a person reads (addon, tools, site, docs; not the generated data)

- Dashes: none. Emoji: only the site's ✓ and ✕ quest marks, which sit beside the state's words (headings, labels),
  as the addon's ready-check icons do: kept. Vague errors: none. Title Case: none outside names.
- AI vocabulary: one, Lore.lua's "Whether you've got past" (rewritten plainly). Filler: "just these" and "just this
  version's" (now "only"); the other "just"s mean a moment ago and stay; LICENSE.md is legal text.
- Exclamation marks: the GitHub thank-you on closed reports ("Thank you!", now a full stop); "Welcome!" is a quest's
  own name. The journal's "Complete!" and the toasts' "complete!" and "Lorebound!" wait on Mike (below).
- Styles: every colour a token, no gradients, glass, glows, stripes or capital labels; motion only a 120 ms hover
  fade, behind prefers-reduced-motion. The continent ring is purple (`--arcane`, as the addon's ring), the one
  colour anti-slop names: colour with meaning, beside words, so noted for Mike rather than changed.

### Steps

| Step | Ran | Found and fixed |
| --- | --- | --- |
| 0 Scope | yes | the whole repository, its first routine |
| 1 CSS check | yes | `.hidden`, the old reward-list `.item` rules and four quality colours dead (removed) |
| 2 Lean | yes | chains worked out three times a build (once now); the Class painting rebuilt each refresh; Quest.lua scanning every quest twice per page; `view.index` and other dead code; the root middleware running on every request |
| 3 Condensing | yes | `ns.Plain`, `InfoFor`, `LoadPart`, `ChainSteps`, `chain_field`, `shrink`, Why's table; `wago_csv` moved to game_files |
| 4 Names | yes | one-letter names in every file; shadowed `next`, `min`, `build`, `pending`; `Share()` read as the module |
| 5 Readability | yes | stale headers and docstrings (`/lore`, `_tools`, "personal", lm, Loremaster); misplaced and fused comments |
| 6 Code review | yes | Share's backtick bug (reports silently dropped a quest); the circular import; `urllib.error` unimported; check_lore ran on import |
| 7 Anti-slop | yes | above |
| 8 Data pass | yes | rebuilt from a copy of the tools before any change and after: Data.lua and Text.lua identical but for their header comments; site data untouched; art byte for byte |
| 9 Proof | yes | 12 Lua files parse; check_lore 4 x 4,692 quests, 0 differ; site pages identical in headless Edge; the three folders synced, nothing extra copied |
| 10 Record | yes | this file |

### For the routine (lessons)

- A whole-word rename is never done with a bare regex: Toast's `of` became `outOf` inside a sentence. Lua and
  Python renames now go through token-aware tools (strings and comments skipped, nothing after a dot).
- JavaScript templates are the hard case both ways: skipping quoted strings hid `${}` code inside double-quoted
  attributes, and renaming template text turned `<p>` into `<progress>`. Rename only names you can see are code,
  then prove it by rendering the pages, not by syntax checks: `node --check` passed all three mistakes.
- Before calling the build "unchanged", build the old tools too, from a copy, on the same day's inputs: the
  committed outputs can lag the tools (nine site paintings did).

### Settled by Mike (2026-11-22)

- The celebration's exclamation marks ("Complete!", "<zone> complete!", "Lorebound!"): kept. Don't flag them again.
- The continent ring's purple (`--arcane`, the addon's group ring): kept. Don't flag it again.
- `site/functions/_middleware.js`: removed for good (lm.frogwizard.net is gone).
