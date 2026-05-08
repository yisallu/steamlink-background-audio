"""Inspect a Mach-O binary: header info, encryption, load commands, and locate
symbols we need to patch."""

from __future__ import annotations

import sys
from macho import (
    LC_ENCRYPTION_INFO_64,
    LC_LOAD_DYLIB,
    LC_ID_DYLIB,
    LC_CODE_SIGNATURE,
    open_macho,
)


def dump(path):
    data, slices = open_macho(path)
    print(f"=== {path} ({len(data)} bytes) ===")
    for i, sl in enumerate(slices):
        print(f"-- slice {i}: cputype={sl.cputype} subtype={sl.cpusubtype} filetype={sl.filetype}")
        print(f"   ncmds={sl.ncmds} sizeofcmds={sl.sizeofcmds} flags=0x{sl.flags:x}")
        if sl.encryption_info:
            off, size, cid, cmd_off = sl.encryption_info
            print(f"   LC_ENCRYPTION_INFO_64 cryptid={cid} cryptoff=0x{off:x} cryptsize=0x{size:x}")
        for seg in sl.segments:
            print(
                f"   SEG {seg.name:<16s} vm=0x{seg.vmaddr:x}+0x{seg.vmsize:x}  file=0x{seg.fileoff:x}+0x{seg.filesize:x} prot={seg.initprot}"
            )
        for lc in sl.load_commands:
            if lc.cmd == LC_LOAD_DYLIB or lc.cmd == LC_ID_DYLIB:
                import struct
                (cmd, cmdsize, nameoff, ts, cv, compat) = struct.unpack_from("<IIIIII", lc.raw, 0)
                name = lc.raw[nameoff:].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
                tag = "ID_DYLIB" if lc.cmd == LC_ID_DYLIB else "LOAD_DYLIB"
                print(f"   {tag}: {name}")
            elif lc.cmd == LC_CODE_SIGNATURE:
                import struct
                cmd, cmdsize, dataoff, datasize = struct.unpack_from("<IIII", lc.raw, 0)
                print(f"   CODE_SIGNATURE off=0x{dataoff:x} size=0x{datasize:x}")
        targets = [
            "_SDL_OnApplicationDidEnterBackground",
            "_SDL_OnApplicationWillEnterBackground",
            "_SDL_OnApplicationDidEnterForeground",
            "_SDL_OnApplicationWillEnterForeground",
            "_SDL_PauseAudioDevice",
            "_SDL_AudioDevicePaused",
            "_SDL_ResumeAudioDevice",
            "_SDL_SetEventEnabled",
        ]
        for t in targets:
            s = sl.find_symbol(t)
            if s:
                fo = sl.vmaddr_to_fileoff(s.n_value)
                fo_str = f"0x{fo:x}" if fo is not None else "(none)"
                print(f"   SYM {t} -> vm=0x{s.n_value:x} file={fo_str} n_type=0x{s.n_type:x} n_sect={s.n_sect}")
            else:
                print(f"   SYM {t} -> (not found)")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        dump(p)
