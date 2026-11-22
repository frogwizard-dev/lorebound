"""Minimal read-only CASC reader for a local WoW install (enough to pull interface files by path)."""
import os, struct, zlib, sys

WOW = r"C:\Games\World of Warcraft"
DATA = os.path.join(WOW, "Data")


def build_config():
    lines = open(os.path.join(WOW, ".build.info"), encoding="utf-8").read().splitlines()
    head = [h.split("!")[0] for h in lines[0].split("|")]
    rows = [dict(zip(head, line.split("|"))) for line in lines[1:]]
    # The released Forever ("wowf") first; CASC_PRODUCT picks another (wow_classic_beta, ...).
    want = os.environ.get("CASC_PRODUCT", "wowf")
    rows.sort(key=lambda r: r.get("Product") != want)
    for row in rows:
        if row.get("Active") == "1":
            key = row["Build Key"]
            path = os.path.join(DATA, "config", key[:2], key[2:4], key)
            cfg = {}
            for l in open(path, encoding="utf-8"):
                if " = " in l:
                    k, v = l.strip().split(" = ", 1)
                    cfg[k] = v.split()
            return cfg, row


def load_indices():
    files = {}
    for f in os.listdir(os.path.join(DATA, "data")):
        if f.endswith(".idx"):
            bucket = f[:2]
            if bucket not in files or f > files[bucket]:
                files[bucket] = f
    index = {}
    for f in files.values():
        b = open(os.path.join(DATA, "data", f), "rb").read()
        hdr_size = struct.unpack_from("<I", b, 0)[0]
        key_bytes = b[8 + 6]
        pos = 8 + hdr_size
        pos = (pos + 15) & ~15
        entries_size = struct.unpack_from("<I", b, pos)[0]
        pos += 8
        entry_len = 9 + 5 + 4
        for i in range(entries_size // entry_len):
            e = pos + i * entry_len
            ekey = b[e:e + 9]
            off = int.from_bytes(b[e + 9:e + 14], "big")
            size = struct.unpack_from("<I", b, e + 14)[0]
            index[ekey] = (off >> 30, off & 0x3FFFFFFF, size)
    return index


def blte(data):
    assert data[:4] == b"BLTE", data[:4]
    hsize = struct.unpack_from(">I", data, 4)[0]
    out = []
    if hsize == 0:
        chunks = [(len(data) - 8, None)]
        pos = 8
    else:
        count = int.from_bytes(data[9:12], "big")
        chunks = []
        p = 12
        for _ in range(count):
            c, d = struct.unpack_from(">II", data, p)
            chunks.append((c, d))
            p += 24
        pos = hsize
    for csize, dsize in chunks:
        chunk = data[pos:pos + csize]
        pos += csize
        mode = chunk[:1]
        if mode == b"N":
            out.append(chunk[1:])
        elif mode == b"Z":
            out.append(zlib.decompress(chunk[1:]))
        elif mode == b"E":
            # Encrypted (content not yet released): zeros of its size, when that's known. Tables
            # mark such sections themselves (db2.py skips them).
            if dsize is None:
                raise ValueError("encrypted chunk")
            out.append(bytes(dsize))
        else:
            raise ValueError("unknown chunk mode %r" % mode)
    return b"".join(out)


class Casc:
    def __init__(self):
        self.cfg, self.row = build_config()
        self.index = load_indices()
        self.handles = {}
        self.load_encoding()
        self.load_root()

    def raw(self, ekey):
        loc = self.index.get(ekey[:9])
        if not loc:
            raise KeyError("ekey not in local storage: " + ekey.hex())
        arc, off, size = loc
        h = self.handles.get(arc)
        if not h:
            h = self.handles[arc] = open(os.path.join(DATA, "data", "data.%03d" % arc), "rb")
        h.seek(off)
        blob = h.read(size)
        # Usually a 30-byte header comes first; some entries point straight at the BLTE data
        # (their size is then the data's own).
        if blob[:4] == b"BLTE":
            return blte(blob)
        return blte(blob[30:])

    def load_encoding(self):
        ekey = bytes.fromhex(self.cfg["encoding"][1])
        b = self.raw(ekey)
        assert b[:2] == b"EN"
        ck, ek = b[3], b[4]
        cpage_kb = struct.unpack_from(">H", b, 5)[0]
        ccount = struct.unpack_from(">I", b, 9)[0]
        espec_size = struct.unpack_from(">I", b, 18)[0]
        pos = 22 + espec_size + ccount * (ck + 16)
        self.c2e = {}
        for p in range(ccount):
            page = b[pos:pos + cpage_kb * 1024]
            pos += cpage_kb * 1024
            i = 0
            while i < len(page):
                n = page[i]
                if n == 0:
                    break
                ckey = page[i + 6:i + 6 + ck]
                self.c2e[ckey] = page[i + 6 + ck:i + 6 + ck + ek]
                i += 6 + ck + ek * n

    def load_root(self):
        ckey = bytes.fromhex(self.cfg["root"][0])
        b = self.raw(self.c2e[ckey])
        self.by_name = {}
        self.by_fdid = {}
        assert b[:4] == b"TSFM", b[:4]
        hsize, version = struct.unpack_from("<II", b, 4)
        if hsize in (0x18, 0x14) and version in (1, 2):
            total, named = struct.unpack_from("<II", b, 12)
            pos = hsize
        else:
            version = 0
            total, named = hsize, version
            pos = 12
        while pos < len(b):
            if version >= 2:
                n, locale, f1, f2 = struct.unpack_from("<IIII", b, pos)
                f3 = b[pos + 16]
                content = f1 | f2 | (f3 << 17)
                pos += 17
            else:
                n, content, locale = struct.unpack_from("<III", b, pos)
                pos += 12
            fdids = struct.unpack_from("<%di" % n, b, pos)
            pos += 4 * n
            ckeys = [b[pos + 16 * i:pos + 16 * i + 16] for i in range(n)]
            pos += 16 * n
            hashes = None
            if not (content & 0x10000000):
                hashes = struct.unpack_from("<%dQ" % n, b, pos)
                pos += 8 * n
            fd = -1
            enus = locale & 0x2 or locale == 0xFFFFFFFF or locale == 0
            for i in range(n):
                fd = fd + 1 + fdids[i]
                if enus or fd not in self.by_fdid:
                    self.by_fdid[fd] = ckeys[i]
                    if hashes:
                        self.by_name[hashes[i]] = ckeys[i]

    def read_name(self, path):
        ck = self.by_name.get(jenkins(path))
        if ck is None:
            return None
        return self.raw(self.c2e[ck])

    def read_fdid(self, fd):
        ck = self.by_fdid.get(fd)
        return ck and self.raw(self.c2e[ck])


def _rot(x, k):
    return ((x << k) | (x >> (32 - k))) & 0xFFFFFFFF


def hashlittle2(data, pc=0, pb=0):
    length = len(data)
    a = b = c = (0xDEADBEEF + length + pc) & 0xFFFFFFFF
    c = (c + pb) & 0xFFFFFFFF
    i = 0
    while length > 12:
        a = (a + struct.unpack_from("<I", data, i)[0]) & 0xFFFFFFFF
        b = (b + struct.unpack_from("<I", data, i + 4)[0]) & 0xFFFFFFFF
        c = (c + struct.unpack_from("<I", data, i + 8)[0]) & 0xFFFFFFFF
        a = (a - c) & 0xFFFFFFFF; a ^= _rot(c, 4); c = (c + b) & 0xFFFFFFFF
        b = (b - a) & 0xFFFFFFFF; b ^= _rot(a, 6); a = (a + c) & 0xFFFFFFFF
        c = (c - b) & 0xFFFFFFFF; c ^= _rot(b, 8); b = (b + a) & 0xFFFFFFFF
        a = (a - c) & 0xFFFFFFFF; a ^= _rot(c, 16); c = (c + b) & 0xFFFFFFFF
        b = (b - a) & 0xFFFFFFFF; b ^= _rot(a, 19); a = (a + c) & 0xFFFFFFFF
        c = (c - b) & 0xFFFFFFFF; c ^= _rot(b, 4); b = (b + a) & 0xFFFFFFFF
        i += 12
        length -= 12
    if length == 0:
        return c, b
    tail = data[i:] + b"\0" * 12
    a = (a + struct.unpack_from("<I", tail, 0)[0]) & 0xFFFFFFFF
    b = (b + struct.unpack_from("<I", tail, 4)[0]) & 0xFFFFFFFF
    c = (c + struct.unpack_from("<I", tail, 8)[0]) & 0xFFFFFFFF
    c ^= b; c = (c - _rot(b, 14)) & 0xFFFFFFFF
    a ^= c; a = (a - _rot(c, 11)) & 0xFFFFFFFF
    b ^= a; b = (b - _rot(a, 25)) & 0xFFFFFFFF
    c ^= b; c = (c - _rot(b, 16)) & 0xFFFFFFFF
    a ^= c; a = (a - _rot(c, 4)) & 0xFFFFFFFF
    b ^= a; b = (b - _rot(a, 14)) & 0xFFFFFFFF
    c ^= b; c = (c - _rot(b, 24)) & 0xFFFFFFFF
    return c, b


def jenkins(path):
    s = path.replace("/", "\\").upper().encode("utf-8")
    c, b = hashlittle2(s)
    return (c << 32) | b


if __name__ == "__main__":
    cs = Casc()
    print("files by id:", len(cs.by_fdid), "named:", len(cs.by_name))
