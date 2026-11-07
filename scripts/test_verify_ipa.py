import hashlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.verify_ipa import verify, EXPECTED_SHA256


def cstr_cmd(cmd, name, header=24):
    raw = name.encode()
    size = (header + len(raw) + 1 + 7) // 8 * 8
    buf = bytearray(size)
    struct.pack_into("<II", buf, 0, cmd, size)
    struct.pack_into("<I", buf, 8, header)
    buf[header:header + len(raw)] = raw
    return bytes(buf)


def macho():
    cmds = [cstr_cmd(0x80000018, "@rpath/Peter.dylib")]
    cmds += [cstr_cmd(0x80000018, "@rpath/NWSupport.dylib")] * 3
    cmds += [cstr_cmd(0x80000018, f"@rpath/L{i}.dylib") for i in range(148)]
    cmds.append(cstr_cmd(0x8000001C, "@executable_path/Frameworks", header=12))
    crypt = bytearray(24)
    struct.pack_into("<IIIIII", crypt, 0, 0x2C, 24, 0, 0, 0, 0)
    cmds.append(bytes(crypt))
    payload = b"".join(cmds)
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2,
                         len(cmds), len(payload), 0, 0)
    return header + payload


class VerifyTest(unittest.TestCase):
    def _ipa(self, td, binary):
        ipa = Path(td) / "test.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/Instagram.app/Instagram", binary)
            z.writestr("Payload/Instagram.app/Frameworks/Peter.dylib",
                       b"\xcf\xfa\xed\xfe" + b"w11 kc-ghost")
        return ipa

    def _ipa_peter(self, td, binary, peter=b"\xcf\xfa\xed\xfe" + b"w11 kc-ghost"):
        ipa = Path(td) / "test.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/Instagram.app/Instagram", binary)
            z.writestr("Payload/Instagram.app/Frameworks/Peter.dylib", peter)
        return ipa

    def test_case_sensitive_marker_rule(self):
        base = macho()
        with tempfile.TemporaryDirectory() as td:
            bad = base + b"activeaccount"
            ipa = self._ipa(td, bad)
            with self.assertRaises(AssertionError):
                verify(ipa, hashlib.sha256(bad).hexdigest(), 2, 152)
            ok = base + b"ActiveAccount"   # casse stock Instagram : autorisee
            ipa = self._ipa(td, ok)
            verify(ipa, hashlib.sha256(ok).hexdigest(), 2, 152)

    def test_rejects_wrong_hash(self):
        with tempfile.TemporaryDirectory() as td:
            base = macho()
            ipa = self._ipa(td, base)
            wrong = hashlib.sha256(b"wrong").hexdigest()
            with self.assertRaises(AssertionError) as ctx:
                verify(ipa, wrong, 2, 152)
            self.assertIn("sha256 binaire", str(ctx.exception))

    def test_rejects_wrong_file_count(self):
        with tempfile.TemporaryDirectory() as td:
            base = macho()
            ipa = self._ipa(td, base)
            # ajouter des fichiers factices pour atteindre 2080 fichiers
            with zipfile.ZipFile(ipa, "a") as z:
                for i in range(2078):
                    z.writestr("Payload/Instagram.app/dummy%d" % i, b"x")
            with self.assertRaises(AssertionError) as ctx:
                verify(ipa, hashlib.sha256(base).hexdigest(), 2079, 152)
            self.assertIn("fichiers: 2080 != 2079", str(ctx.exception))

    def test_rejects_broken_peter(self):
        with tempfile.TemporaryDirectory() as td:
            base = macho()
            ipa = self._ipa_peter(td, base, b"\xcf\xfa\xed\xfe" + b"old build")
            with self.assertRaises(AssertionError) as ctx:
                verify(ipa, hashlib.sha256(base).hexdigest(), 2, 152)
            self.assertIn("Peter.dylib ne contient pas w11", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
