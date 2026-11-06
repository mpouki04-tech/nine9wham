#!/usr/bin/env python3
"""
verify_ipa.py - Verifie qu'une IPA nine9wham est bien formee (vague 11).

Usage:
    python3 verify_ipa.py <fichier.ipa>

Checks:
  - entree Payload/Instagram.app/Instagram presente, magic MH_MAGIC_64
  - binaire non chiffre (LC_ENCRYPTION_INFO_64 cryptid = 0)
  - exactement 152 commandes dylib, dont 1 Peter + 3 NWSupport faibles
  - aucun slot RyukGram/FLEX/libflex/NoPlugins/Substrate
  - LC_RPATH "@executable_path/Frameworks" present
  - 2080 fichiers sous Payload/Instagram.app (hors dossiers, hors __MACOSX)
  - aucun _CodeSignature ni artefact RyukGram dans les noms
  - aucun "ryukgram" (insensible a la casse) dans TOUT l'IPA
  - marqueurs legacy absents du binaire et de Peter.dylib (case-sensitive)
  - Peter.dylib contient "w11" et "kc-ghost"
"""
import hashlib
import re
import struct
import sys
import zipfile

EXPECTED_SHA256 = "b3f98e677df1fe3fb0a03dda50171e4bd7ac095fbb555f5dd6de2f6ebcf31b0c"
EXPECTED_FILES = 2080
EXPECTED_DYLIBS = 152

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_ENCRYPTION_INFO_64 = 0x2C
LC_RPATH = 0x8000001C
MH_MAGIC_64 = 0xFEEDFACF
DYLIB_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB)

RYUK = re.compile(rb"ryukgram", re.IGNORECASE)
CASE_SENSITIVE_MARKERS = (
    b"activeaccount",
    b"ryg_",
    b"_ryg_",
    b"G6Y5X5Q5R7",
    b"61516395224",
    b"inactiveloggedinaccounts",
)
FORBIDDEN_SLOTS = (
    "RyukGram.dylib",
    "FLEXing.dylib",
    "libflex.dylib",
    "NoPluginsPatch.dylib",
    "CydiaSubstrate",
)
FORBIDDEN_NAMES = (
    "_CodeSignature",
    "RyukGram.bundle",
    "RyukGram.dylib",
    "FLEXing.dylib",
    "libflex.dylib",
    "NoPluginsPatch.dylib",
    "CydiaSubstrate",
)


def load_commands(data):
    magic, _cputype, _cpusub, _ftype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from(
        "<IIIIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise AssertionError("magic invalide: 0x%08X" % magic)
    off = 32
    out = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8:
            raise AssertionError("load command de taille invalide: %d" % cmdsize)
        out.append((cmd, cmdsize, off))
        off += cmdsize
    if off != 32 + sizeofcmds:
        raise AssertionError(
            "sizeofcmds incoherent (attendu %d, parcouru %d)" % (sizeofcmds, off - 32)
        )
    return out


def cmd_string(data, off):
    po = struct.unpack_from("<I", data, off + 8)[0]
    end = data.index(b"\0", off + po)
    return data[off + po : end].decode("ascii", "replace")


def verify(path, expected_sha256=EXPECTED_SHA256, expected_files=EXPECTED_FILES,
           expected_dylibs=EXPECTED_DYLIBS):
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        files = [
            n for n in names
            if n.startswith("Payload/Instagram.app/")
            and not n.endswith("/")
            and "__MACOSX" not in n
        ]
        joined = "\n".join(files)
        for forbidden in FORBIDDEN_NAMES:
            assert forbidden.lower() not in joined.lower(), "artefact present: %s" % forbidden
        assert expected_files is None or len(files) == expected_files, \
            "fichiers: %d != %d" % (len(files), expected_files)

        binary_name = "Payload/Instagram.app/Instagram"
        peter_name = "Payload/Instagram.app/Frameworks/Peter.dylib"
        assert binary_name in files, "binaire Instagram absent"
        assert peter_name in files, "Peter.dylib absent de Frameworks/"

        binary = z.read(binary_name)
        digest = hashlib.sha256(binary).hexdigest()
        assert expected_sha256 is None or digest == expected_sha256, \
            "sha256 binaire: %s != %s" % (digest, expected_sha256)

        cmds = load_commands(binary)
        dylibs = [(cmd, cmd_string(binary, off)) for cmd, _size, off in cmds
                  if cmd in DYLIB_COMMANDS]
        assert expected_dylibs is None or len(dylibs) == expected_dylibs, \
            "commandes dylib: %d != %d" % (len(dylibs), expected_dylibs)

        peter = [name for cmd, name in dylibs if name == "@rpath/Peter.dylib"]
        nw = [name for cmd, name in dylibs if name == "@rpath/NWSupport.dylib"]
        assert len(peter) == 1, "slots Peter: %d" % len(peter)
        assert len(nw) == 3, "slots NWSupport: %d" % len(nw)
        assert any(name == "@rpath/Peter.dylib" and cmd == LC_LOAD_WEAK_DYLIB
                   for cmd, name in dylibs), "Peter.dylib doit etre faible"
        assert all(cmd == LC_LOAD_WEAK_DYLIB for cmd, name in dylibs
                   if name == "@rpath/NWSupport.dylib"), "NWSupport doit etre faible"
        for cmd, name in dylibs:
            for forbidden in FORBIDDEN_SLOTS:
                assert forbidden.lower() not in name.lower(), \
                    "slot interdit: %s" % name

        rpaths = [cmd_string(binary, off) for cmd, _size, off in cmds if cmd == LC_RPATH]
        assert "@executable_path/Frameworks" in rpaths, \
            "LC_RPATH @executable_path/Frameworks absent: %s" % rpaths

        cryptids = [struct.unpack_from("<I", binary, off + 16)[0]
                    for cmd, _size, off in cmds if cmd == LC_ENCRYPTION_INFO_64]
        assert cryptids, "LC_ENCRYPTION_INFO_64 absent"
        assert all(cid == 0 for cid in cryptids), "binaire chiffre: cryptid=%s" % cryptids

        peter_data = z.read(peter_name)
        assert struct.unpack_from("<I", peter_data, 0)[0] == MH_MAGIC_64, "Peter.dylib invalide"
        assert b"w11" in peter_data, "Peter.dylib ne contient pas w11"
        assert b"kc-ghost" in peter_data, "Peter.dylib ne contient pas kc-ghost"

        for marker in CASE_SENSITIVE_MARKERS:
            assert marker not in binary, "marqueur interdit dans le binaire: %r" % marker
            assert marker not in peter_data, "marqueur interdit dans Peter.dylib: %r" % marker

        residus = [n for n in files if RYUK.search(z.read(n))]
        assert not residus, "residus RyukGram: %s" % residus

    return {
        "sha256": digest,
        "files": len(files),
        "dylibs": len(dylibs),
        "peter": len(peter),
        "nwsupport": len(nw),
        "rpaths": rpaths,
        "cryptid": cryptids,
        "scanned": len(files),
    }


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print(__doc__)
        return 2
    try:
        counters = verify(args[0])
    except (AssertionError, OSError, ValueError, struct.error, zipfile.BadZipFile) as exc:
        print("ECHEC: %s" % exc)
        return 1
    print("OK: IPA valide")
    print("  hash binaire : %s" % counters["sha256"])
    print("  fichiers     : %d" % counters["files"])
    print("  dylibs       : %d (%d Peter + %d NWSupport)" % (
        counters["dylibs"], counters["peter"], counters["nwsupport"]))
    print("  rpaths       : %s" % counters["rpaths"])
    print("  cryptid      : %s" % counters["cryptid"])
    print("  residus RyukGram : 0 (balayage de %d fichiers)" % counters["scanned"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
