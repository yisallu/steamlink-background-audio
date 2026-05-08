"""Append an LC_LOAD_DYLIB load command to a thin 64-bit Mach-O binary.

Usage:
    python inject_dylib.py <binary> <dylib_install_path>

After injection the binary re-signing must happen externally (codesign on
macOS / ldid elsewhere).  We also truncate the attached code signature,
because the existing signature no longer covers the new command; re-signing
will regenerate it.
"""

from __future__ import annotations

import os
import shutil
import struct
import sys

from macho import (
    LC_CODE_SIGNATURE,
    LC_LOAD_DYLIB,
    open_macho,
    save,
)


def pad8(n):
    return (n + 7) & ~7


def build_load_dylib_cmd(install_name: str) -> bytes:
    # struct dylib_command {
    #   uint32_t cmd;                 // LC_LOAD_DYLIB
    #   uint32_t cmdsize;             // total size
    #   struct dylib dylib;
    #     uint32_t name.offset;       // name string offset
    #     uint32_t timestamp;
    #     uint32_t current_version;
    #     uint32_t compatibility_version;
    # } + null-terminated name + zero padding to 8-byte boundary
    name = install_name.encode("utf-8") + b"\x00"
    hdr_size = 24  # 4*4 + 4 + 4 (cmd,cmdsize + 4 uint32 dylib struct)
    raw_size = hdr_size + len(name)
    cmdsize = pad8(raw_size)
    pad = cmdsize - raw_size
    cmd = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,   # cmd
        cmdsize,         # cmdsize
        hdr_size,        # name.offset (24 => right after the struct)
        2,               # timestamp
        0x00010000,      # current_version 1.0.0
        0x00010000,      # compat_version  1.0.0
    )
    return cmd + name + b"\x00" * pad


def inject(path: str, install_name: str) -> None:
    backup = path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"[backup] {backup}")

    data, slices = open_macho(path)
    assert len(slices) == 1
    sl = slices[0]
    base = sl.base

    # Find earliest section file offset to know the ceiling.
    min_section_fileoff = None
    for seg in sl.segments:
        for sect in seg.sections:
            if sect.size and sect.offset:
                if min_section_fileoff is None or sect.offset < min_section_fileoff:
                    min_section_fileoff = sect.offset
    if min_section_fileoff is None:
        raise SystemExit("no sections found")

    new_cmd = build_load_dylib_cmd(install_name)
    cmds_end = base + sl.header_size + sl.sizeofcmds
    needed = len(new_cmd)
    free = min_section_fileoff - (sl.header_size + sl.sizeofcmds)
    print(f"[info ] header+cmds uses {sl.sizeofcmds} bytes, first section @ 0x{min_section_fileoff:x}, free={free}")
    if needed > free:
        raise SystemExit(
            f"not enough room: need {needed} bytes, have {free}"
        )

    # Check for an existing identical LOAD_DYLIB (idempotent).
    for lc in sl.load_commands:
        if lc.cmd == LC_LOAD_DYLIB:
            (_, _, name_off, _, _, _) = struct.unpack_from("<IIIIII", lc.raw, 0)
            existing = lc.raw[name_off:].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            if existing == install_name:
                print(f"[skip ] already loads {install_name}")
                return

    # Write the new command at cmds_end.
    data[cmds_end : cmds_end + len(new_cmd)] = new_cmd

    # Update header ncmds and sizeofcmds.
    struct.pack_into("<I", data, base + 16, sl.ncmds + 1)                # ncmds
    struct.pack_into("<I", data, base + 20, sl.sizeofcmds + len(new_cmd))  # sizeofcmds

    # The existing code signature no longer covers the new command.  Zero the
    # bytes so stale data doesn't fool codesign; signing will overwrite it.
    for lc in sl.load_commands:
        if lc.cmd == LC_CODE_SIGNATURE:
            (_, _, off, size) = struct.unpack_from("<IIII", lc.raw, 0)
            print(f"[info ] existing code sig @0x{off:x}+0x{size:x} will need re-signing")
            break

    save(path, data)
    print(f"[write] {path} (appended LC_LOAD_DYLIB -> {install_name})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: inject_dylib.py <binary> <dylib_install_path>")
        sys.exit(2)
    inject(sys.argv[1], sys.argv[2])
