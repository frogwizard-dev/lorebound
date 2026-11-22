"""A small reader for WDC5 .db2 tables (the game's client database), enough to list their records.

    from db2 import read
    rows, strings = read(data)   # rows: { id: [field values...] } (arrays as lists, strings as str)

Strings are resolved where a field is a string-table offset (pass string_fields=[index, ...]).
Encrypted sections (tact key) are skipped. Copy-table rows are included.

Tables with variable-sized records (an offset map, such as Spell.db2) can't be read field by field
this way: read_variable(data) gives each record's raw bytes instead ({ id: bytes }).
"""
import struct

HEADER = "<IIIIIIIIIHHIIIIIII"
SECTION = "<QIIIIIIII"


def _bits(data, bit_offset, bit_count):
    byte = bit_offset >> 3
    shift = bit_offset & 7
    need = (shift + bit_count + 7) >> 3
    v = int.from_bytes(data[byte:byte + need], "little")
    return (v >> shift) & ((1 << bit_count) - 1)


def _sections(d, off, count):
    sections = []
    for _ in range(count):
        s = struct.unpack_from(SECTION, d, off)
        off += struct.calcsize(SECTION)
        sections.append(dict(key=s[0], file_offset=s[1], record_count=s[2], string_size=s[3], offset_records_end=s[4],
                             id_list_size=s[5], relationship_size=s[6], offset_map_count=s[7], copy_count=s[8]))
    return sections, off


def read_variable(d):
    """{ id: the record's bytes } for a table with an offset map; strings are inline, null-terminated."""
    assert d[:4] == b"WDC5", d[:4]
    off = 4 + 4 + 128
    header = struct.unpack_from(HEADER, d, off)
    flags, section_count = header[9], header[17]
    assert flags & 1, "not an offset-map table: use read()"
    sections, _ = _sections(d, off + struct.calcsize(HEADER), section_count)
    rows = {}
    for sec in sections:
        so = sec["offset_records_end"]
        ids = list(struct.unpack_from("<%dI" % (sec["id_list_size"] // 4), d, so)) if sec["id_list_size"] else []
        so += sec["id_list_size"]
        copies = [struct.unpack_from("<II", d, so + 8 * i) for i in range(sec["copy_count"])]
        so += 8 * sec["copy_count"]
        entries = [struct.unpack_from("<IH", d, so + 6 * i) for i in range(sec["offset_map_count"])]
        so += 6 * sec["offset_map_count"]
        so += sec["relationship_size"]
        map_ids = struct.unpack_from("<%dI" % sec["offset_map_count"], d, so) if sec["offset_map_count"] else ()
        for i, (offset, size) in enumerate(entries):
            rid = map_ids[i] if map_ids else (ids[i] if i < len(ids) else None)
            if rid is not None and size:
                rows[rid] = d[offset:offset + size]
        for new, old in copies:
            if old in rows:
                rows[new] = rows[old]
    return rows


def read(d, string_fields=()):
    assert d[:4] == b"WDC5", d[:4]
    off = 4 + 4 + 128
    (record_count, field_count, record_size, string_table_size, table_hash, layout_hash, min_id, max_id,
     locale, flags, id_index, total_field_count, bitpacked_offset, lookup_column_count, field_storage_info_size,
     common_data_size, pallet_data_size, section_count) = struct.unpack_from(HEADER, d, off)
    sections, off = _sections(d, off + struct.calcsize(HEADER), section_count)
    fields = []
    for _ in range(field_count):
        size, pos = struct.unpack_from("<hH", d, off)
        off += 4
        fields.append((size, pos))
    storage = []
    for _ in range(field_count):
        s = struct.unpack_from("<HHIIIII", d, off)
        off += 24
        storage.append(dict(offset_bits=s[0], size_bits=s[1], additional=s[2], type=s[3], v1=s[4], v2=s[5], v3=s[6]))
    pallet = d[off:off + pallet_data_size]
    off += pallet_data_size
    common_start = off
    common = {}
    co = off
    for i, st in enumerate(storage):
        if st["type"] == 2:
            m = {}
            for _ in range(st["additional"] // 8):
                rid, val = struct.unpack_from("<II", d, co)
                co += 8
                m[rid] = val
            common[i] = m
    off = common_start + common_data_size

    # Pallet offsets per field.
    pallet_offset = {}
    po = 0
    for i, st in enumerate(storage):
        if st["type"] in (3, 4):
            pallet_offset[i] = po
            po += st["additional"]

    # String offsets count from the field, in a layout where every section's records come first and
    # every section's string table follows them, in section order.
    total_records = sum(s["record_count"] for s in sections) * record_size
    string_tables = []  # (start in that combined string data, size, file offset)
    combined = 0
    for s in sections:
        string_tables.append((combined, s["string_size"], s["file_offset"] + s["record_count"] * record_size))
        combined += s["string_size"]

    def string_at(index):
        for start, size, file_offset in string_tables:
            if start <= index < start + size:
                p = file_offset + index - start
                return d[p:d.index(b"\0", p)].decode("utf-8", "replace")
        return None

    rows = {}
    records_before = 0  # bytes of records in the sections before this one
    for sec in sections:
        so = sec["file_offset"]
        if flags & 1:  # offset map (variable records) not handled
            raise NotImplementedError("offset-map tables")
        records_start = so
        so += sec["record_count"] * record_size
        string_start = so
        so += sec["string_size"]
        ids = list(struct.unpack_from("<%dI" % (sec["id_list_size"] // 4), d, so)) if sec["id_list_size"] else []
        so += sec["id_list_size"]
        copies = [struct.unpack_from("<II", d, so + 8 * i) for i in range(sec["copy_count"])]
        so += 8 * sec["copy_count"]
        so += sec["offset_map_count"] * 6
        # relationship map
        rel = {}
        if sec["relationship_size"]:
            n, mn, mx = struct.unpack_from("<III", d, so)
            for i in range(n):
                foreign, index = struct.unpack_from("<II", d, so + 12 + 8 * i)
                rel[index] = foreign
        for r in range(sec["record_count"]):
            ro = records_start + r * record_size
            rec = d[ro:ro + record_size]
            vals = []
            for i, st in enumerate(storage):
                t = st["type"]
                if t == 0:
                    size_bytes = st["size_bits"] // 8
                    count = max(1, (fields[i + 1][1] - fields[i][1]) // size_bytes if i + 1 < len(fields) else (record_size - fields[i][1]) // size_bytes) if size_bytes else 1
                    base = st["offset_bits"] // 8
                    arr = [int.from_bytes(rec[base + k * size_bytes:base + (k + 1) * size_bytes], "little") for k in range(count)]
                    vals.append(arr[0] if count == 1 else arr)
                elif t in (1, 5):
                    v = _bits(rec, st["offset_bits"], st["size_bits"])
                    if t == 5 and v >> (st["size_bits"] - 1):
                        v -= 1 << st["size_bits"]
                    vals.append(v)
                elif t == 2:
                    vals.append(None)  # filled after the id is known
                elif t == 3:
                    idx = _bits(rec, st["offset_bits"], st["size_bits"])
                    vals.append(struct.unpack_from("<I", pallet, pallet_offset[i] + idx * 4)[0])
                elif t == 4:
                    idx = _bits(rec, st["offset_bits"], st["size_bits"])
                    n = st["v3"]
                    vals.append([struct.unpack_from("<I", pallet, pallet_offset[i] + (idx * n + k) * 4)[0] for k in range(n)])
                else:
                    vals.append(None)
            rid = ids[r] if ids else vals[id_index]
            for i in common:
                vals[i] = common[i].get(rid, storage[i]["v1"])
            for i in string_fields:
                v = vals[i]
                if isinstance(v, int) and v:
                    field = records_before + r * record_size + storage[i]["offset_bits"] // 8
                    vals[i] = string_at(field + v - total_records)
                elif v == 0:
                    vals[i] = ""
            if r in rel:
                vals.append(("rel", rel[r]))
            rows[rid] = vals
        for new, old in copies:
            if old in rows:
                rows[new] = list(rows[old])
        records_before += sec["record_count"] * record_size
    return rows, dict(table_hash=table_hash, fields=field_count, storage=storage)
