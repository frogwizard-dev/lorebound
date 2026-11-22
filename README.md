# Lorebound

Every WoW Forever quest by zone: close each zone's ring, earn its badge, see why a quest is locked. An addon for
WoW Forever, with a site at [lb.frogwizard.net](https://lb.frogwizard.net) and on
[CurseForge](https://www.curseforge.com/wow/addons/lorebound).

## What's here

- The addon itself at the top: the journal, rings, badges, toasts, the quest page, controller support.
- `Lorebound_Data/`: the quest list; `Lorebound_Text/`, `Lorebound_Text_EasternKingdoms/` and
  `Lorebound_Text_Kalimdor/`: the quest pages' text in three parts by group, so a page loads only its third. All
  load-on-demand addons packaged beside Lorebound (see `.pkgmeta`), all generated: don't edit them by hand.
- `tools/`: what generates them. `make_lore.py` builds the quest list from `sources/` and the game's own tables
  (this PC's game files, or wago.tools's copy of Forever's newest build when there's no game), checks players'
  reports, and writes the site's data; `lore_wowhead.py` fetches Forever's objective text from Wowhead's tooltips;
  `lore_pages.py` makes the quest pages (CMaNGOS's classic-db text where Forever's objective matches Classic's);
  `make_lore_site_art.py` the site's art; `bump_version.py` the weekly version bump; `check_lore.py` proves a
  change to Lore.lua changes no quest's status it shouldn't (against the committed one).
- `sources/`: the quest addons' data the list starts from (Zquest's QuestieDB export, GPL-3.0; Quest Completist;
  Questie's blacklist; ForeverDungeonJournal's dungeon list). `tools/refresh_sources.py` copies newer versions in.
- `site/`: lb.frogwizard.net, a Cloudflare Pages project (`site/README.md`).

## Releases

- **By hand:** bump `## Version:` in the five .toc files, add a `## x.y.z` section to `CHANGELOG.md`, then push
  the tag `vx.y.z` (`publish.ps1 Lorebound -Release`). `.github/workflows/release.yml` packages it for GitHub and
  CurseForge.
- **Weekly:** `.github/workflows/update.yml` rebuilds the quest list every Monday (and on demand). When anything
  changed it bumps the patch version, notes it in the changelog, releases and deploys the site.

Secrets: `CF_API_KEY` (CurseForge), `LB_API_TOKEN` (a Cloudflare token with Pages edit) and `CLOUDFLARE_ACCOUNT_ID`
(the site), and optionally `REPORTS_TOKEN` (closes report issues in frogwizard-dev/loremaster-reports once they're
in).

## Licence

GPL-3.0 (`LICENSE.md`), as Zquest's data it's built from.
