#!/usr/bin/env python3
"""
inject_dylib.py - Ajoute une commande LC_LOAD_WEAK_DYLIB "@rpath/<Nom>.dylib"
dans un binaire Mach-O 64-bit ARM64 (in-place, utilise le padding existant).

Usage:
    python3 inject_dylib.py <binary> <DylibName> [DylibName2 ...]

Exemple:
    python3 inject_dylib.py Payload/Instagram.app/Instagram Peter.dylib

Echoue proprement si le padding est insuffisant.
ATTENTION: toute modification invalide la signature -> re-signer apres.
"""
import struct
import sys

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_SEGMENT_64 = 0x19
MH_MAGIC_64 = 0xFEEDFACF
LOAD_CMD_ALIGN = 8


def build_weak_dylib_cmd(install_name: bytes) -> bytes:
    """Construit une commande dylib_command avec name=install_name (NUL termine)."""
    header_size = 24  # cmd, cmdsize, name.offset, timestamp, current_version, compat_version
    raw = header_size + len(install_name) + 1
    cmdsize = (raw + LOAD_CMD_ALIGN - 1) // LOAD_CMD_ALIGN * LOAD_CMD_ALIGN
    buf = bytearray(cmdsize)
    struct.pack_into("<I", buf, 0, LC_LOAD_WEAK_DYLIB)
    struct.pack_into("<I", buf, 4, cmdsize)
    struct.pack_into("<I", buf, 8, header_size)      # name offset
    struct.pack_into("<I", buf, 12, 0)               # timestamp
    struct.pack_into("<I", buf, 16, 0x00010000)      # current_version 1.0
    struct.pack_into("<I", buf, 20, 0x00010000)      # compatibility 1.0
    buf[header_size:header_size + len(install_name)] = install_name
    return bytes(buf)


def first_section_offset(data: bytes, ncmds: int) -> int:
    """Offset file de la premiere section (pour calculer le padding)."""
    off = 32
    min_off = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sect_start = off + 72
            for s in range(nsects):
                so = struct.unpack_from("<I", data, sect_start + s * 80 + 32)[0]
                if so > 0 and (min_off is None or so < min_off):
                    min_off = so
        off += cmdsize
    if min_off is None:
        raise SystemExit("ERREUR: aucune section trouvee")
    return min_off


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    path = sys.argv[1]
    names = sys.argv[2:]

    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IIIIIIII", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"ERREUR: pas un Mach-O 64-bit LE (magic=0x{magic:08X})")

    cmds = []
    already = set()
    off = 32
    # Idempotence : la base v7 reference deja @rpath/Peter.dylib en LC faible
    # (re-ecrit in-place dans la base vide sideload_clean). Si TOUTES les
    # commandes demandees sont presentes, il n'y a rien a injecter.
    for _c in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            po = struct.unpack_from("<I", data, off + 8)[0]
            end = data.index(b"\0", off + po)
            already.add(data[off + po : end].decode("ascii", "replace"))
        off += cmdsize
    for install in names:
        if not install.startswith("@rpath/") and not install.startswith("@"):
            install = "@rpath/" + install
        if install in already:
            print(f"Deja lie : {install} -> no-op")
            continue
        cmds.append(build_weak_dylib_cmd(install.encode("ascii")))
        print(f"Prepare: {install}")
    if not cmds:
        print("OK: rien a injecter, le binaire reference deja Peter.dylib")
        return
    total_new = sum(len(c) for c in cmds)

    insert_at = 32 + sizeofcmds
    first_sec = first_section_offset(data, ncmds)
    pad = first_sec - insert_at
    print(f"ncmds={ncmds} sizeofcmds={sizeofcmds} insertAt=0x{insert_at:X} "
          f"firstSec=0x{first_sec:X} pad={pad}")
    if pad < total_new:
        raise SystemExit(f"ERREUR: padding insuffisant (besoin {total_new}, dispo {pad})")

    # maj header
    struct.pack_into("<I", data, 16, ncmds + len(cmds))
    struct.pack_into("<I", data, 20, sizeofcmds + total_new)
    # ecrit les nouvelles commandes a insertAt (le padding est deja nul)
    pos = insert_at
    for c in cmds:
        data[pos:pos + len(c)] = c
        pos += len(c)

    with open(path, "wb") as f:
        f.write(data)

    # verification
    with open(path, "rb") as f:
        head = f.read(64)
    n2 = struct.unpack_from("<I", head, 16)[0]
    print(f"OK: {len(cmds)} commande(s) injectee(s), {total_new} octets. "
          f"ncmds {ncmds} -> {n2}, taille identique.")


if __name__ == "__main__":
    main()
