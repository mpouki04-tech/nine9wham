import io
import sys

src = io.open(r"D:\OPENCODE\IPA INSTA WHAM\nine9wham\tweak\Peter.m",
              encoding="utf-8").read()
required = [
    "static NSString *NWGhostPK(void)",
    "static NSString *NWZXAccount(void)",
    "static BOOL NWGhostFamily(NSString *s)",
    "static BOOL NWDataHasGhostPK(NSData *d, NSString *pk)",
    "static BOOL NWKeychainGhostVerdict",
    "static NSData *NWKeychainItemData",
    "static NSUInteger NWKeychainPurgeGhost(NSString *trigger, BOOL *complete)",
    "static NSUInteger NWPrefsPurgeGhost(NSString *trigger)",
    "NWKeychainPurgeLegacy(NSString *trigger, BOOL *complete)",
]
for needle in required:
    assert needle in src, "MANQUE: " + needle
assert "61516395224" not in src, "pk en clair interdit"
assert "zxPluginsInjectGenericEntry" not in src, "compte zx en clair interdit"
assert '@"zx"' in src and '@"PluginsInjectGenericEntry"' in src
assert 'NWKeychainPurgeLegacy(@"boot")' not in src, "appel 1 argument restant"
assert 'NWKeychainPurgeLegacy(@"reset")' not in src, "appel 1 argument restant"
assert 'NWKeychainPurgeLegacy(@"manual")' not in src, "appel 1 argument restant"
# boot
assert 'NWKeychainPurgeGhost(@"boot", &okG)' in src
assert 'NWKeychainPurgeLegacy(@"boot", &okL)' in src
assert 'NWPrefsPurgeGhost(@"boot")' in src
assert 'if (okL && okG)' in src
assert 'INCOMPLETE' in src
# reset
assert 'NWKeychainPurgeGhost(@"reset"' in src
assert 'NWPrefsPurgeGhost(@"reset")' in src
# manuel + UI
assert 'Purge stale keychain' in src
assert 'Purger le keychain obsolete' in src
assert 'Purgar keychain obsoleto' in src
# forensique
assert 'SESSION FORENSICS %@\\n' in src
assert 'GHOST ITEMS PRESENT' in src
assert 'kcGhost' in src
# flag build-keyed
assert 'isEqualToString:NWBuildID' in src
print("OK: integration w11 presente")
