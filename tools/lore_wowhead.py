"""Forever's own objective text for each quest, from Wowhead's tooltip service (the one its embed script uses),
cached in lore_sources/wowhead_quests.json: { id: { "name", "objective", "needs": [[what, count]] } or null }.

    python lore_wowhead.py              # every quest in Lorebound_Data/Data.lua not yet cached
    python lore_wowhead.py 681 682      # only these

One request a second, saved every 25, so it can be stopped and run again. A quest Wowhead hasn't got is
cached as null and tried again after 30 days.
"""
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import lupa

from game_files import AGENT

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "Lorebound_Data", "Data.lua")
CACHE = os.path.join(HERE, "lore_sources", "wowhead_quests.json")
URL = "https://nether.wowhead.com/forever/tooltip/quest/%d"
PAUSE = 1.0
RETRY_MISSING = 30 * 24 * 3600


def quest_ids():
    lua = lupa.LuaRuntime()
    with open(DATA, encoding="utf-8") as f:
        lua.execute(f.read())
    return sorted(lua.globals().LoreboundData.quests.keys())


def parse(tooltip):
    """The tooltip's objective paragraphs and its requirement lines."""
    body = tooltip.split("</table>", 1)[-1]
    body = re.sub(r"<span class=\"q\">Requirements:</span>.*", "", body, flags=re.S)
    needs = [[html.unescape(what).strip(), int(count)] for what, count in
             re.findall(r"<br />\s*-\s*([^<]+?) x (\d+)", tooltip)]
    text = re.sub(r"<br\s*/?>", "\n", body)
    text = html.unescape(re.sub(r"<[^>]+>", "", text))
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", text) if part.strip()]
    return paragraphs, needs


def fetch(qid):
    req = urllib.request.Request(URL % qid, headers=AGENT)
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            answer = json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    if not answer.get("name"):
        return None
    paragraphs, needs = parse(answer.get("tooltip", ""))
    return {"name": answer["name"], "objective": paragraphs, "needs": needs}


def main():
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    cache = json.load(open(CACHE, encoding="utf-8")) if os.path.exists(CACHE) else {}
    ids = [int(arg) for arg in sys.argv[1:]] or quest_ids()
    now = time.time()
    todo = [qid for qid in ids if str(qid) not in cache
            or (cache[str(qid)] is None and now - cache.get("_missing_at", {}).get(str(qid), 0) > RETRY_MISSING)]
    print("wowhead: %d to fetch of %d" % (len(todo), len(ids)))
    for done, qid in enumerate(todo, 1):
        try:
            cache[str(qid)] = fetch(qid)
            if cache[str(qid)] is None:
                cache.setdefault("_missing_at", {})[str(qid)] = int(now)
        except Exception as error:  # Wowhead unreachable or slow: stop here, the next run carries on
            print("  stopped at quest %d: %s" % (qid, error))
            break
        if done % 25 == 0 or done == len(todo):
            with open(CACHE, "w", encoding="utf-8") as f:
                json.dump(cache, f, ensure_ascii=False, separators=(",", ":"))
            print("  %d / %d" % (done, len(todo)), flush=True)
        time.sleep(PAUSE)
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
