"""Patch SDL3.framework/SDL3: overwrite the first instruction of a list of
symbols with an ARM64 `RET` (0xD65F03C0), turning the function into a no-op.

Keeps a .bak backup on first run.
"""

from __future__ import annotations

import os
import shutil
import struct
import sys

from macho import open_macho, save


# ARM64 RET = 0xD65F03C0, little-endian bytes
RET = bytes.fromhex("C0035FD6")


SYMBOLS = [
    "_SDL_OnApplicationDidEnterBackground",
    "_SDL_OnApplicationWillEnterBackground",
    "_SDL_PauseAudioDevice",
    "_SDL_AudioDevicePaused",
    # _SDL_ResumeAudioDevice is left alone so the app can still resume on foreground.
    # Foreground enter handlers also untouched - we want normal resume behaviour.
]


def main(path):
    backup = path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"[backup] {backup}")

    data, slices = open_macho(path)
    if len(slices) != 1:
        raise SystemExit("expected thin (single-slice) Mach-O")
    sl = slices[0]

    for name in SYMBOLS:
        sym = sl.find_symbol(name)
        if not sym:
            print(f"[skip ] {name}: symbol not found")
            continue
        fo = sl.vmaddr_to_fileoff(sym.n_value)
        if fo is None:
            print(f"[skip ] {name}: no file mapping for vm=0x{sym.n_value:x}")
            continue
        before = sl.read(fo, 4)
        if before == RET:
            print(f"[done ] {name} @ file=0x{fo:x} already RET")
            continue
        print(f"[patch] {name} @ file=0x{fo:x}: {before.hex()} -> {RET.hex()}")
        sl.write(fo, RET)

    save(path, data)
    print(f"[write] {path}")


if __name__ == "__main__":
    main(sys.argv[1])
