"""Copies the quest addons' data files Lorebound builds from into the repository's sources/ folder, from this PC's
AddOns folder (run it after Zquest, Quest Completist or ForeverDungeonJournal update, then commit the change; the
weekly update on GitHub builds from these copies). Questie's blacklist is also fetched fresh on GitHub each week.

    python tools/refresh_sources.py
"""
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "..", "sources")
ADDONS = r"C:\Games\World of Warcraft\_forever_\Interface\AddOns"
# What to copy: (from, under the AddOns folder; to, under sources/).
COPIES = [
    ("Zquest/Data", "Zquest/Data"),
    ("Zquest/LICENSE.md", "Zquest/LICENSE.md"),
    ("QuestCompletist/Forever/qcQuestData.lua", "QuestCompletist/qcQuestData.lua"),
    ("Questie/Database/Corrections/QuestieQuestBlacklist.lua", "Questie/QuestieQuestBlacklist.lua"),
    ("ForeverDungeonJournal/Data/Dungeons.lua", "ForeverDungeonJournal/Dungeons.lua"),
]


def main():
    for source, target in COPIES:
        src, dst = os.path.join(ADDONS, source), os.path.join(SOURCES, target)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
        elif os.path.exists(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
        else:
            print("missing", src)
            continue
        print("copied", target)


if __name__ == "__main__":
    main()
