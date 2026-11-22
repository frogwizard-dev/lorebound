"""Lorebound's whole data update in one go on this PC: players' reports in, the quest list built and checked, the
quest pages filled, the site's art and quest list out, the addon's data copied into the game and the site deployed.
(The weekly GitHub update, .github/workflows/update.yml, does the same and releases instead of syncing.)

    python update_lore.py            # in tools/
    python update_lore.py --close    # also closes the report issues it read, once the list is built

Steps: make_lore.py --pull (the quest reports you've approved, each checked against the game's quest list and
Wowhead; new quest IDs in the client named in lore_reports/new-in-client.txt), lore_wowhead.py (Forever's
objectives for new quests), make_lore.py again (the pages with that text), make_lore_site_art.py (only art not
made before), _tools/sync_addon.py for Lorebound_Data and the three Lorebound_Text parts, and `npm run deploy` in site/. Stops at the first
step that fails. Needs `gh` signed in as frogwizard-dev and wrangler logged in.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "..", "site")
SYNC = os.path.join(HERE, "..", "..", "_tools", "sync_addon.py")  # this PC's game folder (not on GitHub)


def run(title, args, cwd=HERE):
    print("\n== " + title)
    result = subprocess.run(args, cwd=cwd, shell=(os.name == "nt" and args[0] == "npm"))
    if result.returncode != 0:
        sys.exit("stopped: %s failed (exit %d)" % (title, result.returncode))


def main():
    python = sys.executable
    build = [python, "make_lore.py", "--pull"] + (["--close"] if "--close" in sys.argv else [])
    run("quest list", build)
    run("Forever's objectives from Wowhead (new quests only)", [python, "lore_wowhead.py"])
    run("quest pages", [python, "make_lore.py"])  # again, now Wowhead's text is in for the new quests
    run("site art", [python, "make_lore_site_art.py"])
    if os.path.exists(SYNC):
        run("addon data into the game", [python, SYNC, "Lorebound_Data", "Lorebound_Text", "Lorebound_Text_EasternKingdoms",
                                         "Lorebound_Text_Kalimdor"])
    run("site deploy", ["npm", "run", "deploy"], cwd=SITE)
    for name in ("needs-a-look.txt", "new-in-client.txt"):
        path = os.path.join(HERE, "lore_reports", name)
        if os.path.exists(path):
            print("worth a look: lore_reports/" + name)
    print("\ndone: /reload in game for the new list")


if __name__ == "__main__":
    main()
