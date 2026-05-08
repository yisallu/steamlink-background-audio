"""Minimal Mach-O parser for our patching needs.

Handles both fat (universal) and thin 64-bit Mach-O.  We only implement what we
need: loading slices, enumerating sections, finding string references, mapping
file offsets <-> virtual addresses, listing symbols, and rewriting bytes.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Optional


FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE

LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_ENCRYPTION_INFO_64 = 0x2C
LC_CODE_SIGNATURE = 0x1D
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29


@dataclass
class Section:
    segname: str
    sectname: str
    addr: int
    size: int
    offset: int
    flags: int


@dataclass
class Segment:
    cmd: int
    cmdsize: int
    name: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    maxprot: int
    initprot: int
    nsects: int
    flags: int
    sections: list = field(default_factory=list)


@dataclass
class LoadCommand:
    cmd: int
    cmdsize: int
    offset: int  # offset within the slice
    raw: bytes


@dataclass
class Symbol:
    name: str
    n_type: int
    n_sect: int
    n_desc: int
    n_value: int


class MachOSlice:
    def __init__(self, data: bytearray, base: int, size: int):
        self.data = data
        self.base = base
        self.size = size
        magic = struct.unpack_from("<I", data, base)[0]
        if magic != MH_MAGIC_64:
            raise ValueError("not a little-endian 64-bit Mach-O slice (magic=0x%x)" % magic)
        (
            self.magic,
            self.cputype,
            self.cpusubtype,
            self.filetype,
            self.ncmds,
            self.sizeofcmds,
            self.flags,
            self.reserved,
        ) = struct.unpack_from("<IiiIIIII", data, base)
        self.header_size = 32
        self.load_commands = []
        self.segments = []
        self.encryption_info = None  # (cryptoff, cryptsize, cryptid, cmd_offset)
        self.symtab = None
        self.symbols = []
        self._parse_commands()

    def read(self, offset, size):
        return bytes(self.data[self.base + offset : self.base + offset + size])

    def write(self, offset, blob):
        end = self.base + offset + len(blob)
        self.data[self.base + offset : end] = blob

    def _parse_commands(self):
        off = self.header_size
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.data, self.base + off)
            raw = self.read(off, cmdsize)
            lc = LoadCommand(cmd, cmdsize, off, raw)
            self.load_commands.append(lc)
            if cmd == LC_SEGMENT_64:
                self._parse_segment(lc)
            elif cmd == LC_ENCRYPTION_INFO_64:
                cryptoff, cryptsize, cryptid, pad = struct.unpack_from(
                    "<IIII", self.data, self.base + off + 8
                )
                self.encryption_info = (cryptoff, cryptsize, cryptid, off)
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from(
                    "<IIII", self.data, self.base + off + 8
                )
                self.symtab = dict(
                    symoff=symoff, nsyms=nsyms, stroff=stroff, strsize=strsize
                )
            off += cmdsize
        if self.symtab:
            self._parse_symbols()

    def _parse_segment(self, lc):
        data = self.data
        base = self.base + lc.offset
        cmd, cmdsize = struct.unpack_from("<II", data, base)
        segname = bytes(data[base + 8 : base + 24]).rstrip(b"\x00").decode("ascii")
        (
            vmaddr,
            vmsize,
            fileoff,
            filesize,
            maxprot,
            initprot,
            nsects,
            flags,
        ) = struct.unpack_from("<QQQQiiII", data, base + 24)
        seg = Segment(
            cmd=cmd,
            cmdsize=cmdsize,
            name=segname,
            vmaddr=vmaddr,
            vmsize=vmsize,
            fileoff=fileoff,
            filesize=filesize,
            maxprot=maxprot,
            initprot=initprot,
            nsects=nsects,
            flags=flags,
        )
        section_off = base + 24 + 48  # after segname(16 bytes read above) + 48-byte body fields
        for _ in range(nsects):
            sectname = (
                bytes(data[section_off : section_off + 16])
                .rstrip(b"\x00").decode("ascii")
            )
            sgname = (
                bytes(data[section_off + 16 : section_off + 32])
                .rstrip(b"\x00").decode("ascii")
            )
            (
                addr,
                size,
                offset,
                align,
                reloff,
                nreloc,
                flags,
                r1,
                r2,
                r3,
            ) = struct.unpack_from("<QQIIIIIIII", data, section_off + 32)
            seg.sections.append(Section(sgname, sectname, addr, size, offset, flags))
            section_off += 80
        self.segments.append(seg)

    def _parse_symbols(self):
        sym = self.symtab
        symoff = sym["symoff"]
        nsyms = sym["nsyms"]
        stroff = sym["stroff"]
        strsize = sym["strsize"]
        strings = bytes(
            self.data[self.base + stroff : self.base + stroff + strsize]
        )
        for i in range(nsyms):
            entry_off = self.base + symoff + i * 16
            (strx, ntype, nsect, ndesc, nvalue) = struct.unpack_from(
                "<IBBHQ", self.data, entry_off
            )
            end = strings.find(b"\x00", strx)
            name = strings[strx:end].decode("utf-8", errors="replace")
            self.symbols.append(Symbol(name, ntype, nsect, ndesc, nvalue))

    def vmaddr_to_fileoff(self, vmaddr):
        for seg in self.segments:
            if seg.vmaddr <= vmaddr < seg.vmaddr + seg.vmsize:
                if seg.filesize == 0:
                    return None
                return seg.fileoff + (vmaddr - seg.vmaddr)
        return None

    def fileoff_to_vmaddr(self, fileoff):
        for seg in self.segments:
            if seg.fileoff <= fileoff < seg.fileoff + seg.filesize:
                return seg.vmaddr + (fileoff - seg.fileoff)
        return None

    def find_symbol(self, name):
        for s in self.symbols:
            if s.name == name:
                return s
        return None

    def find_section(self, segname, sectname):
        for seg in self.segments:
            if seg.name != segname:
                continue
            for sect in seg.sections:
                if sect.sectname == sectname:
                    return sect
        return None


def open_macho(path):
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    magic = struct.unpack_from(">I", data, 0)[0]
    slices = []
    if magic in (FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64):
        is_64 = magic in (FAT_MAGIC_64, FAT_CIGAM_64)
        nfat_arch = struct.unpack_from(">I", data, 4)[0]
        entry_size = 32 if is_64 else 20
        for i in range(nfat_arch):
            eo = 8 + i * entry_size
            if is_64:
                cputype, cpusubtype, offset, size, align, reserved = (
                    struct.unpack_from(">iiQQII", data, eo)
                )
            else:
                cputype, cpusubtype, offset, size, align = struct.unpack_from(
                    ">iiIII", data, eo
                )
            slices.append(MachOSlice(data, offset, size))
    else:
        slices.append(MachOSlice(data, 0, len(data)))
    return data, slices


def save(path, data):
    with open(path, "wb") as fh:
        fh.write(bytes(data))
