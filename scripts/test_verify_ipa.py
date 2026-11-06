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


if __name__ == "__main__":
    unittest.main()
