#!/usr/bin/env python3
"""
verify_ipa.py - Verifie qu'une IPA nine9wham est bien formee.

Usage:
    python3 verify_ipa.py <fichier.ipa>

Checks:
  - entree Payload/Instagram.app/Instagram presente, magic MH_MAGIC_64
  - presence de la commande LC_LOAD_WEAK_DYLIB "@rpath/Peter.dylib"
  - presence de Frameworks/Peter.dylib
  - LC_RPATH "@executable_path/Frameworks" present
"""
import re
import struct
import sys
import zipfile

# Vague 10-4 : aucun residu du nom d'origine dans TOUTE l'IPA.
RYUK = re.compile(rb"ryukgram", re.IGNORECASE)

LC_LOAD_WEAK_DYLIB = 0x80000018
LC_RPATH = 0x8000001C
MH_MAGIC_64 = 0xFEEDFACF


def load_commands(data):
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, res = struct.unpack_from(
        "<IIIIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise AssertionError("magic invalide: 0x%08X" % magic)
    off = 32
    out = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8:
            break
        out.append((cmd, cmdsize, off))
        off += cmdsize
    return out


def cmd_string(data, off):
    po = struct.unpack_from("<I", data, off + 8)[0]
    end = data.index(b"\0", off + po)
    return data[off + po : end].decode("ascii", "replace")


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    z = zipfile.ZipFile(path)
    names = z.namelist()

    assert any(n.startswith("Payload/Instagram.app/Instagram") for n in names), \
        "binaire Instagram absent"
    assert any(n.endswith("Frameworks/Peter.dylib") for n in names), \
        "Peter.dylib absent de Frameworks/"

    data = z.read("Payload/Instagram.app/Instagram")
    cmds = load_commands(data)

    weak = [cmd_string(data, o) for c, s, o in cmds if c == LC_LOAD_WEAK_DYLIB]
    rpaths = [cmd_string(data, o) for c, s, o in cmds if c == LC_RPATH]

    assert any(p.endswith("Peter.dylib") for p in weak), \
        "LC_LOAD_WEAK_DYLIB @rpath/Peter.dylib absent: %s" % weak
    assert "@executable_path/Frameworks" in rpaths, \
        "LC_RPATH @executable_path/Frameworks absent: %s" % rpaths

    dylib = z.read("Payload/Instagram.app/Frameworks/Peter.dylib")
    assert struct.unpack_from("<I", dylib, 0)[0] == 0xFEEDFACF, "Peter.dylib invalide"

    # Vague 10-4 : balayage de TOUS les fichiers (binaire 394 Mo compris).
    residus = [n for n in names if RYUK.search(z.read(n))]
    assert not residus, "residus RyukGram: %s" % residus

    print("OK: IPA valide")
    print("  entrees      : %d" % len(names))
    print("  weak dylibs  : %d (dont Peter)" % len(weak))
    print("  rpaths       : %s" % rpaths)
    print("  Peter.dylib  : %d octets" % len(dylib))
    print("  residus RyukGram : 0 (balayage de %d fichiers)" % len(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
