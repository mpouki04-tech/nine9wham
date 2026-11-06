#!/usr/bin/env python3
"""Construit la base Instagram 449 nettoyee pour nine9wham (vague 11).

Source : l'app extraite de l'IPA 449 qui fonctionne. Le script retire les
artefacts RyukGram, reecrit en place les 4 LC_LOAD_WEAK_DYLIB (1 Peter +
3 NWSupport absents) et produit un IPA deterministe verifie.

Usage :
    python scripts/prepare_base.py --app <Instagram.app> --out <base.ipa>
                                   [--work <dir>]
"""

import argparse
import hashlib
import shutil
import struct
import sys
import zipfile
from pathlib import Path

MAGIC = 0xFEEDFACF
WEAK = 0x80000018
DYLIB_COMMANDS = {0xC, 0x80000018, 0x8000001F}
HEADER_SIZE = 24

NEW = {
    b"@rpath/RyukGram.dylib": b"@rpath/Peter.dylib",
    b"@rpath/FLEXing.dylib": b"@rpath/NWSupport.dylib",
    b"@rpath/libflex.dylib": b"@rpath/NWSupport.dylib",
    b"@rpath/NoPluginsPatch.dylib": b"@rpath/NWSupport.dylib",
}
SLOTS = NEW

EXPECTED_SHA = "b3f98e677df1fe3fb0a03dda50171e4bd7ac095fbb555f5dd6de2f6ebcf31b0c"
EXPECTED_FILES = 2079

EXCLUDED_FILES = {
    "Frameworks/RyukGram.dylib",
    "Frameworks/FLEXing.dylib",
    "Frameworks/libflex.dylib",
    "Frameworks/NoPluginsPatch.dylib",
}
EXCLUDED_TREES = {
    "RyukGram.bundle",
    "Frameworks/CydiaSubstrate.framework",
}
CASE_SENSITIVE_MARKERS = (
    b"activeaccount",
    b"ryg_",
    b"_ryg_",
    b"G6Y5X5Q5R7",
    b"61516395224",
    b"inactiveloggedinaccounts",
)


def _is_excluded(rel_posix):
    if rel_posix in EXCLUDED_FILES:
        return True
    for tree in EXCLUDED_TREES:
        if rel_posix == tree or rel_posix.startswith(tree + "/"):
            return True
    return False


def _is_macho(path):
    try:
        with path.open("rb") as fh:
            head = fh.read(4)
    except OSError:
        return False
    if len(head) < 4:
        return False
    return struct.unpack("<I", head)[0] in (0xFEEDFACF, 0xFEEDFACE, 0xCAFEBABE, 0xCAFEBABF)


def _load_commands(data):
    magic, _cputype, _cpusub, _ftype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from(
        "<IIIIIIII", data, 0
    )
    if magic != MAGIC:
        raise ValueError("binaire Mach-O invalide (magic 0x%08X)" % magic)
    off = 32
    out = []
    for index in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8:
            raise ValueError("load command %d de taille invalide" % index)
        out.append((index, cmd, cmdsize, off))
        off += cmdsize
    if off != 32 + sizeofcmds:
        raise ValueError(
            "sizeofcmds incoherent (attendu %d, parcouru %d)"
            % (sizeofcmds, off - 32)
        )
    return out


def rewrite_slots(binary):
    """Reecrit en place les 4 slots RyukGram. Retourne (index, ancien, nouveau)."""
    binary = Path(binary)
    data = bytearray(binary.read_bytes())
    found = {}
    result = []
    for index, cmd, cmdsize, off in _load_commands(data):
        if cmd != WEAK:
            continue
        raw = bytes(data[off + HEADER_SIZE : off + cmdsize]).split(b"\0", 1)[0]
        if raw not in NEW:
            continue
        new = NEW[raw]
        if HEADER_SIZE + len(new) + 1 > cmdsize:
            raise ValueError(
                "slot %s trop petit pour %s (%d > %d)"
                % (raw.decode("ascii", "replace"), new.decode("ascii"), len(new), cmdsize - HEADER_SIZE - 1)
            )
        data[off + HEADER_SIZE : off + cmdsize] = new + b"\0" * (cmdsize - HEADER_SIZE - len(new))
        found[raw] = found.get(raw, 0) + 1
        result.append((index, raw.decode("ascii"), new.decode("ascii")))
    missing = [name.decode("ascii") for name in NEW if found.get(name, 0) != 1]
    if missing:
        raise ValueError("slots RyukGram introuvables ou ambigus : %s" % ", ".join(missing))
    binary.write_bytes(bytes(data))
    return result


def clean_app(src, dst):
    """Copie l'app sans artefacts RyukGram. Retourne (fichiers, octets)."""
    src, dst = Path(src), Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    count = 0
    total = 0
    for path in sorted(src.rglob("*")):
        rel = path.relative_to(src)
        rel_posix = rel.as_posix()
        if any(part == "_CodeSignature" for part in rel.parts):
            continue
        if _is_excluded(rel_posix):
            continue
        if not path.is_file():
            continue
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, out)
        count += 1
        total += path.stat().st_size
    return count, total


def build_ipa(app, out):
    """Zip deterministe Payload/Instagram.app/... avec modes Unix explicites."""
    app, out = Path(app), Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in app.rglob("*") if p.is_file())
    with zipfile.ZipFile(out, "w") as zf:
        for path in files:
            rel = path.relative_to(app).as_posix()
            info = zipfile.ZipInfo("Payload/Instagram.app/" + rel, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if _is_macho(path) else 0o100644) << 16
            with path.open("rb") as src, zf.open(info, "w") as dst:
                shutil.copyfileobj(src, dst)


def verify_output(ipa, expected_sha256=None, expected_files=None):
    ipa = Path(ipa)
    with zipfile.ZipFile(ipa) as zf:
        names = zf.namelist()
        files = [
            n for n in names
            if n.startswith("Payload/Instagram.app/")
            and not n.endswith("/")
            and "__MACOSX" not in n
        ]
        if expected_files is not None:
            assert len(files) == expected_files, "fichiers: %d != %d" % (len(files), expected_files)
        binary_name = "Payload/Instagram.app/Instagram"
        assert binary_name in files, "binaire Instagram absent"
        binary = zf.read(binary_name)
        if expected_sha256 is not None:
            digest = hashlib.sha256(binary).hexdigest()
            assert digest == expected_sha256, "sha256 binaire: %s != %s" % (digest, expected_sha256)

        counts = {}
        for _index, cmd, cmdsize, off in _load_commands(binary):
            if cmd not in DYLIB_COMMANDS:
                continue
            raw = binary[off + HEADER_SIZE : off + cmdsize].split(b"\0", 1)[0]
            name = raw.decode("ascii", "replace")
            counts[name] = counts.get(name, 0) + 1
        assert counts.get("@rpath/Peter.dylib") == 1, "Peter slot: %r" % counts.get("@rpath/Peter.dylib")
        assert counts.get("@rpath/NWSupport.dylib") == 3, "NWSupport slots: %r" % counts.get("@rpath/NWSupport.dylib")
        for old in NEW:
            assert old.decode("ascii") not in counts, "ancien slot present: %s" % old.decode("ascii")

        joined = "\n".join(files)
        for artifact in ("_CodeSignature", "RyukGram.bundle", "Frameworks/RyukGram.dylib",
                         "Frameworks/FLEXing.dylib", "Frameworks/libflex.dylib",
                         "Frameworks/NoPluginsPatch.dylib", "Frameworks/CydiaSubstrate.framework"):
            assert artifact not in joined, "artefact present: %s" % artifact
        assert "Payload/Instagram.app/Frameworks/Peter.dylib" not in files, "Peter.dylib ne doit pas etre dans la base"

        for name in files:
            content = zf.read(name)
            assert b"ryukgram" not in content.lower(), "marqueur RyukGram dans %s" % name
        for marker in CASE_SENSITIVE_MARKERS:
            assert marker not in binary, "marqueur interdit dans le binaire: %r" % marker


def main(argv=None):
    parser = argparse.ArgumentParser(description="Construit la base Instagram 449 nettoyee")
    parser.add_argument("--app", required=True, help="Instagram.app source (IPA 449)")
    parser.add_argument("--out", required=True, help="IPA de sortie")
    parser.add_argument("--work", help="dossier de travail (doit etre vide ou absent)")
    args = parser.parse_args(argv)

    app = Path(args.app)
    out = Path(args.out)
    if not app.is_dir():
        parser.error("app introuvable: %s" % app)

    if args.work:
        work = Path(args.work)
        if work.exists():
            if not work.is_dir() or any(work.iterdir()):
                parser.error("dossier de travail non vide: %s" % work)
        else:
            work.mkdir(parents=True)
    else:
        import tempfile
        work = Path(tempfile.mkdtemp(prefix="prepare_base_"))

    clean_app_path = work / "Payload" / "Instagram.app"
    files, total = clean_app(app, clean_app_path)
    slots = rewrite_slots(clean_app_path / "Instagram")
    build_ipa(clean_app_path, out)
    verify_output(out, EXPECTED_SHA, EXPECTED_FILES)

    digest = hashlib.sha256((clean_app_path / "Instagram").read_bytes()).hexdigest()
    print("base: %d fichiers, %d octets" % (files, total))
    print("binaire: %s" % digest)
    print("slots: %s" % ", ".join("%d -> %s" % (index, new) for index, _old, new in slots))
    print("OK: base 449 prete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
