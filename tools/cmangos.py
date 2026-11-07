"""Rows from the CMaNGOS classic world database dump (https://github.com/cmangos/classic-db, GPL-3.0): exact
NPC and object spawns (with heights) and creature levels and factions. Put Full_DB/ClassicDB_*.sql.gz in
ext/cmangos/.

    from cmangos import table
    for row in table("creature"): ...    # tuples in the table's column order (see COLUMNS)
"""
import glob
import gzip
import os
import re

DUMP_GLOB = os.path.join(os.path.dirname(__file__), "../ext/cmangos/ClassicDB_*.sql.gz")
# column positions used by the tools
COLUMNS = {
    "creature": dict(guid=0, id=1, map=2, x=4, y=5, z=6, spawndist=10, movement=11),
    "gameobject": dict(guid=0, id=1, map=2, x=4, y=5, z=6),
    "creature_movement": dict(guid=0, point=1, x=2, y=3, z=4),
    "creature_template": dict(entry=0, name=1, minlevel=3, maxlevel=4, faction=9, npcflags=16, unitflags=17,
                              extraflags=19, detection=27, rank=33, civilian=84),
}
TOKEN = re.compile(r"'((?:[^'\\]|\\.)*)'|(NULL)|([-+0-9.eE]+)|(\()|(\))")


def _rows(values):
    row = None
    for m in TOKEN.finditer(values):
        s, null, num, op, cl = m.groups()
        if op:
            row = []
        elif cl:
            yield tuple(row)
            row = None
        elif row is not None:
            if s is not None:
                row.append(re.sub(r"\\(.)", r"\1", s))
            elif null:
                row.append(None)
            else:
                row.append(float(num) if any(c in num for c in ".eE") else int(num))


def table(name):
    """Every row of one table, as tuples."""
    dump = sorted(glob.glob(DUMP_GLOB))
    if not dump:
        raise SystemExit("no CMaNGOS dump in ext/cmangos (see tools/cmangos.py)")
    prefix = "INSERT INTO `%s` VALUES " % name
    with gzip.open(dump[-1], "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith(prefix):
                yield from _rows(line[len(prefix):])
