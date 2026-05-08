#!/usr/bin/env python3
"""Patch a decrypted Steam Link IPA so audio keeps playing in background /
locked screen and AirPods Pro Spatial Audio activates.

One-shot pipeline:

  1. Unzip <input>.ipa to a temp dir
  2. Binary-patch Frameworks/SDL3.framework/SDL3 — overwrite the first
     instruction of SDL_On(Will|Did)EnterBackground, SDL_PauseAudioDevice and
     SDL_AudioDevicePaused with ARM64 RET so SDL can never pause its audio
     pipeline from the iOS lifecycle events.
  3. Inject LC_LOAD_DYLIB("@executable_path/Frameworks/BackgroundAudio.dylib")
     into the main "Steam Link" Mach-O so the dylib loads on launch.
  4. Rewrite Info.plist: add UIBackgroundModes = [audio], delete
     UIRequiredDeviceCapabilities (the arm64 whitelist rejects older
     sideloader profiles).
  5. Copy BackgroundAudio.dylib into Payload/Steam Link.app/Frameworks/.
  6. Zip Payload/ back into <output>.ipa.

The produced IPA is NOT signed.  Sideload it with Sideloadly / AltStore /
Feather / ESign (they'll re-sign for you), or sign manually with codesign
(macOS) / ldid (elsewhere) before installing.

Usage:
    python apply_patch.py \
        --input  steamlink1.3.25.ipa \
        --output steamlink1.3.25-bgaudio.ipa \
        --dylib  dist/BackgroundAudio.dylib
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "tools"))

# Reuse the small helpers we already have.
import inject_dylib  # noqa: E402
import patch_sdl_ret  # noqa: E402

APP_NAME = "Steam Link.app"
MAIN_BINARY = "Steam Link"
DYLIB_INSTALL_NAME = "@executable_path/Frameworks/BackgroundAudio.dylib"


def unzip(ipa: Path, dst: Path) -> None:
    print(f"[unzip] {ipa} -> {dst}")
    with zipfile.ZipFile(ipa, "r") as zf:
        zf.extractall(dst)


def zip_payload(payload_dir: Path, out_ipa: Path) -> None:
    print(f"[zip  ] {payload_dir} -> {out_ipa}")
    if out_ipa.exists():
        out_ipa.unlink()
    with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=5) as zf:
        for root, _, files in os.walk(payload_dir.parent):
            for f in files:
                if f.endswith(".bak"):
                    continue
                full = Path(root) / f
                arc = full.relative_to(payload_dir.parent)
                zf.write(full, arc)


def patch_info_plist(path: Path) -> None:
    print(f"[plist] {path}")
    with open(path, "rb") as fh:
        info = plistlib.load(fh)
    modes = set(info.get("UIBackgroundModes", []))
    modes.add("audio")
    info["UIBackgroundModes"] = sorted(modes)
    if "UIRequiredDeviceCapabilities" in info:
        print("[plist] removing UIRequiredDeviceCapabilities")
        del info["UIRequiredDeviceCapabilities"]
    with open(path, "wb") as fh:
        plistlib.dump(info, fh, fmt=plistlib.FMT_XML)


def patch_ipa(input_ipa: Path, output_ipa: Path, dylib_src: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="bgaudio_", dir=str(HERE)) as td:
        work = Path(td)
        unzip(input_ipa, work)

        app_dir = work / "Payload" / APP_NAME
        if not app_dir.exists():
            # Fallback: find first .app under Payload/
            cands = list((work / "Payload").glob("*.app"))
            if not cands:
                raise SystemExit(f"no .app found under {work / 'Payload'}")
            app_dir = cands[0]
            print(f"[info ] using app bundle: {app_dir.name}")

        frameworks = app_dir / "Frameworks"
        main_bin = app_dir / MAIN_BINARY
        if not main_bin.exists():
            # find single file directly under the bundle
            mains = [p for p in app_dir.iterdir() if p.is_file() and not p.suffix]
            if len(mains) == 1:
                main_bin = mains[0]
                print(f"[info ] main binary: {main_bin.name}")
            else:
                raise SystemExit(f"cannot locate main Mach-O under {app_dir}")

        sdl3 = frameworks / "SDL3.framework" / "SDL3"

        # 1. Patch SDL3
        print("[sdl3 ] patching SDL3.framework/SDL3")
        patch_sdl_ret.main(str(sdl3))

        # 2. Copy the dylib in
        frameworks.mkdir(parents=True, exist_ok=True)
        dst_dylib = frameworks / "BackgroundAudio.dylib"
        shutil.copy2(dylib_src, dst_dylib)
        print(f"[dylib] copied {dylib_src} -> {dst_dylib}")

        # 3. Inject LC_LOAD_DYLIB into main binary
        print(f"[inject] LC_LOAD_DYLIB into {main_bin.name}")
        inject_dylib.inject(str(main_bin), DYLIB_INSTALL_NAME)

        # 4. Info.plist
        info_plist = app_dir / "Info.plist"
        patch_info_plist(info_plist)

        # 5. Re-zip
        payload_dir = work / "Payload"
        zip_payload(payload_dir, output_ipa)

    print(f"\n[done ] {output_ipa}")
    print("       Sign with Sideloadly / AltStore / ldid / codesign before install.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input",  required=True, type=Path, help="original Steam Link IPA (decrypted)")
    ap.add_argument("--output", required=True, type=Path, help="output patched IPA")
    ap.add_argument("--dylib",  required=True, type=Path, help="prebuilt BackgroundAudio.dylib")
    args = ap.parse_args()

    for p, name in [(args.input, "input"), (args.dylib, "dylib")]:
        if not p.exists():
            raise SystemExit(f"{name} not found: {p}")
    args.output = args.output.resolve()
    patch_ipa(args.input.resolve(), args.output, args.dylib.resolve())


if __name__ == "__main__":
    main()
