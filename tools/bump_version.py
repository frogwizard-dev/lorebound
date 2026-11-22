"""After the weekly quest list update (.github/workflows/update.yml): when the quest list, the quest pages or the
site changed, bumps the patch version in all of Lorebound's .toc files, adds a CHANGELOG.md entry saying what
changed, and hands the workflow the new tag (v1.2.3). Nothing changed: no tag, so nothing is released.

    python tools/bump_version.py
"""
import os
import re
import subprocess

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEXT_PARTS = ["Lorebound_Text", "Lorebound_Text_EasternKingdoms", "Lorebound_Text_Kalimdor"]
TOCS = ["Lorebound.toc", "Lorebound_Data/Lorebound_Data.toc"] + ["%s/%s.toc" % (part, part) for part in TEXT_PARTS]
WATCHED = ["Lorebound_Data", *TEXT_PARTS, "site/public"]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8").stdout


def quest_ids(source):
    if not source:
        return set()
    lua = lupa.LuaRuntime()
    lua.execute(source)
    return set(lua.globals().LoreboundData.quests.keys())


def main():
    if not git("status", "--porcelain", "--", *WATCHED).strip():
        print("nothing changed: no new version")
        return
    before = quest_ids(git("show", "HEAD:Lorebound_Data/Data.lua"))
    after = quest_ids(open(os.path.join(ROOT, "Lorebound_Data", "Data.lua"), encoding="utf-8").read())
    added, removed = len(after - before), len(before - after)

    toc = open(os.path.join(ROOT, TOCS[0]), encoding="utf-8").read()
    major, minor, patch = map(int, re.search(r"^## Version:\s*(\d+)\.(\d+)\.(\d+)", toc, re.M).groups())
    version = "%d.%d.%d" % (major, minor, patch + 1)
    for name in TOCS:
        path = os.path.join(ROOT, name)
        text = re.sub(r"^## Version:.*$", "## Version: " + version, open(path, encoding="utf-8").read(), flags=re.M)
        open(path, "w", encoding="utf-8", newline="\n").write(text)

    if added or removed:
        what = "%d quest%s added, %d removed (%d in all)" % (added, "" if added == 1 else "s", removed, len(after))
    else:
        what = "quest text, checks and art refreshed (%d quests)" % len(after)
    changelog = os.path.join(ROOT, "CHANGELOG.md")
    text = open(changelog, encoding="utf-8").read()
    at = text.index("\n## ") + 1 if "\n## " in text else len(text)
    entry = "## %s\n\n- Quest list update: %s.\n\n" % (version, what)
    open(changelog, "w", encoding="utf-8", newline="\n").write(text[:at] + entry + text[at:])

    print("new version", version, "-", what)
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as f:
            f.write("tag=v%s\n" % version)


if __name__ == "__main__":
    main()
