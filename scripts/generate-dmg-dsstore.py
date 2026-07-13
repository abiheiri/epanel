#!/usr/bin/env python3
"""Generate the .DS_Store for the epanel DMG.

Writes the Finder metadata that gives the DMG its drag-and-drop layout:
icon view, 500x300 window, epanel.app on the left, Applications on the
right. Generating this file directly (instead of scripting Finder over a
mounted image) works headless and always includes the 'vstl' record that
forces icon view, which modern Finder no longer persists when scripted.

The file uses Apple's "Bud1" buddy-allocator format: a fixed header, a
single B-tree leaf node holding the records, and an allocator directory.
The block layout below mirrors what Finder itself produces for a volume
with this few records.

Usage: generate-dmg-dsstore.py <output-path>
"""
import plistlib
import struct
import sys

APP_NAME = "epanel.app"
WINDOW_BOUNDS = "{{200, 650}, {500, 300}}"  # {{x, y}, {w, h}}; y is from the screen bottom
ICON_POSITIONS = {APP_NAME: (120, 150), "Applications": (380, 150)}
ICON_SIZE = 72.0


def iloc(x, y):
    return struct.pack(">II", x, y) + b"\xff" * 6 + b"\x00\x00"


def build_records():
    bwsp = plistlib.dumps({
        "ContainerShowSidebar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "WindowBounds": WINDOW_BOUNDS,
    }, fmt=plistlib.FMT_BINARY)

    icvp = plistlib.dumps({
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundType": 0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": ICON_SIZE,
        "labelOnBottom": True,
        "showIconPreview": True,
        "showItemInfo": False,
        "textSize": 12.0,
        "viewOptionsVersion": 1,
    }, fmt=plistlib.FMT_BINARY)

    # Records must be sorted by (filename, record type); '.' is the volume
    # root. 'vstl' = icnv is what makes Finder open the window in icon view.
    records = [
        (".", b"bwsp", b"blob", bwsp),
        (".", b"icvp", b"blob", icvp),
        (".", b"vSrn", b"long", 1),
        (".", b"vstl", b"type", b"icnv"),
    ]
    for name in sorted(ICON_POSITIONS, key=str.lower):
        records.append((name, b"Iloc", b"blob", iloc(*ICON_POSITIONS[name])))
    return records


def encode_record(name, rtype, dtype, value):
    out = struct.pack(">I", len(name)) + name.encode("utf-16-be") + rtype + dtype
    if dtype == b"blob":
        out += struct.pack(">I", len(value)) + value
    elif dtype == b"long":
        out += struct.pack(">I", value)
    elif dtype == b"type":
        out += value
    else:
        raise ValueError(f"unsupported data type {dtype}")
    return out


def build_file():
    records = build_records()
    node = struct.pack(">II", 0, len(records))  # leaf node, record count
    node += b"".join(encode_record(*r) for r in records)
    if len(node) > 0x400:
        raise ValueError("records exceed tree node block size")

    # Fixed block layout (offsets are relative to the 4-byte magic prefix):
    #   0x0000 header (0x20) | 0x0040 DSDB master (0x20)
    #   0x0400 tree node (0x400) | 0x1000 allocator directory (0x800)
    buf = bytearray(0x1804)
    struct.pack_into(">I4sIII", buf, 0x00, 1, b"Bud1", 0x1000, 0x800, 0x1000)
    struct.pack_into(">I", buf, 0x14, 0x040A)  # opaque header tail, as Finder writes it

    # DSDB master block: root node block id, tree levels, records, nodes, page size
    struct.pack_into(">IIIII", buf, 0x44, 2, 0, len(records), 1, 0x1000)

    buf[0x404:0x404 + len(node)] = node

    # Allocator directory: block count, then addresses (offset | log2(size))
    off = 0x1004
    struct.pack_into(">IIIII", buf, off, 3, 0, 0x100B, 0x45, 0x040A)
    off += 8 + 256 * 4  # address table is padded to 256 entries

    # Table of contents: the single DSDB tree
    struct.pack_into(">IB4sI", buf, off, 1, 4, b"DSDB", 1)
    off += 13

    # Buddy free lists for the gaps left by the fixed layout above
    free = {5: [0x20, 0x60], 7: [0x80], 8: [0x100], 9: [0x200], 11: [0x800, 0x1800]}
    for i in range(13, 31):
        free[i] = [1 << i]
    for i in range(32):
        entries = free.get(i, [])
        struct.pack_into(">I", buf, off, len(entries))
        off += 4
        for addr in entries:
            struct.pack_into(">I", buf, off, addr)
            off += 4
    if off > len(buf):
        raise ValueError("allocator directory overflowed its block")

    return bytes(buf)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    with open(sys.argv[1], "wb") as f:
        f.write(build_file())


if __name__ == "__main__":
    main()
