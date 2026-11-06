import hashlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.prepare_base import SLOTS, rewrite_slots, clean_app, build_ipa, verify_output

OLD_SLOTS = [(b"@rpath/RyukGram.dylib", 48),
             (b"@rpath/FLEXing.dylib", 48),
             (b"@rpath/libflex.dylib", 48),
             (b"@rpath/NoPluginsPatch.dylib", 56)]
NEW_SLOTS = [(b"@rpath/Peter.dylib", 48),
             (b"@rpath/NWSupport.dylib", 48),
             (b"@rpath/NWSupport.dylib", 48),
             (b"@rpath/NWSupport.dylib", 56)]


def make_binary(slots):
    cmds = b""
    for name, size in slots:
        buf = bytearray(size)
        struct.pack_into("<II", buf, 0, 0x80000018, size)
        struct.pack_into("<I", buf, 8, 24)
        buf[24:24 + len(name) + 1] = name + b"\0"
        cmds += bytes(buf)
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2,
                         len(slots), len(cmds), 0, 0)
    return header + cmds + b"\0" * 64


class PrepareBaseTest(unittest.TestCase):
    def test_rewrite_slots_in_place(self):
        data = make_binary(OLD_SLOTS)
        old_len = len(data)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "Instagram"
            p.write_bytes(data)
            got = rewrite_slots(p)
            self.assertEqual([g[0] for g in got], [0, 1, 2, 3])
            self.assertEqual([g[2] for g in got],
                             ["@rpath/Peter.dylib", "@rpath/NWSupport.dylib",
                              "@rpath/NWSupport.dylib", "@rpath/NWSupport.dylib"])
            new = p.read_bytes()
            self.assertEqual(len(new), old_len)
            self.assertEqual(struct.unpack_from("<II", new, 16),
                             struct.unpack_from("<II", data, 16))
            self.assertIn(b"@rpath/Peter.dylib\0", new)
            self.assertNotIn(b"RyukGram", new)

    def test_rewrite_rejects_second_pass(self):
        data = make_binary(NEW_SLOTS)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "Instagram"
            p.write_bytes(data)
            with self.assertRaises(ValueError):
                rewrite_slots(p)

    def test_clean_app_removes_artifacts_and_signatures(self):
        with tempfile.TemporaryDirectory() as td:
            src, dst = Path(td) / "src", Path(td) / "dst"
            (src / "Frameworks").mkdir(parents=True)
            for name in ("RyukGram.dylib", "FLEXing.dylib", "libflex.dylib", "NoPluginsPatch.dylib"):
                (src / "Frameworks" / name).write_bytes(b"x")
            (src / "Frameworks/CydiaSubstrate.framework").mkdir()
            (src / "Frameworks/CydiaSubstrate.framework/CydiaSubstrate").write_bytes(b"xxx")
            (src / "Frameworks/CydiaSubstrate.framework/_CodeSignature").mkdir()
            (src / "Frameworks/CydiaSubstrate.framework/_CodeSignature/CodeResources").write_bytes(b"4")
            (src / "RyukGram.bundle").mkdir()
            (src / "RyukGram.bundle/a").write_bytes(b"5")
            (src / "_CodeSignature").mkdir()
            (src / "_CodeSignature/CodeResources").write_bytes(b"6")
            (src / "Info.plist").write_bytes(b"7")
            (src / "cyan.entitlements").write_bytes(b"8")
            (src / "Frameworks/Keep.framework").mkdir()
            (src / "Frameworks/Keep.framework/Keep").write_bytes(b"9")
            (src / "Frameworks/Keep.framework/_CodeSignature").mkdir()
            (src / "Frameworks/Keep.framework/_CodeSignature/CodeResources").write_bytes(b"0")
            n, total = clean_app(src, dst)
            self.assertEqual(n, 3)          # Info.plist + cyan.entitlements + Keep
            self.assertEqual(total, 3)      # b"7" + b"8" + b"9"
            self.assertFalse((dst / "_CodeSignature").exists())
            self.assertFalse((dst / "RyukGram.bundle").exists())
            self.assertFalse((dst / "Frameworks/CydiaSubstrate.framework").exists())
            self.assertFalse((dst / "Frameworks/Keep.framework/_CodeSignature").exists())
            self.assertTrue((dst / "Frameworks/Keep.framework/Keep").exists())
            self.assertTrue((dst / "cyan.entitlements").exists())
            self.assertFalse((dst / "PlugIns").exists())

    def test_build_ipa_is_deterministic_and_verifiable(self):
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / "Instagram.app"
            app.mkdir()
            (app / "Instagram").write_bytes(make_binary(NEW_SLOTS))
            (app / "Info.plist").write_bytes(b"plist")
            out1, out2 = Path(td) / "a.ipa", Path(td) / "b.ipa"
            build_ipa(app, out1)
            build_ipa(app, out2)
            self.assertEqual(out1.read_bytes(), out2.read_bytes())
            verify_output(out1, hashlib.sha256((app / "Instagram").read_bytes()).hexdigest(), 2)

    def test_verify_output_rejects_marker(self):
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / "Instagram.app"
            app.mkdir()
            (app / "Instagram").write_bytes(make_binary(NEW_SLOTS) + b"ryukgram")
            (app / "Info.plist").write_bytes(b"plist")
            out = Path(td) / "bad.ipa"
            build_ipa(app, out)
            with self.assertRaises(AssertionError):
                verify_output(out, None, 2)


if __name__ == "__main__":
    unittest.main()
