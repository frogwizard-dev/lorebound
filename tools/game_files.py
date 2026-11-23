"""Forever's game files by file ID or path, for Lorebound's tools: the local client's when it's installed (and the
file isn't held encrypted), else wago.tools's copy of the newest Forever build. So the tools run the same on this
PC and on GitHub's machines, which have no game. wago.tools's copies are cached in lore_sources/files/<build>/.

    from game_files import GameFiles
    files = GameFiles()
    raw = files.read_fdid(1139443)             # QuestV2.db2
    raw = files.read_name("interface/icons/inv_misc_book_09.blp")
    rows = wago_csv("ItemSparse")               # one of Forever's tables, as CSV rows
"""
import csv
import json
import os
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "lore_sources", "files")
LISTFILES = (os.path.join(HERE, "listfile", "community-listfile.csv"),  # the whole community listfile, on this PC
             os.path.join(HERE, "listfile-lorebound.csv"))             # the parts the tools use, kept in the repo
AGENT = {"User-Agent": "Mozilla/5.0 (compatible; lorebound-data)"}
BUILDS = "https://wago.tools/api/builds"
FILE = "https://wago.tools/api/casc/%d?download&version=%s"
PAUSE = 0.4      # seconds between downloads from wago.tools, so a run of them doesn't trip its rate limit
TRIES = 6        # a "too many requests" or server error is waited out and tried again this many times
TABLE = "https://wago.tools/db2/%s/csv?product=wowf"


def download(url):
    """A file from wago.tools, or None when it hasn't got it (404). Paced, and a 429 (too many requests) or a server
    error is waited out (its Retry-After, else a growing pause) and tried again."""
    for attempt in range(TRIES):
        time.sleep(PAUSE)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=120) as res:
                return res.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            if error.code != 429 and error.code < 500 or attempt == TRIES - 1:
                raise
            wait = error.headers.get("Retry-After")
            wait = float(wait) if wait and wait.replace(".", "", 1).isdigit() else 5 * 2 ** attempt
            print("  wago.tools said %d; waiting %.0f s" % (error.code, min(wait, 120)), flush=True)
            time.sleep(min(wait, 120))


def wago_csv(table):
    """Forever's table from wago.tools as CSV rows (cached in lore_sources for a day): the client's own data,
    also for tables db2.py can't parse."""
    path = os.path.join(HERE, "lore_sources", table + ".csv")
    if not os.path.exists(path) or time.time() - os.path.getmtime(path) > 24 * 3600:
        raw = download(TABLE % table)
        if raw is None:
            raise RuntimeError("wago.tools has no table " + table)
        with open(path, "wb") as f:
            f.write(raw)
    csv.field_size_limit(10 ** 7)  # ItemSparse's descriptions
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


class GameFiles:
    def __init__(self, local=True):
        self.casc = None
        if local and not os.environ.get("LOREBOUND_NO_CLIENT"):
            try:
                from casc import Casc
                self.casc = Casc()
            except Exception:  # no game here (GitHub), or no casc.py: wago.tools only
                self.casc = None
        self._build = None
        self._paths = None

    def build(self):
        """The newest Forever build wago.tools has (its files are that build's)."""
        if self._build is None:
            with urllib.request.urlopen(urllib.request.Request(BUILDS, headers=AGENT), timeout=60) as res:
                self._build = json.load(res)["wowf"][0]["version"]
        return self._build

    def read_fdid(self, fid):
        raw = self.casc.read_fdid(fid) if self.casc else None
        if raw and raw[:4] != b"\0\0\0\0":  # unreleased content is held encrypted: zeros
            return raw
        return self.wago(fid)

    def wago(self, fid):
        path = os.path.join(CACHE, self.build(), "%d" % fid)
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            raw = download(FILE % (fid, self.build()))
            if raw is None:
                return None
            with open(path, "wb") as f:
                f.write(raw)
        return open(path, "rb").read()

    def read_name(self, name):
        if self.casc:
            raw = self.casc.read_name(name)
            if raw and raw[:4] != b"\0\0\0\0":
                return raw
        fid = self.paths().get(name.lower())
        return self.read_fdid(fid) if fid else None

    def paths(self):
        """{ path: file ID } from the listfile (the whole one when it's here, else the repo's part of it)."""
        if self._paths is None:
            self._paths = {}
            for listfile in LISTFILES:
                if os.path.exists(listfile):
                    with open(listfile, encoding="utf-8") as f:
                        for line in f:
                            fid, _, path = line.strip().partition(";")
                            if fid.isdigit():
                                self._paths[path.lower()] = int(fid)
                    break
        return self._paths
