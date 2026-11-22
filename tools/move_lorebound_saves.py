"""Carries Loremaster's saved variables over to Lorebound (the rename of 2026-11-21): each account's and
character's SavedVariables/Loremaster.lua is copied to Lorebound.lua with its variables renamed.

    python move_lorebound_saves.py

Run it with the game closed: the game writes these files when it exits. A Lorebound.lua newer than its
Loremaster.lua (Lorebound has saved since) is left alone, so running it again is safe.
"""
import os

WTF = r"C:\Games\World of Warcraft\_forever_\WTF"

for dirpath, _, names in os.walk(WTF):
    if "Loremaster.lua" not in names or os.path.basename(dirpath) != "SavedVariables":
        continue
    old, new = os.path.join(dirpath, "Loremaster.lua"), os.path.join(dirpath, "Lorebound.lua")
    if os.path.exists(new) and os.path.getmtime(new) >= os.path.getmtime(old):
        print("kept", new)
        continue
    text = open(old, encoding="utf-8").read()
    text = text.replace("LoremasterCharDB", "LoreboundCharDB").replace("LoremasterDB", "LoreboundDB")
    with open(new, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("carried over", new)
