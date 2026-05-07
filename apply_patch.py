"""
Steam Link Background Audio Patch
Patches a decrypted Steam Link IPA to keep audio playing in background/lock screen.

Usage:
    python apply_patch.py --input Steamlink.ipa --output Steamlink_patched.ipa [--dylib BackgroundAudio.dylib]
"""
import struct, plistlib, shutil, zipfile, os, argparse, tempfile, re

RET = struct.pack('<I', 0xd65f03c0)


def find_sdl_symbols(sdl):
    """Find target function addresses in SDL3 via symbol table."""
    ncmds = struct.unpack_from('<I', sdl, 16)[0]
    offset = 32
    symtab_off = strtab_off = symtab_nsyms = 0
    data_fileoff = data_filesize = 0

    for _ in range(ncmds):
        cmd = struct.unpack_from('<I', sdl, offset)[0]
        cmdsize = struct.unpack_from('<I', sdl, offset+4)[0]
        if cmd == 0x19:
            segname = sdl[offset+8:offset+24].split(b'\x00')[0]
            if segname == b'__DATA':
                data_fileoff = struct.unpack_from('<Q', sdl, offset+40)[0]
                data_filesize = struct.unpack_from('<Q', sdl, offset+48)[0]
        elif cmd == 0x02:
            symtab_off = struct.unpack_from('<I', sdl, offset+8)[0]
            symtab_nsyms = struct.unpack_from('<I', sdl, offset+12)[0]
            strtab_off = struct.unpack_from('<I', sdl, offset+16)[0]
        offset += cmdsize

    targets = {}
    wanted = [b'_SDL_OnApplicationDidEnterBackground', b'_SDL_OnApplicationWillEnterBackground',
              b'_SDL_PauseAudioDevice', b'_SDL_AudioDevicePaused']
    for i in range(symtab_nsyms):
        entry = symtab_off + i * 16
        n_strx = struct.unpack_from('<I', sdl, entry)[0]
        n_value = struct.unpack_from('<Q', sdl, entry + 8)[0]
        end = sdl.index(b'\x00', strtab_off + n_strx)
        name = bytes(sdl[strtab_off + n_strx:end])
        if name in wanted:
            targets[name.decode()] = n_value

    # Find audioSessionInterruption: IMP via method list
    sel = b'audioSessionInterruption:\x00'
    sel_pos = sdl.find(sel)
    if sel_pos != -1:
        for i in range(data_fileoff, min(len(sdl)-24, data_fileoff + data_filesize), 8):
            if struct.unpack_from('<Q', sdl, i)[0] == sel_pos:
                imp = struct.unpack_from('<Q', sdl, i+16)[0]
                if 0 < imp < data_fileoff:
                    targets['audioSessionInterruption:'] = imp
                    break

    return targets, data_fileoff


def patch_category_refs(sdl):
    """Patch ADRP+ADD instructions that load Ambient/SoloAmbient to load Playback instead."""
    ambient_pos = sdl.find(b'AVAudioSessionCategoryAmbient\x00')
    solo_pos = sdl.find(b'AVAudioSessionCategorySoloAmbient\x00')
    playback_pos = sdl.find(b'AVAudioSessionCategoryPlayback\x00')

    if ambient_pos == -1 or playback_pos == -1:
        print('  WARNING: Category strings not found')
        return 0

    amb_page = ambient_pos & ~0xFFF
    play_page = playback_pos & ~0xFFF
    if amb_page != play_page:
        print('  WARNING: Category strings on different pages, skipping')
        return 0

    target_page = amb_page
    amb_off = ambient_pos & 0xFFF
    solo_off = solo_pos & 0xFFF if solo_pos != -1 else -1
    play_off = playback_pos & 0xFFF

    # Find __TEXT size
    ncmds = struct.unpack_from('<I', sdl, 16)[0]
    offset = 32
    text_size = len(sdl)
    for _ in range(ncmds):
        cmd = struct.unpack_from('<I', sdl, offset)[0]
        cmdsize = struct.unpack_from('<I', sdl, offset+4)[0]
        if cmd == 0x19:
            segname = sdl[offset+8:offset+24].split(b'\x00')[0]
            if segname == b'__TEXT':
                text_size = struct.unpack_from('<Q', sdl, offset+48)[0]
        offset += cmdsize

    count = 0
    for pc in range(0, text_size, 4):
        instr = struct.unpack_from('<I', sdl, pc)[0]
        if (instr & 0xFFC00000) == 0x91000000:
            imm12 = (instr >> 10) & 0xFFF
            if imm12 in (amb_off, solo_off) and pc >= 4:
                prev = struct.unpack_from('<I', sdl, pc-4)[0]
                if (prev & 0x9F000000) == 0x90000000:
                    immhi = (prev >> 5) & 0x7FFFF
                    immlo = (prev >> 29) & 0x3
                    imm = (immhi << 2) | immlo
                    if imm & 0x100000: imm -= 0x200000
                    adrp_page = ((pc-4) & ~0xFFF) + (imm << 12)
                    if adrp_page == target_page:
                        new_add = (instr & 0xFFC003FF) | (play_off << 10)
                        sdl[pc:pc+4] = struct.pack('<I', new_add)
                        count += 1
    return count


def inject_dylib(main, dylib_path="@executable_path/Frameworks/BackgroundAudio.dylib"):
    """Inject LC_LOAD_DYLIB into main binary."""
    ncmds = struct.unpack_from('<I', main, 16)[0]
    sizeofcmds = struct.unpack_from('<I', main, 20)[0]
    lc_end = 32 + sizeofcmds

    dylib_str = dylib_path.encode() + b'\x00'
    str_offset = 24
    cmdsize = (str_offset + len(dylib_str) + 7) & ~7

    lc = struct.pack('<II', 0x0C, cmdsize)
    lc += struct.pack('<I', str_offset)
    lc += struct.pack('<III', 0, 0x00010000, 0x00010000)
    lc += dylib_str
    lc += b'\x00' * (cmdsize - len(lc))

    main[lc_end:lc_end+cmdsize] = lc
    struct.pack_into('<I', main, 16, ncmds + 1)
    struct.pack_into('<I', main, 20, sizeofcmds + cmdsize)
    return ncmds + 1


def main():
    parser = argparse.ArgumentParser(description='Patch Steam Link IPA for background audio')
    parser.add_argument('--input', '-i', required=True, help='Input decrypted IPA')
    parser.add_argument('--output', '-o', required=True, help='Output patched IPA')
    parser.add_argument('--dylib', '-d', default=None, help='Path to BackgroundAudio.dylib')
    args = parser.parse_args()

    # Extract IPA
    tmp = tempfile.mkdtemp()
    print(f'Extracting {args.input}...')
    with zipfile.ZipFile(args.input, 'r') as zf:
        zf.extractall(tmp)

    # Find .app directory
    payload = os.path.join(tmp, 'Payload')
    app_dir = None
    for item in os.listdir(payload):
        if item.endswith('.app'):
            app_dir = os.path.join(payload, item)
            break
    if not app_dir:
        print('ERROR: No .app found in Payload/')
        return

    sdl_path = os.path.join(app_dir, 'Frameworks', 'SDL3.framework', 'SDL3')
    plist_path = os.path.join(app_dir, 'Info.plist')

    # Find main executable
    with open(plist_path, 'rb') as f:
        plist = plistlib.load(f)
    exe_name = plist['CFBundleExecutable']
    main_path = os.path.join(app_dir, exe_name)

    # === Patch SDL3 ===
    print('\n=== Patching SDL3 ===')
    with open(sdl_path, 'rb') as f:
        sdl = bytearray(f.read())

    symbols, _ = find_sdl_symbols(sdl)
    for name, addr in symbols.items():
        sdl[addr:addr+4] = RET
        print(f'  {name} @ {hex(addr)} -> RET')

    cat_count = patch_category_refs(sdl)
    print(f'  Patched {cat_count} category references to Playback')

    with open(sdl_path, 'wb') as f:
        f.write(sdl)

    # === Patch Info.plist ===
    print('\n=== Patching Info.plist ===')
    plist['UIBackgroundModes'] = ['audio']
    plist.pop('UISupportedDevices', None)
    with open(plist_path, 'wb') as f:
        plistlib.dump(plist, f)
    print('  Added UIBackgroundModes: audio')

    # === Inject dylib ===
    if args.dylib and os.path.exists(args.dylib):
        print('\n=== Injecting dylib ===')
        dst = os.path.join(app_dir, 'Frameworks', 'BackgroundAudio.dylib')
        shutil.copy2(args.dylib, dst)

        with open(main_path, 'rb') as f:
            main = bytearray(f.read())
        new_ncmds = inject_dylib(main)
        with open(main_path, 'wb') as f:
            f.write(main)
        print(f'  Injected (ncmds -> {new_ncmds})')

    # === Remove signatures ===
    for d in ['_CodeSignature', 'SC_Info']:
        p = os.path.join(app_dir, d)
        if os.path.exists(p):
            shutil.rmtree(p)

    # === Package IPA ===
    print(f'\n=== Packaging {args.output} ===')
    with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(tmp):
            for f in files:
                full = os.path.join(root, f)
                arcname = os.path.relpath(full, tmp)
                zf.write(full, arcname)

    size_mb = os.path.getsize(args.output) / 1024 / 1024
    print(f'  Done! ({size_mb:.1f} MB)')

    shutil.rmtree(tmp)


if __name__ == '__main__':
    main()
