#!/usr/bin/env python3
"""Author the test beds' font: a tiny TrueType face we own, plus its WOFF wrapper.

The MV/MZ text path rasterises the game's own bundled font with stb_truetype
(mruby-mvjs/src/mvcanvas.cxx). Neither test bed could ship one, because the
fonts real projects use are not redistributable — so `advanced.mainFontFilename`
was left empty, no text ever drew, and the WOFF unpacker added for MZ (RPG Maker
MZ projects ship `fonts/*.woff`) had nothing to exercise it in CI.

This writes a font that is entirely ours: a 5x7 dot-matrix face covering ASCII
32..126, each lit cell emitted as a square contour, hand-assembled into the
minimum set of sfnt tables stb_truetype needs (cmap/glyf/head/hhea/hmtx/loca/
maxp, plus name/post). It is deliberately blocky — legibility at 16-26px is the whole
requirement, not beauty.

Both forms are written:

  * `<bed>/fonts/Sample.ttf`  — the bare sfnt
  * `<bed>/fonts/Sample.woff` — the same tables in a WOFF 1.0 container

The MZ bed gets the **.woff**, which is what MZ games really ship and what makes
CI cover `woff_to_sfnt` end to end; the MV bed gets the .ttf.

Deterministic (no timestamps — the head table's dates are fixed), so re-running
is a no-op in git. Run from anywhere.
"""

import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")

UNITS_PER_EM = 1000
CELL = 100                      # one dot-matrix cell, in font units
COLS, ROWS = 5, 7
ADVANCE = (COLS + 1) * CELL     # one blank column of side bearing
ASCENT = ROWS * CELL
DESCENT = -CELL

# A 5x7 face for ASCII 32..126. Each glyph is 7 rows of 5 characters, top row
# first; '#' lights the cell. Kept legible rather than pretty — this is read at
# 16-26px in a message window.
GLYPHS = {
    " ": ["     "] * 7,
    "!": ["  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "     ", "  #  "],
    '"': [" # # ", " # # ", "     ", "     ", "     ", "     ", "     "],
    "#": [" # # ", " # # ", "#####", " # # ", "#####", " # # ", " # # "],
    "$": ["  #  ", " ####", "# #  ", " ### ", "  # #", "#### ", "  #  "],
    "%": ["##  #", "##  #", "   # ", "  #  ", " #   ", "#  ##", "#  ##"],
    "&": [" ##  ", "#  # ", "#  # ", " ##  ", "#  ##", "#  # ", " ## #"],
    "'": ["  #  ", "  #  ", "     ", "     ", "     ", "     ", "     "],
    "(": ["   # ", "  #  ", " #   ", " #   ", " #   ", "  #  ", "   # "],
    ")": [" #   ", "  #  ", "   # ", "   # ", "   # ", "  #  ", " #   "],
    "*": ["     ", "# # #", " ### ", "#####", " ### ", "# # #", "     "],
    "+": ["     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "],
    ",": ["     ", "     ", "     ", "     ", "  ## ", "  ## ", "   # "],
    "-": ["     ", "     ", "     ", "#####", "     ", "     ", "     "],
    ".": ["     ", "     ", "     ", "     ", "     ", "  ## ", "  ## "],
    "/": ["    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    "],
    "0": [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "],
    "1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    "2": [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
    "3": ["#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### "],
    "4": ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
    "5": ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
    "6": ["  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "],
    "7": ["#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "],
    "8": [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
    "9": [" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "],
    ":": ["     ", "  ## ", "  ## ", "     ", "  ## ", "  ## ", "     "],
    ";": ["     ", "  ## ", "  ## ", "     ", "  ## ", "  ## ", "   # "],
    "<": ["   # ", "  #  ", " #   ", "#    ", " #   ", "  #  ", "   # "],
    "=": ["     ", "     ", "#####", "     ", "#####", "     ", "     "],
    ">": [" #   ", "  #  ", "   # ", "    #", "   # ", "  #  ", " #   "],
    "?": [" ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  "],
    "@": [" ### ", "#   #", "# ###", "# # #", "# ###", "#    ", " ### "],
    "A": [" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "B": ["#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "],
    "C": [" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "],
    "D": ["###  ", "#  # ", "#   #", "#   #", "#   #", "#  # ", "###  "],
    "E": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
    "F": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "],
    "G": [" ### ", "#   #", "#    ", "#  ##", "#   #", "#   #", " ####"],
    "H": ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "I": [" ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    "J": ["  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  "],
    "K": ["#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"],
    "L": ["#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"],
    "M": ["#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #"],
    "N": ["#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"],
    "O": [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "P": ["#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "],
    "Q": [" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"],
    "R": ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
    "S": [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
    "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    "U": ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "V": ["#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "],
    "W": ["#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #"],
    "X": ["#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"],
    "Y": ["#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
    "Z": ["#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"],
    "[": [" ### ", " #   ", " #   ", " #   ", " #   ", " #   ", " ### "],
    "\\": ["#    ", "#    ", " #   ", "  #  ", "   # ", "    #", "    #"],
    "]": [" ### ", "   # ", "   # ", "   # ", "   # ", "   # ", " ### "],
    "^": ["  #  ", " # # ", "#   #", "     ", "     ", "     ", "     "],
    "_": ["     ", "     ", "     ", "     ", "     ", "     ", "#####"],
    "`": [" #   ", "  #  ", "     ", "     ", "     ", "     ", "     "],
    "{": ["   ##", "  #  ", "  #  ", " #   ", "  #  ", "  #  ", "   ##"],
    "|": ["  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    "}": ["##   ", "  #  ", "  #  ", "   # ", "  #  ", "  #  ", "##   "],
    "~": ["     ", "     ", " #  #", "# ## ", "     ", "     ", "     "],
}
# Lower case reuses the upper-case shapes: a 5x7 matrix has no room for a real
# lower case, and the beds only need legible text, not typography.
for _c in "abcdefghijklmnopqrstuvwxyz":
    GLYPHS[_c] = GLYPHS[_c.upper()]

CHARS = [chr(c) for c in range(32, 127)]


def glyph_contours(ch):
    """The lit cells of `ch` as closed square contours, in font units (y up)."""
    rows = GLYPHS.get(ch, GLYPHS[" "])
    contours = []
    for r, row in enumerate(rows):
        for c, cell in enumerate(row):
            if cell != "#":
                continue
            x0 = (c + 1) * CELL            # +1 for the left side bearing
            y1 = (ROWS - r) * CELL         # row 0 is the top
            y0 = y1 - CELL
            x1 = x0 + CELL
            # Clockwise in a y-up space, so the non-zero winding fills it.
            contours.append([(x0, y0), (x0, y1), (x1, y1), (x1, y0)])
    return contours


def glyf_entry(ch):
    """One simple-glyph record (empty bytes for a blank glyph, as spec allows)."""
    contours = glyph_contours(ch)
    if not contours:
        return b""
    xs = [p[0] for c in contours for p in c]
    ys = [p[1] for c in contours for p in c]
    out = struct.pack(">hhhhh", len(contours), min(xs), min(ys), max(xs), max(ys))
    end = -1
    ends = []
    for c in contours:
        end += len(c)
        ends.append(end)
    out += b"".join(struct.pack(">H", e) for e in ends)
    out += struct.pack(">H", 0)  # no instructions

    pts = [p for c in contours for p in c]
    # All points on-curve (straight edges only), flags un-repeated for simplicity.
    out += bytes([0x01] * len(pts))
    prev = 0
    for axis in (0, 1):
        prev = 0
        coords = b""
        for p in pts:
            d = p[axis] - prev
            prev = p[axis]
            coords += struct.pack(">h", d)
        out += coords
    return out


def table_checksum(data):
    padded = data + b"\0" * ((-len(data)) % 4)
    return sum(struct.unpack(">%dI" % (len(padded) // 4), padded)) & 0xFFFFFFFF


def build_sfnt():
    n_glyphs = len(CHARS) + 1  # glyph 0 is .notdef

    glyf = b""
    loca = [0]
    for ch in [None] + CHARS:
        d = b"" if ch is None else glyf_entry(ch)
        d += b"\0" * ((-len(d)) % 4)
        glyf += d
        loca.append(len(glyf))

    # loca is long format (indexToLocFormat = 1), so no /2 packing worries.
    loca_t = b"".join(struct.pack(">I", o) for o in loca)

    head = struct.pack(
        ">IIIIHHqqhhhhHHhhh",
        0x00010000, 0x00010000, 0, 0x5F0F3CF5,
        0x000B, UNITS_PER_EM,
        0, 0,                       # created / modified: fixed, for determinism
        0, DESCENT, (COLS + 1) * CELL, ASCENT,
        0, 8, 2, 1, 0,
    )
    hhea = struct.pack(
        ">IhhhHhhhhhhhhhhhH",
        0x00010000, ASCENT, DESCENT, 0, ADVANCE,
        0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, n_glyphs,
    )
    hmtx = b"".join(struct.pack(">Hh", ADVANCE, 0) for _ in range(n_glyphs))
    # maxp v1.0: version + 14 uint16 fields (numGlyphs, maxPoints,
    # maxContours, maxCompositePoints, maxCompositeContours, maxZones,
    # maxTwilightPoints, maxStorage, maxFunctionDefs, maxInstructionDefs,
    # maxStackElements, maxSizeOfInstructions, maxComponentElements,
    # maxComponentDepth).
    maxp = struct.pack(">IHHHHHHHHHHHHHH", 0x00010000, n_glyphs,
                       COLS * ROWS * 4, COLS * ROWS, 0, 0, 2, 0,
                       0, 0, 0, 0, 0, 0, 0)

    # cmap format 4, one segment covering 32..126 plus the required 0xFFFF end.
    first, last = 32, 126
    seg_count = 2
    search_range = 2 * (2 ** 0) * seg_count // seg_count * 2  # = 4 for 2 segments
    sub = struct.pack(">HHHHHHH", 4, 16 + 8 * seg_count, 0,
                      seg_count * 2, search_range, 0,
                      seg_count * 2 - search_range)
    sub += struct.pack(">HH", last, 0xFFFF)          # endCode[]
    sub += struct.pack(">H", 0)                      # reservedPad
    sub += struct.pack(">HH", first, 0xFFFF)         # startCode[]
    # idDelta maps `first` to glyph 1: delta = 1 - first (mod 65536).
    sub += struct.pack(">hh", 1 - first, 1)   # idDelta[]: cp 32 -> glyph 1
    sub += struct.pack(">HH", 0, 0)                  # idRangeOffset[]
    cmap = struct.pack(">HHHHI", 0, 1, 3, 1, 12) + sub

    def name_record(nid, text):
        return text.encode("utf-16-be"), nid

    names = [name_record(1, "RPG Maker Clone Sample"),
             name_record(2, "Regular"),
             name_record(4, "RPG Maker Clone Sample Regular"),
             name_record(6, "RPGMakerCloneSample")]
    storage = b""
    records = b""
    for text, nid in names:
        records += struct.pack(">HHHHHH", 3, 1, 0x0409, nid, len(text), len(storage))
        storage += text
    name = struct.pack(">HHH", 0, len(names), 6 + 12 * len(names)) + records + storage

    post = struct.pack(">IIhhIIIII", 0x00030000, 0, 0, 0, 0, 0, 0, 0, 0)
    tables = {
        b"cmap": cmap, b"glyf": glyf, b"head": head,
        b"hhea": hhea, b"hmtx": hmtx, b"loca": loca_t, b"maxp": maxp,
        b"name": name, b"post": post,
    }

    tags = sorted(tables)
    n = len(tags)
    entry_selector = 0
    while (1 << (entry_selector + 1)) <= n:
        entry_selector += 1
    search_range = (1 << entry_selector) * 16
    header = struct.pack(">IHHHH", 0x00010000, n, search_range, entry_selector,
                         n * 16 - search_range)

    offset = 12 + 16 * n
    directory = b""
    body = b""
    for tag in tags:
        data = tables[tag]
        directory += struct.pack(">4sIII", tag, table_checksum(data), offset,
                                 len(data))
        padded = data + b"\0" * ((-len(data)) % 4)
        body += padded
        offset += len(padded)
    return header + directory + body, tables, tags


def build_woff(sfnt, tables, tags):
    """Wrap the same tables in a WOFF 1.0 container (what MZ projects ship)."""
    n = len(tags)
    dir_size = 44 + 20 * n
    entries, body = [], b""
    offset = dir_size
    for tag in tags:
        data = tables[tag]
        comp = zlib.compress(data, 9)
        stored = comp if len(comp) < len(data) else data
        entries.append((tag, offset, len(stored), len(data), table_checksum(data)))
        pad = b"\0" * ((-len(stored)) % 4)
        body += stored + pad
        offset += len(stored) + len(pad)
    header = struct.pack(">4sIIHHIHHIIIII", b"wOFF", 0x00010000,
                         dir_size + len(body), n, 0, len(sfnt), 1, 0,
                         0, 0, 0, 0, 0)
    directory = b"".join(struct.pack(">4sIIII", *e) for e in entries)
    return header + directory + body


def main():
    sfnt, tables, tags = build_sfnt()
    woff = build_woff(sfnt, tables, tags)
    # The MZ bed gets the .woff — that is what MZ projects really ship, and it is
    # what makes CI exercise the WOFF unpacker; the MV bed gets the plain .ttf.
    for bed, blob, name in (("mz-sample", woff, "Sample.woff"),
                            ("mv-sample", sfnt, "Sample.ttf")):
        path = os.path.join(ROOT, bed, "fonts", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(blob)
        print("wrote %s (%d bytes)" % (path, len(blob)))


if __name__ == "__main__":
    main()
