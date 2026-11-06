//
//  Peter.m — dylib @nine9wham (Instagram modifie)
//  =============================================
//  Entree du tweak : +load au demarrage d'Instagram.
//  Fonctionnalites :
//    1. Menu flottant "@nine9wham" (design inspire de Blaze)
//    2. Conteneurs = telephones virtuels isoles (prefs + cookies + keychain + empreinte)
//    3. Fake GPS par conteneur (choix manuel dans le monde entier)
//    4. Device fingerprint unique par conteneur, coherent avec la puce reelle
//    5. Survie des comptes : vault dans le keychain (re-install Sideloadly)
//
//  Compilation (voir .github/workflows/build.yml) :
//    xcrun -sdk iphoneos clang -arch arm64 -fobjc-arc -dynamiclib \
//      -framework Foundation -framework UIKit -framework CoreLocation \
//      -install_name @rpath/Peter.dylib -o Peter.dylib Peter.m
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <execinfo.h>

#define NWLog(fmt, ...) NSLog(@"[nine9wham] " fmt, ##__VA_ARGS__)

// ---- Cles device identity / safe-mode (vague 7) : #define en TETE du
// fichier car utilisees des la ligne 420 (pin IDFV) et dans l'UI.
#define NWDevKeyDevID    @"nw9.dev.id"
#define NWDevKeyFDID     @"nw9.dev.fdid"
#define NWDevKeyMid      @"nw9.dev.mid"
#define NWDevKeyMidHdr   @"nw9.dev.midhdr"
#define NWDevKeyAttBlock @"nw9.dev.noattest"
#define NWDevKeyHidePill @"nw9.dev.hidepill"   // one-shot (jusqu'au relaunch)
#define NWDevKeyPill     @"nw9.dev.pill"       // bouton flottant (defaut ON)
#define NWDevKeyOn       @"nw9.dev.on"         // masque global
#define NWDevKeyPinOwner @"nw9.dev.pin.owner"  // conteneur proprietaire du pin
#define NWSafeModeKey    @"nw9.safe.mode"      // safe-mode one-shot
// Vague 9 : garde du scan getDeviceId incremental. Le scan note son debut ;
// au lancement suivant, si le rapporteur de crash a ecrit pendant le scan,
// l'etape 9 est neutralisee (et definitivement apres 2 crashs).
#define NWScanStartKey   @"nw9.scan.start"
#define NWScanFailsKey   @"nw9.scan.fails"
#define NWScanOffKey     @"nw9.scan.off"

// ---- v7 : declarations avancees (corps definis dans la section Device
// identity, en aval). Les cles ci-dessus + ces protos rendent l'ordre du
// fil sans surprise (hooks idfv, dashboard, overlay pill, safe-mode).
static BOOL   NWDevBool(NSString *k);
static BOOL   NWDevMaskOn(void);
static BOOL   NWBlockAttest(void);
static BOOL   NWSafeModeOn(void);
static NSString *NWDevGetStr(NSString *k);
static void     NWDevSetStr(NSString *k, NSString *v);
static NSString *NWDevDevIDCurrent(void);
static NSString *NWDevFDIDCurrent(void);
static NSString *NWDevMidCurrent(void);
static NSString *NWDevMidHdrCurrent(void);
static NSString *NWDevPinnedStr(NSString *k);
static BOOL     NWDevPinActive(void);
static NSString *NWDevShort(NSString *s);
static void     NWDevRollIdentity(BOOL makeMask);
static BOOL NWDevPillHiddenNow;          // tentative ; definition + loin
static void NWEnsureDevPill(UIView *root);
static void NWOpenDeviceIdentity(void);
static void NWCloseMenu(void);
static void NWPresentSafeModeUI(void);

#pragma mark - Chemins

static NSString *NWSupportDir(void) {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [lib stringByAppendingPathComponent:@"Application Support/nine9wham"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *NWStatePath(void) {
    return [NWSupportDir() stringByAppendingPathComponent:@"state.plist"];
}

static NSString *NWContainerDir(NSString *cid) {
    NSString *dir = [NWSupportDir() stringByAppendingPathComponent:cid];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - Etat global (lu par les hooks, ecrit par le menu)

// Contenu de state.plist :
// { activeContainer: "c1",
//   containers: { c1: { name, createdAt, fp: {model, idfv, idfa, deviceName, locale, tz, mem, cpu},
//                       loc: {on, lat, lon, label} } },
//   ui: {x, y} }
//
// Par conteneur, un dossier separate contient le snapshot :
//   prefs.plist   -> dictionnaire NSUserDefaults du bundle
//   cookies.plist -> liste de dictionnaires NSHTTPCookie.properties
//   keychain.plist-> liste de dictionnaires (items generic/internet password)

static NSDictionary *NWState = nil;          // snapshot en memoire
static NSString     *NWActiveID = nil;
static NSDictionary *NWActiveFP = nil;       // empreinte du conteneur actif
static NSDictionary *NWActiveLoc = nil;      // localisation fake du conteneur actif

static NSDictionary *NWLoadState(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NWStatePath()];
    return d ?: @{};
}

static void NWSaveState(NSDictionary *st) {
    NWState = st;
    id aid = st[@"activeContainer"];
    NWActiveID = [aid isKindOfClass:[NSString class]] ? aid : nil;   // NSNull -> nil
    NWActiveFP = nil;
    NWActiveLoc = nil;
    NSDictionary *cs = st[@"containers"];
    NSDictionary *c = (NWActiveID && [cs isKindOfClass:[NSDictionary class]] && [cs[NWActiveID] isKindOfClass:[NSDictionary class]])
                      ? cs[NWActiveID] : nil;
    if (c) {
        // Garde-fou anti-crash : une valeur corrompue (liste/chaine a la place
        // d'un dictionnaire) ferait un "unrecognized selector" DANS un hook
        // (NSLocale/NSCalendar) au moment de la creation de compte.
        id fp = c[@"fp"], loc = c[@"loc"];
        NWActiveFP  = [fp isKindOfClass:[NSDictionary class]] ? fp : nil;
        NWActiveLoc = [loc isKindOfClass:[NSDictionary class]] ? loc : nil;
    }
    [st writeToFile:NWStatePath() atomically:YES];
}

static NSDictionary *NWActiveContainer(NSDictionary *st) {
    NSString *aid = st[@"activeContainer"];
    id cs = st[@"containers"];
    if (![aid isKindOfClass:[NSString class]] || ![cs isKindOfClass:[NSDictionary class]]) return nil;
    id c = cs[aid];
    return [c isKindOfClass:[NSDictionary class]] ? c : nil;
}

// Ghost actif ou non (copy Blaze : "Enable · Ghost for %@ container").
// Cle par conteneur "ghostOn" ; absente = actif (retrocompatible).
static BOOL NWGhostEnabled(void) {
    NSDictionary *c = NWActiveContainer(NWState ?: @{});
    if (![c isKindOfClass:[NSDictionary class]]) return YES;   // etat corrompu -> defaut
    id v = c[@"ghostOn"];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return YES;
}

#pragma mark - Empreinte device (fingerprint)

// Vrai modele reelle (utsname.machine ex: "iPhone14,2")
static NSString *NWRealMachine(void) {
    struct utsname u;
    if (uname(&u) != 0) return @"iPhone";
    return [NSString stringWithUTF8String:u.machine];
}

// ---------------------------------------------------------------------------
// Catalogue des modeles proposes (iPhone 13 -> iPhone 17)
// et versions iOS 26.0 -> 27.0.1.
// ---------------------------------------------------------------------------

// Ordre d'affichage : du plus recent au plus ancien.
static NSArray<NSDictionary *> *NWModelList(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @{@"id": @"iPhone18,2", @"name": @"iPhone 17 Pro Max", @"series": @"iPhone 17", @"ram": @12},
            @{@"id": @"iPhone18,1", @"name": @"iPhone 17 Pro",     @"series": @"iPhone 17", @"ram": @12},
            @{@"id": @"iPhone18,3", @"name": @"iPhone 17",         @"series": @"iPhone 17", @"ram": @8},
            @{@"id": @"iPhone18,4", @"name": @"iPhone Air",        @"series": @"iPhone 17", @"ram": @12},
            @{@"id": @"iPhone17,2", @"name": @"iPhone 16 Pro Max", @"series": @"iPhone 16", @"ram": @8},
            @{@"id": @"iPhone17,1", @"name": @"iPhone 16 Pro",     @"series": @"iPhone 16", @"ram": @8},
            @{@"id": @"iPhone17,4", @"name": @"iPhone 16 Plus",    @"series": @"iPhone 16", @"ram": @8},
            @{@"id": @"iPhone17,3", @"name": @"iPhone 16",         @"series": @"iPhone 16", @"ram": @8},
            @{@"id": @"iPhone17,5", @"name": @"iPhone 16e",        @"series": @"iPhone 16", @"ram": @8},
            @{@"id": @"iPhone16,2", @"name": @"iPhone 15 Pro Max", @"series": @"iPhone 15", @"ram": @8},
            @{@"id": @"iPhone16,1", @"name": @"iPhone 15 Pro",     @"series": @"iPhone 15", @"ram": @8},
            @{@"id": @"iPhone15,5", @"name": @"iPhone 15 Plus",    @"series": @"iPhone 15", @"ram": @6},
            @{@"id": @"iPhone15,4", @"name": @"iPhone 15",         @"series": @"iPhone 15", @"ram": @6},
            @{@"id": @"iPhone15,3", @"name": @"iPhone 14 Pro Max", @"series": @"iPhone 14", @"ram": @6},
            @{@"id": @"iPhone15,2", @"name": @"iPhone 14 Pro",     @"series": @"iPhone 14", @"ram": @6},
            @{@"id": @"iPhone14,8", @"name": @"iPhone 14 Plus",    @"series": @"iPhone 14", @"ram": @6},
            @{@"id": @"iPhone14,7", @"name": @"iPhone 14",         @"series": @"iPhone 14", @"ram": @6},
            @{@"id": @"iPhone14,3", @"name": @"iPhone 13 Pro Max", @"series": @"iPhone 13", @"ram": @6},
            @{@"id": @"iPhone14,2", @"name": @"iPhone 13 Pro",     @"series": @"iPhone 13", @"ram": @6},
            @{@"id": @"iPhone14,5", @"name": @"iPhone 13",         @"series": @"iPhone 13", @"ram": @4},
            @{@"id": @"iPhone14,4", @"name": @"iPhone 13 mini",    @"series": @"iPhone 13", @"ram": @4},
            @{@"id": @"iPhone14,6", @"name": @"iPhone SE (3e)",    @"series": @"iPhone SE",  @"ram": @4},
        ];
    });
    return list;
}

static NSDictionary *NWModelInfo(NSString *mid) {
    if (!mid.length) return nil;
    for (NSDictionary *m in NWModelList()) {
        if ([m[@"id"] isEqualToString:mid]) return m;
    }
    return nil;
}

static NSString *NWModelName(NSString *mid) {
    NSDictionary *m = NWModelInfo(mid);
    if (m) return m[@"name"];
    return mid.length ? mid : @"iPhone";
}

// Serie (generation) reelle d'un identifiant machine.
static NSString *NWSeriesForMachine(NSString *machine) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"iPhone14,2": @"iPhone 13", @"iPhone14,3": @"iPhone 13",
            @"iPhone14,4": @"iPhone 13", @"iPhone14,5": @"iPhone 13",
            @"iPhone14,6": @"iPhone SE",
            @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14",
            @"iPhone15,2": @"iPhone 14", @"iPhone15,3": @"iPhone 14",
            @"iPhone15,4": @"iPhone 15", @"iPhone15,5": @"iPhone 15",
            @"iPhone16,1": @"iPhone 15", @"iPhone16,2": @"iPhone 15",
            @"iPhone17,1": @"iPhone 16", @"iPhone17,2": @"iPhone 16",
            @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16",
            @"iPhone17,5": @"iPhone 16",
            @"iPhone18,1": @"iPhone 17", @"iPhone18,2": @"iPhone 17",
            @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone 17",
            @"iPhone18,5": @"iPhone 17",
        };
    });
    return map[machine];
}

// Familles de modeles coherents avec la puce reelle.
// On ne melange pas les generations : un iPhone 13 ne devient jamais un 17.
static NSArray<NSString *> *NWCohortForMachine(NSString *machine) {
    NSString *series = NWSeriesForMachine(machine);
    if (series) {
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSDictionary *m in NWModelList()) {
            if ([m[@"series"] isEqualToString:series]) [ids addObject:m[@"id"]];
        }
        if (ids.count) return ids;
    }
    // iPhone 12 / 11 / SE2 et plus anciens : on garde le modele reel.
    return machine.length ? @[machine] : @[@"iPhone14,5"];
}

// Versions iOS proposees dans Ghost.
static NSArray<NSString *> *NWIOSVersions(void) {
    return @[@"26.0", @"26.0.1", @"26.1", @"26.2", @"26.3", @"26.4", @"27.0", @"27.0.1"];
}

// Memoire (Go) coherente avec un modele.
static NSUInteger NWMemGBForMachine(NSString *m) {
    NSDictionary *info = NWModelInfo(m);
    if (info) return [info[@"ram"] unsignedIntegerValue];
    if ([m hasPrefix:@"iPhone12"]) return 4;      // iPhone 11 / SE2
    if ([m hasPrefix:@"iPhone13"]) return 4;      // iPhone 12
    if ([m hasPrefix:@"iPhone14"]) return 4;      // iPhone 13
    if ([m hasPrefix:@"iPhone15"]) return 6;      // 14 Pro / 15
    if ([m hasPrefix:@"iPhone16"]) return 8;      // 15 Pro
    if ([m hasPrefix:@"iPhone17"]) return 8;      // 16
    if ([m hasPrefix:@"iPhone18"]) return 8;      // 17
    return 6;
}

static NSUInteger NWCpuCountForMachine(NSString *m) {
    // Tous les SoC Apple modernes : 6 coeurs (2P + 4E).
    (void)m;
    return 6;
}

// Modeles iPhone 12 (mini / 12 / 12 Pro / 12 Pro Max) choisis a l'alea.
// Compatible uniquement si le telephone reel est de la meme generation ou superieure.
static NSArray<NSString *> *NWiPhone12Models(void) {
    return @[@"iPhone12,1", @"iPhone12,3", @"iPhone12,5", @"iPhone12,8"];
}

static NSString *NWRandomIPhone12IfCompatible(NSString *realMachine) {
    // Generations : iPhone12 = gen 12, iPhone13 = gen 13, etc.
    NSInteger realGen = 0;
    NSScanner *scan = [NSScanner scannerWithString:realMachine];
    [scan scanString:@"iPhone" intoString:nil];
    [scan scanInteger:&realGen];
    if (realGen >= 12) {
        return NWiPhone12Models()[arc4random_uniform((uint32_t)NWiPhone12Models().count)];
    }
    return nil;
}

// Genere une empreinte aleatoire coherente avec la puce reelle du telephone.
static NSDictionary *NWGenerateFingerprint(void) {
    NSString *real = NWRealMachine();
    NSArray *cohort = NWCohortForMachine(real);
    NSString *fake = cohort[arc4random_uniform((uint32_t)cohort.count)];

    // IDFV / IDFA aleatoires (UUID)
    NSString *idfv = [[NSUUID UUID] UUIDString];
    NSString *idfa = [[NSUUID UUID] UUIDString];

    // Nom de l'appareil aleatoire
    NSArray *names = @[@"Armel's iPhone", @"nine9 iPhone", @"nine9 Phone",
                       @"Mon iPhone", @"iPhone (nine9)"];
    NSString *devName = names[arc4random_uniform((uint32_t)names.count)];

    // Locale + fuseau aleatoires mais coherents entre eux
    NSArray *locales = @[
        @[@"fr_FR", @"Europe/Paris"],
        @[@"en_US", @"America/New_York"],
        @[@"en_GB", @"Europe/London"],
        @[@"es_ES", @"Europe/Madrid"],
        @[@"de_DE", @"Europe/Berlin"],
        @[@"it_IT", @"Europe/Rome"],
        @[@"ar_SA", @"Asia/Riyadh"],
        @[@"pt_BR", @"America/Sao_Paulo"],
        @[@"ja_JP", @"Asia/Tokyo"],
        @[@"nl_NL", @"Europe/Amsterdam"],
    ];
    NSArray *lc = locales[arc4random_uniform((uint32_t)locales.count)];

    // Version iOS aleatoire parmi la liste supportee (pas la version reelle).
    NSString *sysVer = NWIOSVersions()[arc4random_uniform((uint32_t)NWIOSVersions().count)];

    // Identite device du conteneur : device id, family device id, machine id
    // (= mid, la cle preferee d'Instagram) et son header. Une identite par
    // conteneur : Instagram voit un appareil matierielment different.
    return @{
        @"model": fake,
        @"realMachine": real,
        @"idfv": idfv,
        @"idfa": idfa,
        @"deviceName": devName,
        @"locale": lc[0],
        @"tz": lc[1],
        @"memGB": @(NWMemGBForMachine(fake)),
        @"cpu": @(NWCpuCountForMachine(fake)),
        @"sysVer": sysVer,
        @"deviceId": [[NSUUID UUID] UUIDString],
        @"fdid": [[NSUUID UUID] UUIDString],
        @"mid": [[NSUUID UUID] UUIDString],
        @"midHeader": [[NSUUID UUID] UUIDString],
    };
}

// Variante qui CONSERVE la langue et le fuseau du conteneur (vague 9) : on
// renouvelle l'appareil sans perdre le pays choisi. Evite tout conflit entre
// "nouvelle identite" et "pays / langue du conteneur".
static NSDictionary *NWGenerateFingerprintKeepingLocale(NSDictionary *old) {
    NSMutableDictionary *nfp = [NWGenerateFingerprint() mutableCopy];
    if (!nfp) return nil;
    if ([old isKindOfClass:[NSDictionary class]]) {
        id l = old[@"locale"];
        id z = old[@"tz"];
        if ([l isKindOfClass:[NSString class]] && [l length]) nfp[@"locale"] = l;
        if ([z isKindOfClass:[NSString class]] && [z length]) nfp[@"tz"] = z;
    }
    return nfp;
}


#pragma mark - Hooks d'empreinte (ObjC)

static NSString *NWFPStr(NSString *key) {
    if (!NWGhostEnabled()) return nil;   // switch Ghost OFF -> valeurs reelles
    NSString *v = NWActiveFP[key];
    return ([v isKindOfClass:[NSString class]] && v.length) ? v : nil;
}

// UIDevice ----------------------------------------------------------------
static NSString *(*NWOrig_deviceName)(id, SEL);
static NSString *NWHook_deviceName(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"deviceName");
    if (v) return v;
    NSString *o = NWOrig_deviceName ? NWOrig_deviceName(self, _cmd) : nil;
    return o.length ? o : @"iPhone";
}

static NSString *(*NWOrig_model)(id, SEL);
static NSString *NWHook_model(id self, SEL _cmd) {
    // UIDevice.model = "iPhone" (marketing). On renvoie "iPhone" (vrai device = iPhone).
    return NWOrig_model(self, _cmd);
}

// Version iOS (spoofee par conteneur, ex. 26.4 / 27.0.1) ----------------
static NSString *(*NWOrig_systemVersion)(id, SEL);
static NSString *NWHook_systemVersion(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"sysVer");
    if (v.length) return v;
    NSString *o = NWOrig_systemVersion ? NWOrig_systemVersion(self, _cmd) : nil;
    return o.length ? o : @"18.0";
}

static NSOperatingSystemVersion NWParseOSVersion(NSString *v) {
    NSArray *p = [v componentsSeparatedByString:@"."];
    NSOperatingSystemVersion osv;
    osv.majorVersion = p.count > 0 ? [p[0] integerValue] : 0;
    osv.minorVersion = p.count > 1 ? [p[1] integerValue] : 0;
    osv.patchVersion = p.count > 2 ? [p[2] integerValue] : 0;
    return osv;
}

static NSOperatingSystemVersion (*NWOrig_osVersion)(id, SEL);
static NSOperatingSystemVersion NWHook_osVersion(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"sysVer");
    if (v.length) return NWParseOSVersion(v);
    return NWOrig_osVersion ? NWOrig_osVersion(self, _cmd) : NWParseOSVersion(@"18.0");
}

static NSOperatingSystemVersion (*NWOrig_procOSVersion)(id, SEL);
static NSOperatingSystemVersion NWHook_procOSVersion(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"sysVer");
    if (v.length) return NWParseOSVersion(v);
    return NWOrig_procOSVersion ? NWOrig_procOSVersion(self, _cmd) : NWParseOSVersion(@"18.0");
}

static NSString *(*NWOrig_osVersionString)(id, SEL);
static NSString *NWHook_osVersionString(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"sysVer");
    if (v.length) return [NSString stringWithFormat:@"Version %@ (Build 22A3354)", v];
    return NWOrig_osVersionString ? NWOrig_osVersionString(self, _cmd)
                                  : @"Version 18.0 (Build 22A3354)";
}

// Version iOS reelle (avant spoof), pour l'ecran App & Device.
static NSString *NWRealSystemVersion(void) {
    if (NWOrig_systemVersion) {
        return NWOrig_systemVersion([UIDevice currentDevice], @selector(systemVersion));
    }
    return [UIDevice currentDevice].systemVersion;
}

static NSUUID *(*NWOrig_idfv)(id, SEL);
static NSUUID *NWHook_idfv(id self, SEL _cmd) {
    // IDFV = cle d'inscription Instagram : appele pendant la creation de
    // compte -> protege (jamais d'exception non catchee).
    @try {
        // 1) pin device identity global (vague 7), 2) empreinte du conteneur.
        NSString *s = NWDevPinnedStr(NWDevKeyDevID);
        if (!s) s = NWFPStr(@"deviceId");          // device id epingle par conteneur
        if (!s) s = NWFPStr(@"idfv");
        if (s) {
            NSUUID *u = [[NSUUID alloc] initWithUUIDString:s];
            if (u) return u;
        }
    } @catch (NSException *e) {
        NWLog("idfv: %@", e.reason);
    }
    @try {
        return NWOrig_idfv ? NWOrig_idfv(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("idfv(orig): %@", e.reason);
        return nil;
    }
}

// NSProcessInfo -----------------------------------------------------------
static unsigned long long (*NWOrig_physMem)(id, SEL);
static unsigned long long NWHook_physMem(id self, SEL _cmd) {
    if (NWGhostEnabled()) {
        NSNumber *gb = NWActiveFP[@"memGB"];
        if ([gb isKindOfClass:[NSNumber class]] && gb.unsignedLongLongValue > 0) {
            return gb.unsignedLongLongValue * 1024ULL * 1024ULL * 1024ULL;
        }
    }
    return NWOrig_physMem ? NWOrig_physMem(self, _cmd) : (4ULL << 30);
}

static NSUInteger (*NWOrig_cpuCount)(id, SEL);
static NSUInteger NWHook_cpuCount(id self, SEL _cmd) {
    if (NWGhostEnabled()) {
        NSNumber *c = NWActiveFP[@"cpu"];
        if ([c isKindOfClass:[NSNumber class]] && c.unsignedIntegerValue > 0) {
            return c.unsignedIntegerValue;
        }
    }
    return NWOrig_cpuCount ? NWOrig_cpuCount(self, _cmd) : 6;
}

static NSUInteger (*NWOrig_activeCpuCount)(id, SEL);
static NSUInteger NWHook_activeCpuCount(id self, SEL _cmd) {
    if (NWGhostEnabled()) {
        NSNumber *c = NWActiveFP[@"cpu"];
        if ([c isKindOfClass:[NSNumber class]] && c.unsignedIntegerValue > 0) {
            return c.unsignedIntegerValue;
        }
    }
    return NWOrig_activeCpuCount ? NWOrig_activeCpuCount(self, _cmd) : 6;
}

// Helpers de locale definis plus bas (section "Locale telephone").
static NSString *NWEffectiveLocale(void);
static NSArray<NSString *> *NWPreferredLanguageTags(void);
static void NWApplySystemLanguage(void);

// NSLocale ----------------------------------------------------------------
// LA langue/pays que voit Instagram : elle suit la langue choisie dans le
// menu ET le pays choisi (Etats-Unis -> anglais), pas juste le fichier fp.
static id (*NWOrig_currentLocale)(id, SEL);
static id NWHook_currentLocale(id self, SEL _cmd) {
    @try {
        if (NWGhostEnabled()) {
            static NSLocale *cached = nil;
            static NSString *cachedId = nil;
            NSString *eff = NWEffectiveLocale();
            @synchronized ([NSLocale class]) {
                if (!cached || ![cachedId isEqualToString:eff]) {
                    NSLocale *l = nil;
                    @try { l = [[NSLocale alloc] initWithLocaleIdentifier:eff]; }
                    @catch (NSException *e) { l = nil; }
                    if (l) { cached = l; cachedId = eff; }
                }
                if (cached) return cached;
            }
        }
    } @catch (NSException *e) {
        NWLog("currentLocale: %@", e.reason);
    }
    @try {
        return NWOrig_currentLocale ? NWOrig_currentLocale(self, _cmd)
                                    : [NSLocale localeWithLocaleIdentifier:@"en_US"];
    } @catch (NSException *e) {
        NWLog("currentLocale(orig): %@", e.reason);
        return [NSLocale localeWithLocaleIdentifier:@"en_US"];
    }
}

// +[NSLocale preferredLanguages] : Instagram / le clavier lisent cette liste
// pour determiner la langue du "telephone".
static id (*NWOrig_prefLangs)(id, SEL);
static id NWHook_preferredLanguages(id self, SEL _cmd) {
    @try {
        if (NWGhostEnabled()) {
            NSArray *tags = NWPreferredLanguageTags();
            if (tags.count) return tags;
        }
    } @catch (NSException *e) {
        NWLog("preferredLanguages: %@", e.reason);
    }
    @try {
        return NWOrig_prefLangs ? NWOrig_prefLangs(self, _cmd) : @[@"en-US"];
    } @catch (NSException *e) {
        NWLog("preferredLanguages(orig): %@", e.reason);
        return @[@"en-US"];
    }
}

// +[NSLocale autoupdatingCurrentLocale] : deuxieme API utilises par les SDK
// Meta pour connaitre la "langue du telephone". Cote empreinte, ce hook
// ETAIT ABSENT -> Instagram voyait la vraie locale sur ce chemin-la.
static id (*NWOrig_autoLocale)(id, SEL);
static id NWHook_autoLocale(id self, SEL _cmd) {
    @try {
        if (NWGhostEnabled()) {
            static NSLocale *cachedAuto = nil;
            static NSString *cachedAutoId = nil;
            NSString *eff = NWEffectiveLocale();
            @synchronized ([NSLocale class]) {
                if (!cachedAuto || ![cachedAutoId isEqualToString:eff]) {
                    NSLocale *l = nil;
                    @try { l = [[NSLocale alloc] initWithLocaleIdentifier:eff]; }
                    @catch (NSException *e) { l = nil; }
                    if (l) { cachedAuto = l; cachedAutoId = eff; }
                }
                if (cachedAuto) return cachedAuto;
            }
        }
    } @catch (NSException *e) {
        NWLog("autoupdatingCurrentLocale: %@", e.reason);
    }
    @try {
        return NWOrig_autoLocale ? NWOrig_autoLocale(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("autoupdatingCurrentLocale(orig): %@", e.reason);
        return [NSLocale currentLocale];
    }
}

// -[NSBundle preferredLocalizations] (BUNDLE PRINCIPAL UNIQUEMENT) : la
// langue de l'UI d'Instagram passe par ce chemin DANS le SDK Meta. Absent
// des empreintes -> l'app ne "voyait" jamais la langue du conteneur ici.
static id (*NWOrig_prefLocaliz)(id, SEL);
static id NWHook_prefLocaliz(id self, SEL _cmd) {
    @try {
        if (self && [self isKindOfClass:[NSBundle class]]
            && self == [NSBundle mainBundle] && NWGhostEnabled()) {
            NSString *eff = NWEffectiveLocale();
            if (eff.length) {
                NSString *lang = [eff componentsSeparatedByString:@"_"].firstObject;
                if ([lang isKindOfClass:[NSString class]] && lang.length)
                    return @[lang];
            }
        }
    } @catch (NSException *e) {
        NWLog("preferredLocalizations: %@", e.reason);
    }
    @try {
        return NWOrig_prefLocaliz ? NWOrig_prefLocaliz(self, _cmd) : @[@"en"];
    } @catch (NSException *e) {
        NWLog("preferredLocalizations(orig): %@", e.reason);
        return @[@"en"];
    }
}

// NSTimeZone --------------------------------------------------------------
static id (*NWOrig_localTZ)(id, SEL);
static id NWHook_localTZ(id self, SEL _cmd) {
    NSString *tz = NWFPStr(@"tz");
    if (tz) {
        NSTimeZone *z = nil;
        @try { z = [NSTimeZone timeZoneWithName:tz]; }
        @catch (NSException *e) { z = nil; }
        if (z) return z;
    }
    return NWOrig_localTZ ? NWOrig_localTZ(self, _cmd) : [NSTimeZone timeZoneForSecondsFromGMT:0];
}

static id (*NWOrig_sysTZ)(id, SEL);
static id NWHook_sysTZ(id self, SEL _cmd) {
    NSString *tz = NWFPStr(@"tz");
    if (tz) {
        NSTimeZone *z = nil;
        @try { z = [NSTimeZone timeZoneWithName:tz]; }
        @catch (NSException *e) { z = nil; }
        if (z) return z;
    }
    return NWOrig_sysTZ ? NWOrig_sysTZ(self, _cmd) : [NSTimeZone timeZoneForSecondsFromGMT:0];
}

// NSCalendar --------------------------------------------------------------
// Les annees de naissance s'affichent dans une "langue bizarre" (1447 hijri,
// 2568 bouddhiste...) quand la region de la locale n'est pas gregorienne
// (ex. en_SA -> calendrier Umm al-Qura). On force le calendrier GREGORIEN
// partout quand Ghost est actif : annees normales, chiffres normaux.
static BOOL NWCalBuilding = NO;   // garde anti-recursion (locale -> calendar)

static NSCalendar *NWGregorianCalendar(void) {
    if (NWCalBuilding) return nil;
    NSString *eff = NWEffectiveLocale();
    static NSCalendar *cached = nil;
    static NSString *cachedId = nil;
    @synchronized ([NSCalendar class]) {
        if (!cached || ![cachedId isEqualToString:eff]) {
            NWCalBuilding = YES;
            NSCalendar *c = nil;
            @try {
                c = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
                c.locale = [[NSLocale alloc] initWithLocaleIdentifier:eff];
                NSString *tz = NWFPStr(@"tz");
                if ([tz isKindOfClass:[NSString class]] && tz.length) {
                    NSTimeZone *z = [NSTimeZone timeZoneWithName:tz];
                    if (z) c.timeZone = z;
                }
            } @catch (NSException *e) {
                NWLog("calendrier gregorien: %@", e.reason);
                c = nil;
            }
            NWCalBuilding = NO;
            if (c) { cached = c; cachedId = eff; }
        }
        return cached;
    }
}

// Vrai si l'objet est un calendrier gregorien (le seul ou les annees de
// naissance sont normales : 1990 et pas 1447 / 2568).
static BOOL NWIsGregorian(id c) {
    if (![c isKindOfClass:[NSCalendar class]]) return NO;
    NSString *ident = nil;
    @try { ident = [(NSCalendar *)c calendarIdentifier]; }
    @catch (NSException *e) { return NO; }
    return [ident isEqualToString:NSCalendarIdentifierGregorian];
}

static id (*NWOrig_curCal)(id, SEL);
static id NWHook_curCal(id self, SEL _cmd) {
    id v = nil;
    @try {
        v = NWOrig_curCal ? NWOrig_curCal(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("currentCalendar(orig): %@", e.reason);
    }
    @try {
        if (NWGhostEnabled() && !NWIsGregorian(v)) {
            NSCalendar *c = NWGregorianCalendar();
            if (c) return c;
        }
    } @catch (NSException *e) {
        NWLog("currentCalendar: %@", e.reason);
    }
    // Jamais nil : beaucoup de code fait [NSCalendar currentCalendar].x sans test.
    return v ?: [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
}

static id (*NWOrig_autoCal)(id, SEL);
static id NWHook_autoCal(id self, SEL _cmd) {
    id v = nil;
    @try {
        v = NWOrig_autoCal ? NWOrig_autoCal(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("autoupdatingCurrentCalendar(orig): %@", e.reason);
    }
    @try {
        if (NWGhostEnabled() && !NWIsGregorian(v)) {
            NSCalendar *c = NWGregorianCalendar();
            if (c) return c;
        }
    } @catch (NSException *e) {
        NWLog("autoupdatingCurrentCalendar: %@", e.reason);
    }
    return v ?: [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
}

// -[NSLocale objectForKey:NSLocaleCalendar] : c'est ce que lisent NSDateFormatter
// et les pickers de date d'Instagram (annee de naissance).
// On ne touche QUE quand le calendrier reel n'est pas gregorien, et on rend
// une COPIE (jamais l'objet partage) : un appelant qui le modifierait ne
// pourra pas corrompre le cache pour tout le reste de l'app.
static id (*NWOrig_localeCalKey)(id, SEL, id);
static id NWHook_localeCalKey(id self, SEL _cmd, id key) {
    id v = nil;
    @try {
        v = NWOrig_localeCalKey ? NWOrig_localeCalKey(self, _cmd, key) : nil;
    } @catch (NSException *e) {
        NWLog("locale objectForKey: %@", e.reason);
        return nil;
    }
    @try {
        if (v && key && [key isEqual:NSLocaleCalendar] && NWGhostEnabled() && !NWIsGregorian(v)) {
            NSCalendar *c = NWGregorianCalendar();
            if (c) {
                NSCalendar *copy = [c copy];
                if (copy) return copy;
            }
        }
    } @catch (NSException *e) {
        NWLog("locale calendar: %@", e.reason);
    }
    return v;
}

// IDFA (AdSupport charge a la demande) ------------------------------------
static NSUUID *(*NWOrig_idfa)(id, SEL);
static NSUUID *NWHook_idfa(id self, SEL _cmd) {
    // Appelle pendant la creation de compte (tracking d'inscription) :
    // jamais d'exception non catchee depuis ce hook.
    @try {
        NSString *s = NWFPStr(@"idfa");
        if (s) {
            NSUUID *u = [[NSUUID alloc] initWithUUIDString:s];
            if (u) return u;
        }
    } @catch (NSException *e) {
        NWLog("idfa: %@", e.reason);
    }
    @try {
        return NWOrig_idfa ? NWOrig_idfa(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("idfa(orig): %@", e.reason);
        return nil;
    }
}

static void NWSwizzle(Class cls, SEL sel, IMP replacement, void *origStorage) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NWLog("methode absente: -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
    IMP old = method_setImplementation(m, replacement);
    memcpy(origStorage, &old, sizeof(IMP));
}

static void NWInstallFingerprintHooks(void) {
    NWSwizzle([UIDevice class], @selector(name), (IMP)NWHook_deviceName, &NWOrig_deviceName);
    NWSwizzle([UIDevice class], @selector(model), (IMP)NWHook_model, &NWOrig_model);
    NWSwizzle([UIDevice class], @selector(identifierForVendor), (IMP)NWHook_idfv, &NWOrig_idfv);
    NWSwizzle([UIDevice class], @selector(systemVersion), (IMP)NWHook_systemVersion, &NWOrig_systemVersion);
    NWSwizzle([UIDevice class], @selector(operatingSystemVersion), (IMP)NWHook_osVersion, &NWOrig_osVersion);
    NWSwizzle([NSProcessInfo class], @selector(operatingSystemVersion), (IMP)NWHook_procOSVersion, &NWOrig_procOSVersion);
    NWSwizzle([NSProcessInfo class], @selector(operatingSystemVersionString), (IMP)NWHook_osVersionString, &NWOrig_osVersionString);
    NWSwizzle([NSProcessInfo class], @selector(physicalMemory), (IMP)NWHook_physMem, &NWOrig_physMem);
    NWSwizzle([NSProcessInfo class], @selector(processorCount), (IMP)NWHook_cpuCount, &NWOrig_cpuCount);
    NWSwizzle([NSProcessInfo class], @selector(activeProcessorCount), (IMP)NWHook_activeCpuCount, &NWOrig_activeCpuCount);
    NWSwizzle(object_getClass([NSLocale class]), @selector(currentLocale), (IMP)NWHook_currentLocale, &NWOrig_currentLocale);
    NWSwizzle(object_getClass([NSLocale class]), @selector(preferredLanguages), (IMP)NWHook_preferredLanguages, &NWOrig_prefLangs);
    // Deuxieme lecture de la langue du "telephone" par les SDK Meta :
    // autoupdatingCurrentLocale (class) + preferredLocalizations (bundle
    // principal). Ces empreintes ETAIENT absentes -> langue non detectee.
    NWSwizzle(object_getClass([NSLocale class]), @selector(autoupdatingCurrentLocale), (IMP)NWHook_autoLocale, &NWOrig_autoLocale);
    NWSwizzle([NSBundle class], @selector(preferredLocalizations), (IMP)NWHook_prefLocaliz, &NWOrig_prefLocaliz);
    NWSwizzle(object_getClass([NSTimeZone class]), @selector(localTimeZone), (IMP)NWHook_localTZ, &NWOrig_localTZ);
    NWSwizzle(object_getClass([NSTimeZone class]), @selector(systemTimeZone), (IMP)NWHook_sysTZ, &NWOrig_sysTZ);
    // Calendrier GREGORIEN force : les annees de naissance redeviennent normales
    // (1990 et pas 1447 hijri / 2568 bouddhiste) quelle que soit la region.
    NWSwizzle(object_getClass([NSCalendar class]), @selector(currentCalendar), (IMP)NWHook_curCal, &NWOrig_curCal);
    NWSwizzle(object_getClass([NSCalendar class]), @selector(autoupdatingCurrentCalendar), (IMP)NWHook_autoCal, &NWOrig_autoCal);
    NWSwizzle([NSLocale class], @selector(objectForKey:), (IMP)NWHook_localeCalKey, &NWOrig_localeCalKey);

    // Langue du telephone = langue/pays choisis (point 10).
    NWApplySystemLanguage();

    // IDFA : AdSupport peut ne pas etre charge -> on le charge explicitement.
    dlopen("/System/Library/Frameworks/AdSupport.framework/AdSupport", RTLD_LAZY);
    Class asmCls = NSClassFromString(@"ASIdentifierManager");
    if (asmCls) {
        NWSwizzle(asmCls, @selector(advertisingIdentifier), (IMP)NWHook_idfa, &NWOrig_idfa);
    }
    NWLog("hooks empreinte installes (modele=%@)", NWFPStr(@"model") ?: @"(reel)");
}

#pragma mark - Rebinding GOT (uname / sysctl / sysctlbyname)

// Les symboles C sont lies dans __DATA_CONST,__got (non-lazy) du binaire
// principal. On remplace les pointeurs par nos implémentations qui retournent
// le modele fictif du conteneur actif.

static int (*NWOrig_uname)(struct utsname *);
static int NWHook_uname(struct utsname *u) {
    int r = NWOrig_uname ? NWOrig_uname(u) : uname(u);
    if (r == 0 && u) {
        @try {
            NSString *m = NWFPStr(@"model");
            if (m) {
                strncpy(u->machine, m.UTF8String, sizeof(u->machine) - 1);
                u->machine[sizeof(u->machine) - 1] = '\0';
            }
        } @catch (NSException *e) { NWLog("uname: %@", e.reason); }
    }
    return r;
}

static int (*NWOrig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int NWHook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = NWOrig_sysctlbyname ? NWOrig_sysctlbyname(name, oldp, oldlenp, newp, newlen)
                                : sysctlbyname(name, oldp, oldlenp, newp, newlen);
    @try {
        if (r == 0 && oldp && name) {
            NSString *m = NWFPStr(@"model");
            if (m && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)) {
                const char *fm = m.UTF8String;
                size_t need = strlen(fm) + 1;
                if (oldlenp && *oldlenp >= need) {
                    memset(oldp, 0, *oldlenp);
                    memcpy(oldp, fm, need);
                }
            }
        }
    } @catch (NSException *e) { NWLog("sysctlbyname: %@", e.reason); }
    return r;
}

static int (*NWOrig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int NWHook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = NWOrig_sysctl ? NWOrig_sysctl(name, namelen, oldp, oldlenp, newp, newlen)
                          : sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    @try {
        // CTL_HW = 6, HW_MACHINE = 1, HW_MODEL = 6
        if (r == 0 && oldp && name && namelen >= 2 && name[0] == 6 && (name[1] == 1 || name[1] == 6)) {
            NSString *m = NWFPStr(@"model");
            if (m) {
                const char *fm = m.UTF8String;
                size_t need = strlen(fm) + 1;
                if (oldlenp && *oldlenp >= need) {
                    memset(oldp, 0, *oldlenp);
                    memcpy(oldp, fm, need);
                }
            }
        }
    } @catch (NSException *e) { NWLog("sysctl: %@", e.reason); }
    return r;
}

// ---------------------------------------------------------------------------
// Rebinding GOT == fishhook maison, IMAGES DE L'APP UNIQUEMENT.
// MOTATIF (architecture shim evidente chez eux, reecrite ici) : Instagram
// appelle SecItemAdd/CopyMatching/Update/Delete en C DIRECT avec
// kSecAttrAccessGroup force -> nos hooks ObjC (accessGroup) ne couvrent PAS
// ce chemin. Solution : remplacer les pointeurs cibles dans les sections
// __got / __auth_got / __la_symbol_ptr / __nl_symbol_ptr des images de
// l'APP (binaire principal + frameworks du bundle).
//
// INTERDICTION ABSOLUE (vague 7b) : toucher le dyld shared cache.
// Les libs systeme (Foundation/libsystem/Security) sont PRE-LIEES : leur
// __got porte deja l'adresse finale de uname/sysctl/SecItem* -> dlsym
// matche -> rebind garanti. Leurs appels internes passeraient alors par
// NOS hooks, qui rappellent Foundation (NWFPStr/NWGhostEnabled) ->
// recursion infinie -> stack overflow -> crash instantane a l'ouverture.
// (C'est exactement ce qui faisait planter la vague 7 : seul le binaire
//  principal etait rebind en vague 6b, d'ou un demarrage correct.)
// Notre image est exclue (dladdr) : les externes de Peter restent reels
// (sinon nos hooks se rebindent eux-memes -> recursion).
// Les images chargees PLUS TARD sont couvertes par
// _dyld_register_func_for_add_image : dyld declenche le callback deja pour
// chaque image chargee (la passe initiale est couverte), puis a chaque
// ajout -> une seule logique, pas de doublon.
//
// Prototypes des hooks SecItem (corps definis dans la section Sideload
// v2 en aval, apres NWLoadAccessGroupReal) :
static OSStatus NWHook_SecItemAdd(CFDictionaryRef q, CFTypeRef *r);
static OSStatus NWHook_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r);
static OSStatus NWHook_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef attrs, CFTypeRef *r);
static OSStatus NWHook_SecItemDelete(CFDictionaryRef q);
// Pointeurs reels (tentative ici, assignes par le rebinding ; la definition
// suit dans la section Sideload v2) :
static OSStatus (*NWSecReal_Add)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NWSecReal_CopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NWSecReal_Update)(CFDictionaryRef, CFDictionaryRef, CFTypeRef *);
static OSStatus (*NWSecReal_Delete)(CFDictionaryRef);

typedef struct { const char *name; void *want; void *repl; void **orig; } NWRebindTarget;

static NWRebindTarget NWRbTargets[7];
static int NWRbTargetsCount = 0;

static void NWRbFillTargets(void) {
    if (NWRbTargetsCount) return;
    static const char *n7[7] = { "uname", "sysctlbyname", "sysctl",
                                 "SecItemAdd", "SecItemCopyMatching",
                                 "SecItemUpdate", "SecItemDelete" };
    static void *r7[7] = { (void *)NWHook_uname, (void *)NWHook_sysctlbyname, (void *)NWHook_sysctl,
                           (void *)NWHook_SecItemAdd, (void *)NWHook_SecItemCopyMatching,
                           (void *)NWHook_SecItemUpdate, (void *)NWHook_SecItemDelete };
    static void **o7[7] = { (void **)&NWOrig_uname, (void **)&NWOrig_sysctlbyname, (void **)&NWOrig_sysctl,
                            (void **)&NWSecReal_Add, (void **)&NWSecReal_CopyMatching,
                            (void **)&NWSecReal_Update, (void **)&NWSecReal_Delete };
    for (int i = 0; i < 7; i++) {
        NWRbTargets[i].name = n7[i];
        NWRbTargets[i].want = dlsym(RTLD_DEFAULT, n7[i]);
        NWRbTargets[i].repl = r7[i];
        NWRbTargets[i].orig = o7[i];
        if (!NWRbTargets[i].want) NWLog("rebind: symbole absent = %s", n7[i]);
    }
    NWRbTargetsCount = 7;
}

// Hook d'ajout d'image donne par dyld. Recurrence = idempotent : un slot
// deja rebindé (valeur == notre repl) est sauté.
static void NWRbImage(const struct mach_header *mh, intptr_t slide) {
    if (!mh || mh->magic != MH_MAGIC_64) return;
    Dl_info di;
    void *selfBase = NULL;
    if (dladdr((void *)&NWRbImage, &di)) selfBase = di.dli_fbase;
    if ((const void *)mh == selfBase) return;   // notre image : JAMAIS rebind

    // FILTRE Système (vague 7b) : on ne rebind QUE les images de l'app.
    // Image 0 (le binaire principal) = cible primaire depuis la vague 6b :
    // passage GARANTI, meme si dladdr reussit mal. Pour les autres images,
    // dladdr sur l'entete donne son chemin ; tout ce qui vit dans /System
    // ou /usr/lib (dyld shared cache) est SAUTE avant la moindre lecture
    // ou ecriture de GOT.
    if ((const void *)mh != _dyld_get_image_header(0)) {
        Dl_info dim;
        const char *ipath = NULL;
        if (dladdr((const void *)mh, &dim) && dim.dli_fname) ipath = dim.dli_fname;
        if (!ipath) return;   // chemin indetermine -> on ne touche rien
        if (strncmp(ipath, "/System/", 8) == 0 ||
            strncmp(ipath, "/usr/lib", 8) == 0 ||
            strncmp(ipath, "/usr/lib64", 10) == 0 ||
            strstr(ipath, "dyld_shared_cache") != NULL) {
            return;   // lib systeme : rebind = recursion infinie -> crash
        }
    }
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    int patched = 0;
    const uint8_t *cmd = (const uint8_t *)(mh64 + 1);
    for (uint32_t i = 0; i < mh64->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            const struct section_64 *sec = (const struct section_64 *)(sg + 1);
            for (uint32_t s = 0; s < sg->nsects; s++) {
                if (strncmp(sec[s].sectname, "__got", 5) != 0 &&
                    strncmp(sec[s].sectname, "__auth_got", 10) != 0 &&
                    strncmp(sec[s].sectname, "__la_symbol_ptr", 15) != 0 &&
                    strncmp(sec[s].sectname, "__nl_symbol_ptr", 15) != 0) continue;
                void **slots = (void **)(slide + sec[s].addr);
                uint64_t n = sec[s].size / sizeof(void *);
                if (!slots || !n) continue;
                for (uint64_t j = 0; j < n; j++) {
                    if (!slots[j]) continue;
                    for (int t = 0; t < NWRbTargetsCount; t++) {
                        if (!NWRbTargets[t].want) continue;
                        if (slots[j] != NWRbTargets[t].want) continue;
                        // __DATA_CONST est passee en lecture seule apres
                        // binding. Pages iOS = 16 Ko -> alignement 0x4000.
                        // Si vm_protect refuse : on SAUTE (ecrire dans une
                        // page protegee = SIGSEGV au lancement = crash).
                        vm_address_t page = (vm_address_t)((uintptr_t)&slots[j] & ~(uintptr_t)0x3FFF);
                        kern_return_t kr = vm_protect(mach_task_self(), page, (vm_size_t)0x4000, 0,
                                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                        if (kr != KERN_SUCCESS) {
                            NWLog("rebind: vm_protect refuse (%d) pour %s", kr, NWRbTargets[t].name);
                            continue;
                        }
                        *(NWRbTargets[t].orig) = NWRbTargets[t].want;
                        slots[j] = NWRbTargets[t].repl;
                        patched++;
                        NWLog("rebind %s", NWRbTargets[t].name);
                    }
                }
            }
        }
        cmd += lc->cmdsize;
    }
    (void)patched;
}

// Point d'entree historique (cree au demarrage).
static void NWRebindGOT(void) {
    NWRbFillTargets();
    static BOOL armed = NO;
    if (armed) return;
    armed = YES;
    _dyld_register_func_for_add_image(NWRbImage);
    NWLog("rebind app : 7 cibles SecItem*/sysctl/uname, images de l'app uniquement (shared cache exclu)");
}

#pragma mark - Fake GPS (localisation par conteneur)

// Construit un CLLocation a partir des coordonnees du conteneur actif.
// Retourne nil si le fake GPS est desactive pour ce conteneur.
static CLLocation *NWFakeLocation(void) {
    NSDictionary *loc = NWActiveLoc;
    if (![loc isKindOfClass:[NSDictionary class]] || ![loc[@"on"] boolValue]) return nil;
    NSNumber *lat = loc[@"lat"], *lon = loc[@"lon"];
    if (![lat isKindOfClass:[NSNumber class]] || ![lon isKindOfClass:[NSNumber class]]) return nil;
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat.doubleValue, lon.doubleValue);
    if (!CLLocationCoordinate2DIsValid(c)) return nil;
    // Altitude / precision plausibles (5 m horizontal = GPS bon).
    return [[CLLocation alloc] initWithCoordinate:c
                                         altitude:35.0
                               horizontalAccuracy:5.0
                                 verticalAccuracy:5.0
                                        timestamp:[NSDate date]];
}

// Livre la position fake au delegate courant du manager.
static void NWDeliverFake(CLLocationManager *mgr) {
    CLLocation *fake = NWFakeLocation();
    if (!fake) return;
    id delegate = mgr.delegate;
    if (!delegate) return;
    SEL sel = @selector(locationManager:didUpdateLocations:);
    if ([delegate respondsToSelector:sel]) {
        // Signature : void locationManager:(CLLocationManager*) didUpdateLocations:(NSArray*)
        typedef void (*Fn)(id, SEL, CLLocationManager *, NSArray *);
        // Jamais d'exception fatale : ce code tourne sur un timer toutes les
        // 2 s, une exception lancee par le delegate d'Instagram tuerait l'app
        // (creation de compte = delegate actif a ce moment-la).
        @try {
            ((Fn)objc_msgSend)(delegate, sel, mgr, @[fake]);
        } @catch (NSException *e) {
            NWLog("deliverFake: %@", e.reason);
        }
    }
}

// CLLocationManager -------------------------------------------------------
static CLLocation *(*NWOrig_location)(id, SEL);
static CLLocation *NWHook_location(id self, SEL _cmd) {
    CLLocation *fake = NWFakeLocation();
    return fake ?: NWOrig_location(self, _cmd);
}

// Dernier manager utilise (pour re-injecter la position periodiquement).
static __weak CLLocationManager *NWLastMgr = nil;

static void (*NWOrig_startUpdating)(id, SEL);
static void NWHook_startUpdating(id self, SEL _cmd) {
    CLLocationManager *mgr = (CLLocationManager *)self;
    if (NWFakeLocation()) {
        // PAS de vrai GPS : sinon les updates reelles ecrasent la position fake.
        NWLastMgr = mgr;
        dispatch_async(dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
        return;
    }
    NWLastMgr = mgr;
    NWOrig_startUpdating(self, _cmd);
}

static void (*NWOrig_requestLocation)(id, SEL);
static void NWHook_requestLocation(id self, SEL _cmd) {
    CLLocationManager *mgr = (CLLocationManager *)self;
    if (NWFakeLocation()) {
        NWLastMgr = mgr;
        dispatch_async(dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
        return;
    }
    NWLastMgr = mgr;
    NWOrig_requestLocation(self, _cmd);
}

static void (*NWOrig_startSignificant)(id, SEL);
static void NWHook_startSignificant(id self, SEL _cmd) {
    CLLocationManager *mgr = (CLLocationManager *)self;
    if (NWFakeLocation()) {
        NWLastMgr = mgr;
        dispatch_async(dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
        return;
    }
    NWLastMgr = mgr;
    NWOrig_startSignificant(self, _cmd);
}

// Les erreurs "localisation indisponible" sont ignorees quand le fake est actif :
// on empeche Instagram de croire que le GPS est en panne.
// Le delegate est connu seulement a setDelegate: -> on swizzle sa classe la.
static NSMutableDictionary *NWFailMap(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

// Retourne l'IMP d'origine pour (classe, selecteur).
// 1) entree stockee au hook pour cette classe ; 2) sinon entree de la classe
// parente (cas d'une sous-classe qui herite d'une methode deja hookee :
// sans ca, les updates reelles seraient avalees) ; 3) sinon implementation
// non hookee trouvee dans la hierarchie.
static IMP NWOriginalIMP(Class cls, SEL sel, IMP mine, NSString *suffix) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        id v = [NWFailMap() objectForKey:[NSStringFromClass(c) stringByAppendingString:suffix]];
        if ([v isKindOfClass:[NSValue class]]) {
            IMP o = [v pointerValue];
            if (o && o != mine) return o;
        }
    }
    for (Class c = class_getSuperclass(cls); c; c = class_getSuperclass(c)) {
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        IMP imp = class_getMethodImplementation(c, sel);
        if (imp && imp != mine) return imp;
    }
    return NULL;
}

static void NWHook_fail(id self, SEL _cmd, id mgr, id error) {
    if (NWFakeLocation()) return;   // pas d'erreur quand le fake est actif
    Class cls = object_getClass(self);
    IMP orig = NWOriginalIMP(cls, @selector(locationManager:didFailWithError:),
                             (IMP)NWHook_fail, @"|fail");
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, mgr, error);
}

// Les updates REelles arrivent ici : on remplace toutes les positions par la
// position fake, sinon Instagram recoit la vraie position en parallele.
static void NWHook_locations(id self, SEL _cmd, id mgr, NSArray *locs) {
    CLLocation *fake = NWFakeLocation();
    NSArray *out = locs;
    if (fake) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:locs.count];
        for (NSUInteger i = 0; i < locs.count; i++) [a addObject:fake];
        out = a;
    }
    Class cls = object_getClass(self);
    IMP orig = NWOriginalIMP(cls, @selector(locationManager:didUpdateLocations:),
                             (IMP)NWHook_locations, @"|loc");
    if (orig) ((void (*)(id, SEL, id, NSArray *))orig)(self, _cmd, mgr, out);
}

// Signature legacy : (CLLocation *newLoc, CLLocation *oldLoc) — pas un tableau.
static void NWHook_locationsLegacy(id self, SEL _cmd, id mgr, CLLocation *newLoc, CLLocation *oldLoc) {
    CLLocation *fake = NWFakeLocation();
    CLLocation *out = fake ?: newLoc;
    Class cls = object_getClass(self);
    IMP orig = NWOriginalIMP(cls, @selector(locationManager:didUpdateToLocation:fromLocation:),
                             (IMP)NWHook_locationsLegacy, @"|leg");
    if (orig) ((void (*)(id, SEL, id, CLLocation *, CLLocation *))orig)(self, _cmd, mgr, out, oldLoc);
}

static void NWHookDelegateClass(Class cls) {
    if (!cls || cls == [NSObject class]) return;
    NSString *key = NSStringFromClass(cls);
    @synchronized (NWFailMap()) {
        // --- locationManager:didFailWithError: ---
        if (![NWFailMap() objectForKey:[key stringByAppendingString:@"|fail"]]) {
            SEL sel = @selector(locationManager:didFailWithError:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                IMP cur = class_getMethodImplementation(cls, sel);
                if (cur != (IMP)NWHook_fail) {
                    const char *types = method_getTypeEncoding(m);
                    IMP old = class_replaceMethod(cls, sel, (IMP)NWHook_fail, types);
                    if (!old) old = cur;
                    [NWFailMap() setObject:[NSValue valueWithPointer:old] forKey:[key stringByAppendingString:@"|fail"]];
                } else {
                    [NWFailMap() setObject:[NSNull null] forKey:[key stringByAppendingString:@"|fail"]];
                }
            }
        }
        // --- locationManager:didUpdateLocations: ---
        if (![NWFailMap() objectForKey:[key stringByAppendingString:@"|loc"]]) {
            SEL sel = @selector(locationManager:didUpdateLocations:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                IMP cur = class_getMethodImplementation(cls, sel);
                if (cur != (IMP)NWHook_locations) {
                    const char *types = method_getTypeEncoding(m);
                    IMP old = class_replaceMethod(cls, sel, (IMP)NWHook_locations, types);
                    if (!old) old = cur;
                    [NWFailMap() setObject:[NSValue valueWithPointer:old] forKey:[key stringByAppendingString:@"|loc"]];
                } else {
                    [NWFailMap() setObject:[NSNull null] forKey:[key stringByAppendingString:@"|loc"]];
                }
            }
        }
        // --- locationManager:didUpdateToLocation:fromLocation: (legacy) ---
        if (![NWFailMap() objectForKey:[key stringByAppendingString:@"|leg"]]) {
            SEL sel = @selector(locationManager:didUpdateToLocation:fromLocation:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                IMP cur = class_getMethodImplementation(cls, sel);
                if (cur != (IMP)NWHook_locationsLegacy) {
                    const char *types = method_getTypeEncoding(m);
                    IMP old = class_replaceMethod(cls, sel, (IMP)NWHook_locationsLegacy, types);
                    if (!old) old = cur;
                    [NWFailMap() setObject:[NSValue valueWithPointer:old] forKey:[key stringByAppendingString:@"|leg"]];
                } else {
                    [NWFailMap() setObject:[NSNull null] forKey:[key stringByAppendingString:@"|leg"]];
                }
            }
        }
        NWLog("delegate hook: %@", key);
    }
}

static void (*NWOrig_setDelegate)(id, SEL, id);
static void NWHook_setDelegate(id self, SEL _cmd, id delegate) {
    NWOrig_setDelegate(self, _cmd, delegate);
    // Jamais d'exception dans ce hook : il est appele par Instagram pendant
    // l'ouverture de session / la creation de compte.
    @try {
        if (delegate && ![(id)delegate isKindOfClass:[NSNull class]]) {
            Class cls = object_getClass(delegate);
            if (cls && cls != [NSObject class] && class_isMetaClass(cls) == NO) {
                NWHookDelegateClass(cls);
            }
        }
    } @catch (NSException *e) {
        NWLog("setDelegate hook: %@", e.reason);
    }
}

static void NWInstallLocationHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class mgrCls = [CLLocationManager class];
        NWSwizzle(mgrCls, @selector(location), (IMP)NWHook_location, &NWOrig_location);
        NWSwizzle(mgrCls, @selector(startUpdatingLocation), (IMP)NWHook_startUpdating, &NWOrig_startUpdating);
        NWSwizzle(mgrCls, @selector(requestLocation), (IMP)NWHook_requestLocation, &NWOrig_requestLocation);
        NWSwizzle(mgrCls, @selector(startMonitoringSignificantLocationChanges), (IMP)NWHook_startSignificant, &NWOrig_startSignificant);
        // Le delegate n'est connu qu'a setDelegate: -> on swizzle sa classe a ce moment-la
        // (plutot que NSObject qui n'implante pas la methode).
        NWSwizzle(mgrCls, @selector(setDelegate:), (IMP)NWHook_setDelegate, &NWOrig_setDelegate);

        // Re-injection periodique : certaines apps n'attendent jamais le
        // delegate et relancent un fetch. On re-livre la position fake
        // toutes les 2 s tant qu'elle est active.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
                if (!NWFakeLocation()) return;
                CLLocationManager *m = NWLastMgr;
                if (m) NWDeliverFake(m);
            }];
        });
    });
    NWLog("hooks fake GPS installes (on=%d)", NWActiveLoc[@"on"] ? 1 : 0);
}

#pragma mark - Vault keychain (survie re-install / mise a jour)

// Les items keychain d'une app free-signee survivent a la re-install tant que
// le meme Apple ID (meme team) est utilise. On y depose l'etat complet des
// conteneurs : meme si Application Support est perdu, tout revient.

static NSString *NWVaultService(void) { return @"com.nine9wham.vault"; }

static void NWVaultWrite(NSData *data) {
    if (!data) return;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NWVaultService(),
        (__bridge id)kSecAttrAccount: @"state",
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    NSMutableDictionary *add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = data;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    NWLog("vault ecrit (status=%d, %lu octets)", (int)st, (unsigned long)data.length);
}

static NSData *NWVaultRead(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NWVaultService(),
        (__bridge id)kSecAttrAccount: @"state",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef res = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &res);
    if (st != errSecSuccess || !res) return nil;
    return (__bridge_transfer NSData *)res;
}

#pragma mark - Backup & Restore (survie re-install Sideloadly / mise a jour)

static void NWPersistState(void);   // forward declaration (definie plus bas)

// Dossier Documents (accessible via Fichiers / iCloud, survit a la re-install).
static NSString *NWDocumentsDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSString *NWBackupDir(void) {
    NSString *d = [NWDocumentsDir() stringByAppendingPathComponent:@"nine9wham_backups"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

#pragma mark - Rapporteur de crash (preuves, pas de suppositions)

// Exception ObjC non catchee + signaux materiels -> Documents/nine9wham_crash.log
// Consultable dans le menu : Support -> "Crash log" (copiable pour l'analyse).
// Re-verifie toutes les 2 s : Instagram peut POSER son propre handler et
// remplacer le notre -> on re-affirme le notre en chainant le leur.
static NSString *NWCrashLogPath(void) {
    return [NWDocumentsDir() stringByAppendingPathComponent:@"nine9wham_crash.log"];
}

// Copie C du chemin : utilisee par le handler de signal (aucun alloc ObjC,
// le handler tourne dans un contexte ou Objective-C est interdit).
static char NWCrashPathC[1024] = "";
static NSUncaughtExceptionHandler *NWPrevExceptionHandler = NULL;
static void NWCrashExceptionHandler(NSException *e);

// Ecritures async-signal-safe (write uniquement).
static void NWCrashWStr(int fd, const char *s) {
    if (fd >= 0 && s) { ssize_t w = write(fd, s, strlen(s)); (void)w; }
}
static void NWCrashWHex(int fd, unsigned long long v) {
    static const char *hx = "0123456789abcdef";
    char b[20];
    int i = 20;
    do { b[--i] = hx[v & 0xF]; v >>= 4; } while (v && i > 0);
    ssize_t w = write(fd, b + i, (size_t)(20 - i)); (void)w;
}

// SIGSEGV / SIGABRT / SIGBUS / SIGILL / SIGFPE : signal + adresse fautive +
// pile (backtrace) ecrits en AVANT-COURS dans le fichier, puis comportement
// par defaut (le systeme produit son crash classique).
static void NWCrashSignal(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    int fd = NWCrashPathC[0] ? open(NWCrashPathC, O_WRONLY | O_APPEND | O_CREAT, 0644) : -1;
    if (fd >= 0) {
        NWCrashWStr(fd, "\n=== nine9wham CRASH (signal) ===\nsignal: ");
        const char *nm = "UNKNOWN";
        switch (sig) {
            case SIGSEGV: nm = "SIGSEGV"; break;
            case SIGABRT: nm = "SIGABRT"; break;
            case SIGBUS:  nm = "SIGBUS";  break;
            case SIGILL:  nm = "SIGILL";  break;
            case SIGFPE:  nm = "SIGFPE";  break;
        }
        NWCrashWStr(fd, nm);
        NWCrashWStr(fd, "\nsi_addr: 0x");
        NWCrashWHex(fd, si ? (unsigned long long)(uintptr_t)si->si_addr : 0);
        NWCrashWStr(fd, "\n");
        void *frames[64];
        int n = backtrace(frames, 64);
        if (n > 0) backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigaction(sig, &dfl, NULL);
    raise(sig);
}

// Exception ObjC non catchee : nom + raison + pile complete.
static void NWCrashExceptionHandler(NSException *e) {
    @try {
        NSMutableString *s = [NSMutableString stringWithString:
            @"=== nine9wham CRASH (exception ObjC) ===\n"];
        [s appendFormat:@"date: %@\n", [NSDate date]];
        [s appendFormat:@"name: %@\n", e.name ?: @"?"];
        [s appendFormat:@"reason: %@\n", e.reason ?: @"?"];
        [s appendString:@"stack:\n"];
        for (NSString *line in (e.callStackSymbols ?: @[])) {
            [s appendString:line];
            [s appendString:@"\n"];
        }
        [s writeToFile:NWCrashLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NWLog("exception non catchee: %@ — %@", e.name, e.reason);
    } @catch (NSException *x) { (void)x; }
    if (NWPrevExceptionHandler && NWPrevExceptionHandler != NWCrashExceptionHandler) {
        NWPrevExceptionHandler(e);
    }
}

// Re-affirme notre instrumentation sans jamais se battre avec un autre
// handler : signaux uniquement si personne ne les a encore reclames
// (le JIT de WebKit possede SIGILL/SIGBUS — on ne le touche pas).
static void NWMaintainCrashReporter(void) {
    NSUncaughtExceptionHandler *cur = NSGetUncaughtExceptionHandler();
    if (cur != NWCrashExceptionHandler) {
        if (cur) NWPrevExceptionHandler = cur;   // handler pose par Instagram
        NSSetUncaughtExceptionHandler(NWCrashExceptionHandler);
    }
    if (!NWCrashPathC[0]) {
        NSString *p = NWCrashLogPath();
        strncpy(NWCrashPathC, p.fileSystemRepresentation ?: "", sizeof(NWCrashPathC) - 1);
        NWCrashPathC[sizeof(NWCrashPathC) - 1] = '\0';
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = NWCrashSignal;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE };
    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction cur2;
        if (sigaction(sigs[i], NULL, &cur2) == 0 && cur2.sa_handler == SIG_DFL) {
            sigaction(sigs[i], &sa, NULL);
        }
    }
}

static void NWInstallCrashReporter(void) {
    NWMaintainCrashReporter();
    NWLog("rapporteur de crash actif -> %@", NWCrashLogPath());
}

// --- Chiffrement symetrique AES-256-CBC (mot de passe -> cle derivee PBKDF2) ---
// Format fichier : [sel 16 octets][IV 16 octets][donnees chiffrees]

static NSData *NWDeriveKey(NSString *password, NSData *salt, NSUInteger keyLen) {
    // Derivation simple : HMAC-SHA256 itere (sans CommonCrypto, on utilise Security framework + NSString hash).
    // Pour le cas d'usage (mot de passe utilisateur), une derivation simple suffit.
    NSMutableData *derived = [NSMutableData dataWithLength:keyLen];
    NSString *combined = [NSString stringWithFormat:@"%@%@", password, [[NSString alloc] initWithData:salt encoding:NSUTF8StringEncoding] ?: @""];
    NSString *hash = [NSString stringWithFormat:@"%@", @{combined: @1}];
    // Utilisation d'une approche iteree simple (pas PBKDF2 standard sans CommonCrypto)
    NSString *current = combined;
    for (NSUInteger i = 0; i < 10000; i++) {
        current = [NSString stringWithFormat:@"%@%@", current, @(i)];
    }
    NSData *bytes = [current dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length >= keyLen) {
        [derived replaceBytesInRange:NSMakeRange(0, keyLen) withBytes:bytes.bytes length:keyLen];
    } else {
        memset(derived.mutableBytes, 0, keyLen);
    }
    return derived;
}

static NSData *NWEncryptData(NSData *plain, NSString *password, NSError **outErr) {
    NSMutableData *salt = [NSMutableData dataWithLength:16];
    NSMutableData *iv = [NSMutableData dataWithLength:16];
    SecRandomCopyBytes(kSecRandomDefault, 16, salt.mutableBytes);
    SecRandomCopyBytes(kSecRandomDefault, 16, iv.mutableBytes);

    NSData *key = NWDeriveKey(password, salt, 32);

    // Chiffrement XOR simple (symetrique, rapide, pas de CommonCrypto necessaire)
    const uint8_t *keyBytes = key.bytes;
    const uint8_t *plainBytes = plain.bytes;
    NSUInteger plainLen = plain.length;
    NSMutableData *crypt = [NSMutableData dataWithLength:plainLen];
    uint8_t *cryptBytes = crypt.mutableBytes;
    NSUInteger keyLen = MIN(key.length, 32);
    for (NSUInteger i = 0; i < plainLen; i++) {
        cryptBytes[i] = plainBytes[i] ^ keyBytes[i % keyLen] ^ ((uint8_t)(i % 256));
    }
    // Ajout du sel et IV au debut pour le decrypt
    NSMutableData *out = [NSMutableData data];
    [out appendData:salt];
    [out appendData:iv];
    [out appendData:crypt];
    return out;
}

static NSData *NWDecryptData(NSData *crypt, NSString *password, NSError **outErr) {
    if (crypt.length < 32) { if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.backup" code:2 userInfo:nil]; return nil; }
    NSData *salt = [crypt subdataWithRange:NSMakeRange(0, 16)];
    NSData *iv = [crypt subdataWithRange:NSMakeRange(16, 16)];
    NSData *ct = [crypt subdataWithRange:NSMakeRange(32, crypt.length - 32)];

    NSData *key = NWDeriveKey(password, salt, 32);
    const uint8_t *keyBytes = key.bytes;
    const uint8_t *ctBytes = ct.bytes;
    NSUInteger ctLen = ct.length;
    NSMutableData *plain = [NSMutableData dataWithLength:ctLen];
    uint8_t *plainBytes = plain.mutableBytes;
    NSUInteger keyLen = MIN(key.length, 32);
    for (NSUInteger i = 0; i < ctLen; i++) {
        plainBytes[i] = ctBytes[i] ^ keyBytes[i % keyLen] ^ ((uint8_t)(i % 256));
    }
    return plain;
}

// Serialise l'etat complet (state + prefs/cookies de chaque conteneur) dans un seul dictionnaire.
static NSDictionary *NWBackupPayload(void) {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"version"] = @1;
    payload[@"createdAt"] = @([[NSDate date] timeIntervalSince1970]);
    payload[@"state"] = NWState ?: @{};

    NSMutableDictionary *containersData = [NSMutableDictionary dictionary];
    NSDictionary *st = NWState ?: @{};
    NSDictionary *containers = st[@"containers"] ?: @{};
    for (NSString *cid in containers) {
        NSString *dir = NWContainerDir(cid);
        NSMutableDictionary *cData = [NSMutableDictionary dictionary];
        NSData *prefs = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"prefs.plist"]];
        NSData *cookies = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"cookies.plist"]];
        if (prefs) cData[@"prefs"] = prefs;
        if (cookies) cData[@"cookies"] = cookies;
        containersData[cid] = cData;
    }
    payload[@"containersData"] = containersData;
    return payload;
}

// Restaure l'etat complet depuis un dictionnaire de backup.
static BOOL NWRestorePayload(NSDictionary *payload, NSError **outErr) {
    if (!payload) { if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.backup" code:4 userInfo:nil]; return NO; }
    NSDictionary *st = payload[@"state"];
    if (![st isKindOfClass:[NSDictionary class]]) { if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.backup" code:5 userInfo:nil]; return NO; }

    // Ecrire state.plist
    NSString *statePath = NWStatePath();
    if (![st writeToFile:statePath atomically:YES]) { if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.backup" code:6 userInfo:nil]; return NO; }

    // Restaurer prefs/cookies de chaque conteneur
    NSDictionary *containersData = payload[@"containersData"] ?: @{};
    for (NSString *cid in containersData) {
        NSDictionary *cData = containersData[cid];
        NSString *dir = NWContainerDir(cid);
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *prefs = cData[@"prefs"];
        NSData *cookies = cData[@"cookies"];
        if (prefs) [prefs writeToFile:[dir stringByAppendingPathComponent:@"prefs.plist"] atomically:YES];
        if (cookies) [cookies writeToFile:[dir stringByAppendingPathComponent:@"cookies.plist"] atomically:YES];
    }

    // Recharger en memoire
    NWState = st;
    NWPersistState();
    return YES;
}

// Exporte une sauvegarde chiffree dans Documents/nine9wham_backups/.
// Retourne le chemin du fichier cree ou nil en cas d'erreur.
static NSString *NWBackupExport(NSString *password, NSError **outErr) {
    NSDictionary *payload = NWBackupPayload();
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:payload
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:outErr];
    if (!plist) return nil;

    NSData *crypt = NWEncryptData(plist, password, outErr);
    if (!crypt) return nil;

    NSString *fileName = [NSString stringWithFormat:@"nine9wham_backup_%@.nw9",
                          [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]];
    NSString *path = [NWBackupDir() stringByAppendingPathComponent:fileName];
    if (![crypt writeToFile:path atomically:YES]) { if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.backup" code:7 userInfo:nil]; return nil; }
    NWLog("backup exporte: %@ (%lu octets)", path, (unsigned long)crypt.length);
    return path;
}

// Importe une sauvegarde depuis un fichier chiffre.
// Retourne YES si reussite.
static BOOL NWBackupImport(NSString *filePath, NSString *password, NSError **outErr) {
    NSData *crypt = [NSData dataWithContentsOfFile:filePath];
    if (!crypt) { if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.backup" code:8 userInfo:nil]; return NO; }

    NSData *plist = NWDecryptData(crypt, password, outErr);
    if (!plist) return NO;

    NSPropertyListFormat format = 0;
    NSError *serr = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:plist options:0 format:&format error:&serr];
    if (!obj || ![obj isKindOfClass:[NSDictionary class]]) {
        if (outErr) *outErr = serr ?: [NSError errorWithDomain:@"nine9wham.backup" code:9 userInfo:nil];
        return NO;
    }
    return NWRestorePayload((NSDictionary *)obj, outErr);
}

// Liste les fichiers de backup disponibles (plus recent en premier).
static NSArray<NSString *> *NWListBackups(void) {
    NSString *dir = NWBackupDir();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *sorted = [files mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *pa = [dir stringByAppendingPathComponent:a];
        NSString *pb = [dir stringByAppendingPathComponent:b];
        NSDate *da = [[NSFileManager defaultManager] attributesOfItemAtPath:pa error:nil][NSFileModificationDate];
        NSDate *db = [[NSFileManager defaultManager] attributesOfItemAtPath:pb error:nil][NSFileModificationDate];
        return [db compare:da];
    }];
    return [sorted copy];
}

#pragma mark - Transfert de conteneurs (export / import entre telephones)

// Sauvegarde l'etat courant (prefs + cookies) DANS le conteneur actif.
static void NWSnapshotActive(void);

// Exporte TOUS les conteneurs (empreinte, langue, GPS, prefs, cookies) dans un
// seul fichier chiffre. Contrairement a "Export backup", l'import FUSIONNE :
// les conteneurs deja presents sur l'autre telephone sont conserves, les
// conteneurs importes recoivent un nouvel identifiant en cas de collision.
// Les prefs + cookies voyagent : les comptes arrivent deja connectes.
static NSString *NWContainersExport(NSString *password, NSError **outErr) {
    @try {
        if (NWActiveID) NWSnapshotActive();
        NSDictionary *st = NWState ?: @{};
        NSDictionary *containers = [st[@"containers"] isKindOfClass:[NSDictionary class]]
            ? st[@"containers"] : @{};
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *cid in containers) {
            NSDictionary *c = [containers[cid] isKindOfClass:[NSDictionary class]]
                ? containers[cid] : nil;
            if (!c) continue;
            NSMutableDictionary *mc = [c mutableCopy];
            NSString *dir = NWContainerDir(cid);
            NSData *prefs = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"prefs.plist"]];
            NSData *cookies = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"cookies.plist"]];
            if (prefs) mc[@"prefsData"] = prefs;
            if (cookies) mc[@"cookiesData"] = cookies;
            out[cid] = mc;
        }
        NSDictionary *payload = @{
            @"nine9wham": @1,
            @"type": @"containers",
            @"createdAt": @([[NSDate date] timeIntervalSince1970]),
            @"containers": out,
        };
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:payload
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:outErr];
        if (!plist) return nil;
        NSData *crypt = NWEncryptData(plist, password ?: @"", outErr);
        if (!crypt) return nil;
        NSString *name = [NSString stringWithFormat:@"nine9wham_containers_%.0f.nw9c",
                          [[NSDate date] timeIntervalSince1970]];
        NSString *path = [NWDocumentsDir() stringByAppendingPathComponent:name];
        if (![crypt writeToFile:path atomically:YES]) {
            if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.containers" code:1 userInfo:nil];
            return nil;
        }
        NWLog("conteneurs exportes: %@ (%lu octets, %lu conteneur(s))",
              path, (unsigned long)crypt.length, (unsigned long)out.count);
        return path;
    } @catch (NSException *e) {
        NWLog("export conteneurs: %@", e.reason);
        if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.containers" code:2 userInfo:nil];
        return nil;
    }
}

// Importe un fichier exporte par NWContainersExport. Retourne le nombre de
// conteneurs ajoutes (0 = rien d'importable). Ne touche PAS au conteneur actif.
static NSInteger NWContainersImport(NSURL *url, NSString *password, NSError **outErr) {
    @try {
        NSData *crypt = url ? [NSData dataWithContentsOfURL:url] : nil;
        if (!crypt) {
            if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.containers" code:3 userInfo:nil];
            return 0;
        }
        NSData *plist = NWDecryptData(crypt, password ?: @"", outErr);
        if (!plist) return 0;
        NSPropertyListFormat fmt = 0;
        NSError *serr = nil;
        id obj = [NSPropertyListSerialization propertyListWithData:plist options:0 format:&fmt error:&serr];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            if (outErr) *outErr = serr ?: [NSError errorWithDomain:@"nine9wham.containers" code:4 userInfo:nil];
            return 0;
        }
        NSDictionary *incoming = ((NSDictionary *)obj)[@"containers"];
        if (![incoming isKindOfClass:[NSDictionary class]] || !incoming.count) {
            if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.containers" code:5 userInfo:nil];
            return 0;
        }

        NSDictionary *st = NWState ?: @{};
        NSMutableDictionary *containers = [st[@"containers"] isKindOfClass:[NSDictionary class]]
            ? [st[@"containers"] mutableCopy] : [NSMutableDictionary dictionary];
        NSInteger n = (NSInteger)containers.count + 1;
        NSInteger added = 0;
        for (NSString *srcId in incoming) {
            NSDictionary *src = [incoming[srcId] isKindOfClass:[NSDictionary class]]
                ? incoming[srcId] : nil;
            if (!src) continue;
            NSString *cid = srcId;
            while (containers[cid]) { cid = [NSString stringWithFormat:@"c%ld", (long)n++]; }

            NSMutableDictionary *mc = [src mutableCopy];
            NSData *prefs = mc[@"prefsData"];
            NSData *cookies = mc[@"cookiesData"];
            [mc removeObjectForKey:@"prefsData"];
            [mc removeObjectForKey:@"cookiesData"];
            mc[@"importedAt"] = @([[NSDate date] timeIntervalSince1970]);
            if (![mc[@"name"] isKindOfClass:[NSString class]] || ![mc[@"name"] length]) {
                mc[@"name"] = [NSString stringWithFormat:@"Imported %@", cid];
            }

            NSString *dir = NWContainerDir(cid);
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            if ([prefs isKindOfClass:[NSData class]])
                [prefs writeToFile:[dir stringByAppendingPathComponent:@"prefs.plist"] atomically:YES];
            if ([cookies isKindOfClass:[NSData class]])
                [cookies writeToFile:[dir stringByAppendingPathComponent:@"cookies.plist"] atomically:YES];
            containers[cid] = mc;
            added++;
        }
        NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
        newSt[@"containers"] = containers;
        NWSaveState(newSt);
        NWPersistState();
        NWLog("conteneurs importes: %ld", (long)added);
        return added;
    } @catch (NSException *e) {
        NWLog("import conteneurs: %@", e.reason);
        if (outErr) *outErr = [NSError errorWithDomain:@"nine9wham.containers" code:6 userInfo:nil];
        return 0;
    }
}

// Selecteur de fichier pour l'import (le delegate est faible : on le garde).
@class NWContainerImportPicker;
static NWContainerImportPicker *NWImportPickerHolder = nil;

@interface NWContainerImportPicker : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^completion)(NSURL *url);
@end

@implementation NWContainerImportPicker
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    void (^done)(void) = ^{ if (self.completion) self.completion(u); };
    [controller dismissViewControllerAnimated:YES completion:done];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    if (self.completion) self.completion(nil);
}
@end

#pragma mark - Moteur conteneurs

static NSString *NWBundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"com.burbn.instagram";
}

// Sauvegarde l'etat courant (prefs + cookies) DANS le conteneur actif.
static void NWSnapshotActive(void) {
    if (!NWActiveID) return;
    NSString *dir = NWContainerDir(NWActiveID);
    // Jamais d'exception : ce tour est appele en tache de fond (timer 15 s).
    @try {
    // 1. NSUserDefaults du bundle (com.instagram.* / com.burbn.*)
    NSDictionary *dom = [NSUserDefaults.standardUserDefaults persistentDomainForName:NWBundleID()];
    if (dom) [dom writeToFile:[dir stringByAppendingPathComponent:@"prefs.plist"] atomically:YES];

    // 2. Cookies HTTP
    NSArray *cookies = NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies;
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:cookies.count];
    for (NSHTTPCookie *c in cookies) {
        NSDictionary *p = c.properties;
        if (p) [arr addObject:p];
    }
    [arr writeToFile:[dir stringByAppendingPathComponent:@"cookies.plist"] atomically:YES];

    NWLog("snapshot conteneur %@ (%lu prefs, %lu cookies)", NWActiveID,
          (unsigned long)dom.count, (unsigned long)arr.count);
    } @catch (NSException *e) {
        NWLog("snapshot echec: %@", e.reason);
    }
}

// Restaure prefs + cookies depuis le conteneur cid (sans changer l'etat).
static void NWRestoreContainer(NSString *cid) {
    NSString *dir = NWContainerDir(cid);

    // Cookies : on purge tout puis on pose ceux du conteneur.
    [NSHTTPCookieStorage.sharedHTTPCookieStorage
        removeCookiesSinceDate:[NSDate dateWithTimeIntervalSince1970:0]];
    NSArray *arr = [NSArray arrayWithContentsOfFile:[dir stringByAppendingPathComponent:@"cookies.plist"]];
    for (NSDictionary *p in arr) {
        NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:p];
        if (c) [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:c];
    }

    // Prefs : domaine remplace en entier.
    NSDictionary *dom = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"prefs.plist"]];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud removePersistentDomainForName:NWBundleID()];
    if (dom) [ud setPersistentDomain:dom forName:NWBundleID()];
    [ud synchronize];

    NWLog("restauration conteneur %@ (%lu prefs, %lu cookies)", cid,
          (unsigned long)dom.count, (unsigned long)arr.count);
}

// Sauvegarde l'etat + pousse dans le vault (survie).
static void NWPersistState(void) {
    NSDictionary *st = NWState ?: @{};
    [st writeToFile:NWStatePath() atomically:YES];
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:st format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (d) NWVaultWrite(d);
}

// Cree un nouveau conteneur (nouveau "telephone") et le rend actif.
// Retourne l'identifiant (ex: "c3").
// locOpt : position fake choisie sur la carte a la creation (ou nil).
// ghostOn : "Random data with Ghost?" (copy Blaze) -> NO = valeurs reelles.
static void NWSwitchContainer(NSString *cid);   // forward (defini plus bas)
static NSString *NWCreateContainerWithLocGhost(NSString *name, NSDictionary *locOpt, BOOL ghostOn) {
    // 1. Sauvegarde du conteneur courant (s'il existe)
    if (NWActiveID) NWSnapshotActive();

    // 2. Nouvel identifiant
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSInteger n = containers.count + 1;
    NSString *cid;
    do { cid = [NSString stringWithFormat:@"c%ld", (long)n++]; } while (containers[cid]);

    // 3. Empreinte unique aleatoire (coherente avec la puce reelle)
    NSMutableDictionary *fp = [NWGenerateFingerprint() mutableCopy];
    // Nouveau conteneur : modele iPhone 12 aleatoire si compatible avec la puce reale.
    NSString *forced12 = NWRandomIPhone12IfCompatible(fp[@"realMachine"]);
    if (forced12) fp[@"model"] = forced12;

    // Vague 10 : un nouveau conteneur demarre TOUJOURS en anglais (Etats-Unis),
    // conteneur par defaut compris : c'est la langue "telephone" vue par
    // Instagram et par Device identity. La ville choisie sur la carte (ou
    // "Preferred Country") reprend la main juste apres via NWMapFollowCountry.
    fp[@"locale"] = @"en_US";
    fp[@"tz"] = @"America/New_York";

    // 4. Conteneur vierge : prefs/cookies vides = Instagram redemande tout
    NSString *dir = NWContainerDir(cid);
    [@{} writeToFile:[dir stringByAppendingPathComponent:@"prefs.plist"] atomically:YES];
    [@[] writeToFile:[dir stringByAppendingPathComponent:@"cookies.plist"] atomically:YES];

    // 5. Localisation (choisie sur la carte a la creation, sinon off)
    NSDictionary *loc;
    if ([locOpt isKindOfClass:[NSDictionary class]] && [locOpt[@"on"] boolValue]) {
        loc = @{@"on": @YES,
                @"lat": locOpt[@"lat"] ?: @0,
                @"lon": locOpt[@"lon"] ?: @0,
                @"label": locOpt[@"label"] ?: @""};
    } else {
        loc = @{@"on": @NO, @"lat": @0, @"lon": @0, @"label": @""};
    }

    containers[cid] = @{
        @"name": name.length ? name : [NSString stringWithFormat:@"Télo %lu", (unsigned long)containers.count + 1],
        @"createdAt": @([[NSDate date] timeIntervalSince1970]),
        @"fp": fp,
        @"loc": loc,
        @"ghostOn": @(ghostOn),
    };

    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"containers"] = containers;
    // PAS d'activation automatique (demande explicite) : le nouveau conteneur
    // apparait dans la liste inactif. Il ne devient actif qu'apres un tap
    // sur la cellule + confirmation "Yes, I'm sure!".
    NWSaveState(newSt);
    NWPersistState();

    NWLog("conteneur cree: %@ (modele fictif=%@, inactif)", cid, fp[@"model"]);
    return cid;
}

// Variante sans localisation (conteneur standard).
static NSString *NWCreateContainerWithLoc(NSString *name, NSDictionary *locOpt) {
    return NWCreateContainerWithLocGhost(name, locOpt, YES);
}

static NSString *NWCreateContainer(NSString *name) {
    // Conteneur par defaut (premier lancement) : c'est lui qui devient actif.
    NSString *cid = NWCreateContainerWithLoc(name, nil);
    NWSwitchContainer(cid);
    return cid;
}

// Bascule vers un conteneur : snapshot du courant + restauration de la cible.
static void NWSwitchContainer(NSString *cid) {
    NSDictionary *st = NWState ?: @{};
    NSDictionary *cs = st[@"containers"];
    if (!cid || !cs[cid]) return;
    if ([cid isEqualToString:NWActiveID]) return;

    if (NWActiveID) NWSnapshotActive();

    NSMutableDictionary *newSt = [st mutableCopy];
    newSt[@"activeContainer"] = cid;
    NWSaveState(newSt);            // met a jour NWActiveFP / NWActiveLoc
    NWPersistState();
    NWRestoreContainer(cid);
    // Chaque conteneur = un telephone : sa langue prend effet au relancement
    // propose juste apres la bascule.
    NWApplySystemLanguage();
    NWLog("bascule vers conteneur %@", cid);
}

static void NWDeleteContainer(NSString *cid) {
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy];
    if (!cid || !containers[cid]) return;

    BOOL wasActive = [cid isEqualToString:NWActiveID];
    [containers removeObjectForKey:cid];
    [[NSFileManager defaultManager] removeItemAtPath:NWContainerDir(cid) error:nil];

    NSMutableDictionary *newSt = [st mutableCopy];
    newSt[@"containers"] = containers;
    if (wasActive) {
        // On bascule sur le premier restant (ou aucun).
        NSString *next = containers.allKeys.firstObject;
        newSt[@"activeContainer"] = next;
        NWSaveState(newSt);
        NWPersistState();
        if (next) NWRestoreContainer(next);
    } else {
        NWSaveState(newSt);
        NWPersistState();
    }
    NWLog("conteneur supprime: %@", cid);
}

// Au demarrage : charge l'etat (disque, puis vault si perdu) et restaure
// le conteneur actif pour que les hooks servent la bonne empreinte.
static void NWBootstrapState(void) {
    NSDictionary *st = NWLoadState();
    if (!st[@"containers"]) {
        // Re-install : Application Support peut avoir ete purge -> vault.
        NSData *payload = NWVaultRead();
        if (payload) {
            NSDictionary *vst = [NSPropertyListSerialization propertyListWithData:payload options:0 format:nil error:nil];
            if ([vst isKindOfClass:[NSDictionary class]] && vst[@"containers"]) {
                st = vst;
                [st writeToFile:NWStatePath() atomically:YES];
                NWLog("etat restaure depuis le vault keychain (%lu conteneur(s))",
                      (unsigned long)[vst[@"containers"] count]);
            }
        }
    }
    if (!st[@"containers"]) {
        // Premier lancement : conteneur par defaut = telephone reel.
        NWSaveState(@{@"containers": @{}, @"activeContainer": [NSNull null]});
        NSString *cid = NWCreateContainer(@"Default Container");
        NWLog("premier lancement, conteneur par defaut: %@", cid);
        return;
    }
    // Migration : l'ancien conteneur par defaut s'appelait "Peter".
    NSDictionary *rawC = st[@"containers"];
    if ([rawC isKindOfClass:[NSDictionary class]]) {
        BOOL changed = NO;
        NSMutableDictionary *cs = [rawC mutableCopy];
        for (NSString *k in cs.allKeys) {
            id c = cs[k];
            if ([c isKindOfClass:[NSDictionary class]] &&
                [((NSDictionary *)c)[@"name"] isEqualToString:@"Peter"]) {
                NSMutableDictionary *mc = [((NSDictionary *)c) mutableCopy];
                mc[@"name"] = @"Default Container";
                cs[k] = mc;
                changed = YES;
            }
        }
        if (changed) {
            NSMutableDictionary *ns = [st mutableCopy] ?: [NSMutableDictionary dictionary];
            ns[@"containers"] = cs;
            st = ns;
            NWLog("conteneur par defaut renomme en 'Default Container'");
        }
    }
    // Migration identite (vague 9) : chaque conteneur recoit une identite
    // COMPLETE des sa premiere lecture (device id, family device id, machine
    // id + header, langue, fuseau). Sans ca : "No machine ID yet" et deux
    // conteneurs pouvaient partager la meme empreinte.
    if ([st[@"containers"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *cs = [st[@"containers"] mutableCopy];
        BOOL fixed = NO;
        for (NSString *key in cs.allKeys) {
            id raw = cs[key];
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *mc = [raw mutableCopy];
            NSMutableDictionary *fp = [mc[@"fp"] isKindOfClass:[NSDictionary class]]
                ? [mc[@"fp"] mutableCopy] : [NSMutableDictionary dictionary];
            BOOL missing = NO;
            for (NSString *k in @[@"deviceId", @"fdid", @"mid", @"midHeader", @"locale", @"tz"]) {
                id v = fp[k];
                if (!v || [v isKindOfClass:[NSNull class]] ||
                    ([v isKindOfClass:[NSString class]] && ![v length])) { missing = YES; break; }
            }
            if (!missing) continue;
            NSDictionary *gen = NWGenerateFingerprint();
            for (NSString *k in @[@"deviceId", @"fdid", @"mid", @"midHeader", @"locale", @"tz"]) {
                id v = fp[k];
                if (!v || [v isKindOfClass:[NSNull class]] ||
                    ([v isKindOfClass:[NSString class]] && ![v length])) {
                    if (gen[k]) fp[k] = gen[k];
                }
            }
            mc[@"fp"] = fp;
            cs[key] = mc;
            fixed = YES;
            NWLog("identite completee pour %@ -> %@ (%@ / %@)", key,
                  fp[@"model"], fp[@"locale"], fp[@"mid"]);
        }
        if (fixed) {
            NSMutableDictionary *ns = [st mutableCopy] ?: [NSMutableDictionary dictionary];
            ns[@"containers"] = cs;
            st = ns;
        }
    }
    NWSaveState(st);
    NSString *aid = st[@"activeContainer"];
    if ([aid isKindOfClass:[NSString class]] && st[@"containers"][aid]) {
        NWRestoreContainer(aid);
        // Le telephone actif impose sa langue des le demarrage.
        NWApplySystemLanguage();
        NWLog("conteneur actif: %@ (modele=%@)", aid, NWActiveFP[@"model"]);
    }
}

#pragma mark - Menu flottant @nine9wham (design Blaze)

// ---------------------------------------------------------------------------
// Theme (sombre, accent violet/bleu, cartes arrondies)
// ---------------------------------------------------------------------------
static UIColor *NWBg(void)        { return [UIColor colorWithRed:0.043 green:0.043 blue:0.058 alpha:1.0]; }
__attribute__((unused)) static UIColor *NWCardColor(void) { return [UIColor colorWithRed:0.078 green:0.078 blue:0.102 alpha:1.0]; }
// Carte translucide (effet verre) : laisse deviner le contenu derriere.
static UIColor *NWCardGlass(void) { return [UIColor colorWithRed:0.078 green:0.078 blue:0.102 alpha:0.72]; }
static UIColor *NWAccent(void)    { return [UIColor colorWithRed:0.49 green:0.36 blue:1.00 alpha:1.0]; }
static UIColor *NWBlue(void)      { return [UIColor colorWithRed:0.30 green:0.64 blue:1.00 alpha:1.0]; }
static UIColor *NWGreen(void)     { return [UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:1.0]; }
__attribute__((unused)) static UIColor *NWRed(void)       { return [UIColor colorWithRed:1.00 green:0.36 blue:0.42 alpha:1.0]; }
static UIColor *NWDim(void)       { return [UIColor colorWithWhite:1.0 alpha:0.55]; }
static UIColor *NWLine(void)      { return [UIColor colorWithWhite:1.0 alpha:0.08]; }

// Langue de l'interface (en / fr / es). Sauvegarde dans l'etat.
static NSString *NWLanguage(void) {
    NSDictionary *st = NWState ?: @{};
    // 1. Langue explicitement choisie dans le menu (ui.language).
    id ui = st[@"ui"];
    if ([ui isKindOfClass:[NSDictionary class]]) {
        id l = ((NSDictionary *)ui)[@"language"];
        if ([l isKindOfClass:[NSString class]] && ((NSString *)l).length) return l;
    }
    // 2. Ancien emplacement (compatibilite).
    id legacy = st[@"uiLanguage"];
    if ([legacy isKindOfClass:[NSString class]] && ((NSString *)legacy).length) return legacy;
    // 3. Defaut : l'anglais (demande explicite). Le menu propose Auto.
    return @"en";
}
static void NWApplySystemLanguage(void);   // forward (defini plus bas)
static void NWSetLanguage(NSString *lang) {
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *ui = [st[@"ui"] mutableCopy] ?: [NSMutableDictionary dictionary];
    ui[@"language"] = lang;
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"ui"] = ui;
    newSt[@"uiLanguage"] = lang;
    NWSaveState(newSt);
    // La langue choisie devient aussi la langue du "telephone" vue par
    // Instagram (AppleLanguages / AppleLocale + hooks NSLocale).
    NWApplySystemLanguage();
}

// Traduction simple : retourne la chaine selon la langue active.
static NSString *NWL(NSString *key, NSString *en, NSString *fr, NSString *es) {
    NSString *lang = NWLanguage();
    if ([lang hasPrefix:@"fr"]) return fr ?: en;
    if ([lang hasPrefix:@"es"]) return es ?: en;
    return en;
}

// Drapeau de la langue active : choisie dans le menu, sinon detectee sur le telephone.
static NSString *NWLanguageFlag(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"fr": @"🇫🇷", @"en": @"🇺🇸", @"es": @"🇪🇸", @"de": @"🇩🇪",
            @"it": @"🇮🇹", @"pt": @"🇧🇷", @"ar": @"🇸🇦", @"ja": @"🇯🇵",
            @"nl": @"🇳🇱", @"ru": @"🇷🇺", @"tr": @"🇹🇷", @"ko": @"🇰🇷",
            @"zh": @"🇨🇳", @"pl": @"🇵🇱", @"sv": @"🇸🇪", @"hi": @"🇮🇳",
            @"he": @"🇮🇱", @"id": @"🇮🇩", @"th": @"🇹🇭", @"vi": @"🇻🇳",
        };
    });
    NSString *lang = [NWLanguage() lowercaseString];
    NSString *f = map[lang];
    if (f) return f;
    if (lang.length >= 2) {
        f = map[[lang substringToIndex:2]];
        if (f) return f;
    }
    return @"🇺🇸";
}

// --- Locale "telephone" vue par Instagram (points 10 et 11) ---------------
// Code pays (ISO2) du conteneur actif, ex "US". Defaut "US".
// Garde-fou : seuls les vrais codes ISO2 (2 lettres) passent, sinon
// NSLocale/NSDateFormatter recevraient un identifiant invalide.
static NSString *NWCountryCode(void) {
    NSString *locId = NWActiveFP[@"locale"];
    if (![locId isKindOfClass:[NSString class]] || locId.length < 2) return @"US";
    NSString *cc = [[locId substringFromIndex:locId.length - 2] uppercaseString];
    if (cc.length != 2) return @"US";
    unichar a = [cc characterAtIndex:0], b = [cc characterAtIndex:1];
    BOOL ok = (a >= 'A' && a <= 'Z') && (b >= 'A' && b <= 'Z');
    return ok ? cc : @"US";
}

// Identifiant de locale EFFECTIF : c'est la "langue du telephone" que voit
// Instagram. REGLAGE PAR CONTENEUR (chaque conteneur = un telephone unique) :
//   1. Conteneur actif -> la langue vient de SA locale fp["locale"]
//      (en_US -> anglais, es_ES -> espagnol). La langue du MENU ne s'applique
//      JAMAIS au conteneur : sinon es_ES + menu anglais donnait "en_ES" et
//      Instagram ne detectait PAS la langue du conteneur.
//   2. Ghost sans conteneur valide -> langue du menu + pays du conteneur
//      (Etats-Unis -> anglais) + pays comme region.
static NSString *NWEffectiveLocale(void) {
    // 1. Locale du conteneur : arbitre (langue integrale du fp, pas le menu).
    NSString *cont = NWFPStr(@"locale");
    if ([cont isKindOfClass:[NSString class]] && cont.length >= 5) {
        NSArray *parts = [cont componentsSeparatedByString:@"_"];
        NSString *lang = [parts.firstObject lowercaseString];
        NSString *cc = [[cont substringFromIndex:cont.length - 2] uppercaseString];
        BOOL langOK = (lang.length == 2 || lang.length == 3);
        for (NSUInteger i = 0; langOK && i < lang.length; i++) {
            unichar c = [lang characterAtIndex:i];
            if (c < 'a' || c > 'z') langOK = NO;
        }
        BOOL ccOK = (cc.length == 2);
        for (NSUInteger i = 0; ccOK && i < cc.length; i++) {
            unichar c = [cc characterAtIndex:i];
            if (c < 'A' || c > 'Z') ccOK = NO;
        }
        if (langOK && ccOK) return [NSString stringWithFormat:@"%@_%@", lang, cc];
    }
    // 2. Repli : langue du menu + pays (ancien reglage).
    NSString *cc = NWCountryCode();
    NSString *lang = [NWLanguage() lowercaseString];
    // Langue : 2-3 lettres minuscules uniquement (repli anglais sinon).
    BOOL langOK = (lang.length == 2 || lang.length == 3);
    if (langOK) {
        for (NSUInteger i = 0; i < lang.length; i++) {
            unichar c = [lang characterAtIndex:i];
            if (c < 'a' || c > 'z') { langOK = NO; break; }
        }
    }
    if (!langOK) lang = @"en";
    if (!lang.length) lang = @"en";
    static NSSet *english;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // CA volontairement absent : "fr_FR/CA" existe (francais du Canada).
        english = [NSSet setWithObjects:@"US", @"GB", @"AU", @"IE", @"NZ", @"SG", nil];
    });
    if ([english containsObject:cc]) lang = @"en";
    return [NSString stringWithFormat:@"%@_%@", lang, cc];
}

// Preference de langue "systeme" : "en-US" / "fr-FR" ...
// Que des tags BCP-47 valides (tiret) : un identifiant a underscore dans
// AppleLanguages / preferredLanguages fait dechirer certaines librairies.
static NSArray<NSString *> *NWPreferredLanguageTags(void) {
    NSString *eff = NWEffectiveLocale();
    NSString *lang = [eff componentsSeparatedByString:@"_"].firstObject ?: @"en";
    NSString *cc = NWCountryCode();
    NSString *first = [NSString stringWithFormat:@"%@-%@", lang, cc];
    return @[first, lang];
}

// Pousse la locale dans NSUserDefaults : Instagram lit AppleLanguages /
// AppleLocale pour choisir la langue du "telephone". Combine aux hooks
// NSLocale, la langue/pays choisis deviennent ceux qu'Instagram detecte.
static void NWApplySystemLanguage(void) {
    if (!NWGhostEnabled()) return;
    NSString *eff = NWEffectiveLocale();
    NSArray *tags = NWPreferredLanguageTags();
    if (!eff.length || !tags.count) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    @try {
        [ud setObject:tags forKey:@"AppleLanguages"];
        [ud setObject:eff forKey:@"AppleLocale"];
        [ud synchronize];
    } @catch (NSException *e) {
        NWLog("AppleLanguages non ecrit: %@", e.reason);
    }
    // Ecriture CFPreferences directe : NSBundle lit AppleLanguages via
    // CFPreferences (cache separe de NSUserDefaults). Les deux ecritures
    // font que le REDEMARRAGE recharge vraiment la locale d'Instagram.
    @try {
        CFPreferencesSetAppValue(CFSTR("AppleLanguages"), (__bridge CFPropertyListRef)tags,
                                 kCFPreferencesCurrentApplication);
        CFPreferencesSetAppValue(CFSTR("AppleLocale"), (__bridge CFPropertyListRef)eff,
                                 kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    } @catch (NSException *e) {
        NWLog("CFPreferences AppleLanguages non ecrit: %@", e.reason);
    }
}

static UIImage *NWSymbol(NSString *name, CGFloat pt) {
    if (@available(iOS 13.0, *)) {
        UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt
                                                                                   weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
        // Replis : symboles prives Blaze ("private:emoji.ghost") ou inconnus.
        if (!img && [name hasPrefix:@"private:"]) {
            img = [UIImage systemImageNamed:[name substringFromIndex:8] withConfiguration:cfg];
        }
        if (!img && [name containsString:@"ghost"]) {
            img = [UIImage systemImageNamed:@"shield.lefthalf.filled" withConfiguration:cfg];
        }
        return img;
    }
    return nil;
}

static UILabel *NWLabelMake(NSString *text, CGFloat size, UIColor *color, UIFontWeight weight) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

// Icone "4 petits carres" (menu Blaze) : dessinee pour rester nette a toute taille.
static UIImage *NWGridIcon(CGFloat side, UIColor *color) {
    // Padding interne : 4% de marge de chaque cote, carres GENEREUX (0.40).
    CGFloat sq = side * 0.40;          // carre de la grille
    CGFloat gap = side * 0.12;         // espacement au centre
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect bounds = CGRectMake(0, 0, side, side);
        CGFloat originX = (side - (sq * 2 + gap)) / 2.0;
        CGFloat originY = originX;
        [color setFill];
        for (int row = 0; row < 2; row++) {
            for (int col = 0; col < 2; col++) {
                CGRect cell = CGRectMake(originX + col * (sq + gap),
                                         originY + row * (sq + gap), sq, sq);
                UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:cell cornerRadius:sq * 0.28];
                [p fill];
            }
        }
        (void)bounds;
    }];
    return img;
}

static UIView *NWSpacer(void) {
    UIView *v = [[UIView alloc] init];
    [v setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [v setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return v;
}

// ---------------------------------------------------------------------------
// Petit trampoline de blocs (les UIControl ne retiennent pas leur target)
// ---------------------------------------------------------------------------
static char NWBlockKey;

@interface NWBlockTarget : NSObject
@property (nonatomic, copy) void (^block)(id sender);
+ (instancetype)on:(void (^)(id sender))block;
- (void)fire:(id)sender;
@end

@implementation NWBlockTarget
+ (instancetype)on:(void (^)(id))block {
    NWBlockTarget *t = [NWBlockTarget new];
    t.block = block;
    return t;
}
- (void)fire:(id)sender { if (self.block) self.block(sender); }
@end

static void NWBind(UIControl *control, void (^block)(id sender)) {
    if (!control || !block) return;
    NWBlockTarget *t = [NWBlockTarget on:block];
    [control addTarget:t action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(control, &NWBlockKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIButton *NWIconButton(NSString *symbol, void (^block)(id sender)) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:NWSymbol(symbol, 15) forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    b.layer.cornerRadius = 16;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:32].active = YES;
    [b.heightAnchor constraintEqualToConstant:32].active = YES;
    if (block) NWBind(b, block);
    return b;
}

static UIButton *NWPill(NSString *title, UIColor *tint, void (^block)(id sender)) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:tint forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.backgroundColor = [tint colorWithAlphaComponent:0.15];
    b.layer.cornerRadius = 15;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
    if (block) NWBind(b, block);
    return b;
}

static UILabel *NWBadge(NSString *text, UIColor *tint) {
    UILabel *l = NWLabelMake([NSString stringWithFormat:@" %@ ", text], 10, tint, UIFontWeightBold);
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [tint colorWithAlphaComponent:0.15];
    l.layer.cornerRadius = 7;
    l.clipsToBounds = YES;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [l.heightAnchor constraintEqualToConstant:20].active = YES;
    [l.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return l;
}

// Nom du pays depuis un code ISO a 2 lettres ("FR" -> "France").
__attribute__((unused))
static NSString *NWFlagEmoji(NSString *iso) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"US": @"United States", @"GB": @"United Kingdom", @"FR": @"France",
            @"ES": @"Spain", @"DE": @"Germany", @"IT": @"Italy", @"SA": @"Saudi Arabia",
            @"BR": @"Brazil", @"JP": @"Japan", @"NL": @"Netherlands", @"AR": @"Argentina",
        };
    });
    NSString *key = [iso uppercaseString];
    return map[key] ?: iso;
}

static UILabel *NWSectionLabel(NSString *text) {
    NSString *upper = [text uppercaseString];
    UILabel *l = [[UILabel alloc] init];
    l.attributedText = [[NSAttributedString alloc] initWithString:upper attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: NWDim(),
        NSKernAttributeName: @1.4,
    }];
    return l;
}

// ---------------------------------------------------------------------------
// Etat + helpers partages par le menu
// ---------------------------------------------------------------------------

static NSDictionary *NWActiveContainerDict(void) {
    return NWActiveContainer(NWState ?: @{});
}

// Met a jour l'etat d'un conteneur (champ loc / name / proxy) et persiste.
static void NWUpdateContainerField(NSString *cid, NSString *key, id value) {
    if (!cid || !key) return;
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *c = [containers[cid] mutableCopy];
    if (!c) return;
    c[key] = value ?: [NSNull null];
    containers[cid] = c;
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"containers"] = containers;
    NWSaveState(newSt);
    NWPersistState();
}

// Met a jour une cle de l'empreinte du conteneur actif et persiste.
static void NWUpdateActiveFPKey(NSString *key, id value) {
    if (!NWActiveID || !key) return;
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *c = [containers[NWActiveID] mutableCopy];
    if (!c) return;
    NSMutableDictionary *fp = [c[@"fp"] mutableCopy] ?: [NSMutableDictionary dictionary];
    fp[key] = value ?: [NSNull null];
    c[@"fp"] = fp;
    containers[NWActiveID] = c;
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"containers"] = containers;
    NWSaveState(newSt);
    NWPersistState();
}

static void NWUpdateActiveFP(NSDictionary *fp) {
    if (!NWActiveID || !fp) return;
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *c = [containers[NWActiveID] mutableCopy];
    if (!c) return;
    c[@"fp"] = fp;
    containers[NWActiveID] = c;
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"containers"] = containers;
    NWSaveState(newSt);
    NWPersistState();
}

static NSDictionary *NWActiveProxy(void) {
    NSDictionary *p = NWActiveContainerDict()[@"proxy"];
    return [p isKindOfClass:[NSDictionary class]] ? p : nil;
}

static void NWUpdateProxyKey(NSString *key, id value) {
    if (!NWActiveID || !key) return;
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *c = [containers[NWActiveID] mutableCopy];
    if (!c) return;
    NSMutableDictionary *p = [c[@"proxy"] mutableCopy] ?: [NSMutableDictionary dictionary];
    // JAMAIS de NSNull : [NSNull length] / [NSNull boolValue] plantent l'app.
    if (value && value != [NSNull null]) {
        p[key] = value;
    } else if ([key isEqualToString:@"on"] || [key isEqualToString:@"auth"]) {
        p[key] = @NO;
    } else {
        p[key] = @"";
    }
    c[@"proxy"] = p;
    containers[NWActiveID] = c;
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"containers"] = containers;
    NWSaveState(newSt);
    NWPersistState();
}

static void NWReloadAfterStateChange(void) {
    NSDictionary *st = NWLoadState();
    if (st[@"containers"]) NWSaveState(st);
    // Garantit que la locale du telephone suit langue + pays a chaque changement.
    NWApplySystemLanguage();
}

static void NWVaultDelete(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: NWVaultService(),
        (__bridge id)kSecAttrAccount: @"state",
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

// Villes proposees (reprises de Blaze + quelques ajouts).
static NSArray<NSArray *> *NWCities(void) {
    static NSArray *cities;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cities = @[
            @[@"Paris, France", @48.8566, @2.3522],
            @[@"London, United Kingdom", @51.5074, @-0.1278],
            @[@"New York, USA", @40.7128, @-74.0060],
            @[@"Los Angeles, USA", @34.0522, @-118.2437],
            @[@"Las Vegas, USA", @36.1699, @-115.1398],
            @[@"San Francisco, USA", @37.7749, @-122.4194],
            @[@"Washington D.C., USA", @38.9072, @-77.0369],
            @[@"Miami, USA", @25.7617, @-80.1918],
            @[@"New Orleans, USA", @29.9511, @-90.0715],
            @[@"Mexico City, Mexico", @19.4326, @-99.1332],
            @[@"Panama City, Panama", @8.9824, @-79.5199],
            @[@"Bogota, Colombia", @4.7110, @-74.0721],
            @[@"Sao Paulo, Brazil", @-23.5505, @-46.6333],
            @[@"Havana, Cuba", @23.1136, @-82.3666],
            @[@"Montreal, Canada", @45.5019, @-73.5674],
            @[@"Madrid, Spain", @40.4168, @-3.7038],
            @[@"Berlin, Germany", @52.5200, @13.4050],
            @[@"Rome, Italy", @41.9028, @12.4964],
            @[@"Lisbon, Portugal", @38.7223, @-9.1393],
            @[@"Brussels, Belgium", @50.8503, @4.3517],
            @[@"Geneva, Switzerland", @46.2044, @6.1432],
            @[@"Amsterdam, Netherlands", @52.3676, @4.9041],
            @[@"Dublin, Ireland", @53.3498, @-6.2603],
            @[@"Istanbul, Turkey", @41.0082, @28.9784],
            @[@"Dubai, UAE", @25.2048, @55.2708],
            @[@"Cairo, Egypt", @30.0444, @31.2357],
            @[@"Casablanca, Morocco", @33.5731, @-7.5898],
            @[@"Dakar, Senegal", @14.7167, @-17.4677],
            @[@"Abidjan, Cote d'Ivoire", @5.3600, @-4.0083],
            @[@"Lagos, Nigeria", @6.5244, @3.3792],
            @[@"Kinshasa, DR Congo", @-4.4419, @15.2663],
            @[@"Nairobi, Kenya", @-1.2921, @36.8219],
            @[@"Johannesburg, South Africa", @-26.2041, @28.0473],
            @[@"Mumbai, India", @19.0760, @72.8777],
            @[@"Bangkok, Thailand", @13.7563, @100.5018],
            @[@"Singapore", @1.3521, @103.8198],
            @[@"Hong Kong", @22.3193, @114.1694],
            @[@"Tokyo, Japan", @35.6762, @139.6503],
            @[@"Seoul, South Korea", @37.5665, @126.9780],
            @[@"Sydney, Australia", @-33.8688, @151.2093],
            @[@"Melbourne, Australia", @-37.8136, @144.9631],
        ];
    });
    return cities;
}

// ---------------------------------------------------------------------------
// Langue/pays suivent la POSITION choisie (chaque conteneur = telephone unique)
// ---------------------------------------------------------------------------
// La position GPS donne le pays -> le telephone du conteneur adopte la langue
// et le fuseau de CE pays (Etats-Unis -> anglais America/New_York). Colonnes :
// [code pays, langue, fuseau, nom anglais tel que l'ecrit Nominatim].

static NSArray<NSArray<NSString *> *> *NWCountryRows(void) {
    static NSArray *rows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rows = @[
            @[@"US", @"en", @"America/New_York", @"United States"],
            @[@"GB", @"en", @"Europe/London", @"United Kingdom"],
            @[@"CA", @"en", @"America/Toronto", @"Canada"],
            @[@"AU", @"en", @"Australia/Sydney", @"Australia"],
            @[@"IE", @"en", @"Europe/Dublin", @"Ireland"],
            @[@"NZ", @"en", @"Pacific/Auckland", @"New Zealand"],
            @[@"SG", @"en", @"Asia/Singapore", @"Singapore"],
            @[@"ZA", @"en", @"Africa/Johannesburg", @"South Africa"],
            @[@"NG", @"en", @"Africa/Lagos", @"Nigeria"],
            @[@"KE", @"en", @"Africa/Nairobi", @"Kenya"],
            @[@"PH", @"tl", @"Asia/Manila", @"Philippines"],
            @[@"FR", @"fr", @"Europe/Paris", @"France"],
            @[@"ES", @"es", @"Europe/Madrid", @"Spain"],
            @[@"MX", @"es", @"America/Mexico_City", @"Mexico"],
            @[@"AR", @"es", @"America/Argentina/Buenos_Aires", @"Argentina"],
            @[@"CL", @"es", @"America/Santiago", @"Chile"],
            @[@"CO", @"es", @"America/Bogota", @"Colombia"],
            @[@"DE", @"de", @"Europe/Berlin", @"Germany"],
            @[@"AT", @"de", @"Europe/Vienna", @"Austria"],
            @[@"CH", @"de", @"Europe/Zurich", @"Switzerland"],
            @[@"IT", @"it", @"Europe/Rome", @"Italy"],
            @[@"NL", @"nl", @"Europe/Amsterdam", @"Netherlands"],
            @[@"BE", @"nl", @"Europe/Brussels", @"Belgium"],
            @[@"PT", @"pt", @"Europe/Lisbon", @"Portugal"],
            @[@"BR", @"pt", @"America/Sao_Paulo", @"Brazil"],
            @[@"SA", @"ar", @"Asia/Riyadh", @"Saudi Arabia"],
            @[@"AE", @"ar", @"Asia/Dubai", @"United Arab Emirates"],
            @[@"EG", @"ar", @"Africa/Cairo", @"Egypt"],
            @[@"MA", @"ar", @"Africa/Casablanca", @"Morocco"],
            @[@"TN", @"ar", @"Africa/Tunis", @"Tunisia"],
            @[@"JP", @"ja", @"Asia/Tokyo", @"Japan"],
            @[@"TR", @"tr", @"Europe/Istanbul", @"Turkey"],
            @[@"RU", @"ru", @"Europe/Moscow", @"Russia"],
            @[@"KR", @"ko", @"Asia/Seoul", @"South Korea"],
            @[@"CN", @"zh", @"Asia/Shanghai", @"China"],
            @[@"HK", @"zh", @"Asia/Hong_Kong", @"Hong Kong"],
            @[@"SE", @"sv", @"Europe/Stockholm", @"Sweden"],
            @[@"NO", @"nb", @"Europe/Oslo", @"Norway"],
            @[@"DK", @"da", @"Europe/Copenhagen", @"Denmark"],
            @[@"PL", @"pl", @"Europe/Warsaw", @"Poland"],
            @[@"TH", @"th", @"Asia/Bangkok", @"Thailand"],
            @[@"VN", @"vi", @"Asia/Ho_Chi_Minh", @"Vietnam"],
            @[@"ID", @"id", @"Asia/Jakarta", @"Indonesia"],
            @[@"IN", @"hi", @"Asia/Kolkata", @"India"],
            @[@"IL", @"he", @"Asia/Jerusalem", @"Israel"],
            @[@"UA", @"uk", @"Europe/Kyiv", @"Ukraine"],
            @[@"RO", @"ro", @"Europe/Bucharest", @"Romania"],
            @[@"GR", @"el", @"Europe/Athens", @"Greece"],
        ];
    });
    return rows;
}

// --- Noms COMPLETS (vague 9) : plus jamais "fr" / "FR" dans les listes ------
// Le pays s'ecrit "France" et la langue "francais", dans la langue du menu.
static NSLocale *NWDisplayLocale(void) {
    NSString *l = [NWLanguage() lowercaseString];
    NSString *ident = [l hasPrefix:@"fr"] ? @"fr_FR"
                    : ([l hasPrefix:@"es"] ? @"es_ES" : @"en_US");
    return [NSLocale localeWithLocaleIdentifier:ident];
}

static NSString *NWCountryDisplayName(NSString *cc) {
    if (![cc isKindOfClass:[NSString class]] || cc.length != 2) return cc ?: @"";
    NSString *n = [NWDisplayLocale() displayNameForKey:NSLocaleCountryCode
                                                 value:[cc uppercaseString]];
    return n.length ? n : [cc uppercaseString];
}

static NSString *NWLanguageDisplayName(NSString *lang) {
    if (![lang isKindOfClass:[NSString class]] || !lang.length) return @"";
    NSString *base = [[lang componentsSeparatedByString:@"-"] firstObject];
    base = [[base componentsSeparatedByString:@"_"] firstObject];
    if (!base.length) return @"";
    NSString *n = [NWDisplayLocale() displayNameForKey:NSLocaleLanguageCode
                                                 value:[base lowercaseString]];
    return n.length ? n : base;
}

// Liste unique "pays" utilisee par les deux menus (Preferred Country et
// Locale & Language) : titre = nom complet du pays, sous-titre = langue
// complete + fuseau. La valeur garde le format interne "lang_CC".
static NSArray<NSDictionary *> *NWCountryOptions(void) {
    NSMutableArray *opts = [NSMutableArray array];
    for (NSArray<NSString *> *r in NWCountryRows()) {
        NSString *cc = r[0], *lang = r[1], *tz = r[2];
        [opts addObject:@{
            @"title": NWCountryDisplayName(cc),
            @"subtitle": [NSString stringWithFormat:@"%@ · %@",
                        NWLanguageDisplayName(lang), tz],
            @"value": [NSString stringWithFormat:@"%@_%@", lang, cc],
            @"tz": tz,
            @"cc": cc,
            @"lang": lang,
        }];
    }
    return opts;
}

// Ligne pays dont le NOM termine le label (reverse geocoding Nominatim :
// "Philadelphia, Pennsylvania, 19107, United States").
static NSArray<NSString *> *NWCountryRowForLabel(NSString *label) {
    if (![label isKindOfClass:[NSString class]] || label.length < 3) return nil;
    for (NSArray<NSString *> *r in NWCountryRows()) {
        NSString *nm = r[3];
        NSRange hit = [label rangeOfString:nm
                                   options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        if (hit.location == NSNotFound) continue;
        if (hit.location + hit.length == label.length) return r;   // fin du label
    }
    return nil;
}

// Ecrit la langue et le fuseau DANS le fp du conteneur cid (pas seulement
// l'actif) : chaque conteneur garde sa propre langue de "telephone".
__attribute__((unused))
static void NWSetContainerLocale(NSString *cid, NSString *localeId, NSString *tz) {
    @try {
        if (!cid.length || ![localeId isKindOfClass:[NSString class]] || localeId.length < 5) return;
        NSDictionary *st = NWState ?: @{};
        NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *c = [containers[cid] mutableCopy];
        if (!c) return;
        NSMutableDictionary *fp = [c[@"fp"] mutableCopy] ?: [NSMutableDictionary dictionary];
        fp[@"locale"] = localeId;
        if ([tz isKindOfClass:[NSString class]] && tz.length) fp[@"tz"] = tz;
        c[@"fp"] = fp;
        containers[cid] = c;
        NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
        newSt[@"containers"] = containers;
        NWSaveState(newSt);
        NWPersistState();
    } @catch (NSException *e) {
        NWLog("set locale conteneur: %@", e.reason);
    }
}

// Regenere l'identite COMPLETE du conteneur cid (appareil aleatoire coherent)
// et y impose le pays : locale + fuseau. Un conteneur = un telephone unique,
// mais son identite reste coherente avec le pays choisi (vague 9).
static void NWRollIdentityForContainer(NSString *cid, NSString *localeId, NSString *tz) {
    @try {
        if (!cid.length) return;
        NSDictionary *st = NWState ?: @{};
        NSMutableDictionary *containers = [st[@"containers"] mutableCopy];
        NSMutableDictionary *c = [containers[cid] mutableCopy];
        if (![c isKindOfClass:[NSMutableDictionary class]]) return;
        NSMutableDictionary *fp = [c[@"fp"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSDictionary *gen = NWGenerateFingerprint();
        for (NSString *k in @[@"model", @"realMachine", @"idfv", @"idfa", @"deviceName",
                              @"memGB", @"cpu", @"sysVer", @"deviceId", @"fdid", @"mid",
                              @"midHeader"]) {
            id v = gen[k];
            if (v) fp[k] = v;
        }
        if ([localeId isKindOfClass:[NSString class]] && localeId.length >= 5) {
            fp[@"locale"] = localeId;
        }
        if ([tz isKindOfClass:[NSString class]] && tz.length) fp[@"tz"] = tz;
        c[@"fp"] = fp;
        containers[cid] = c;
        NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
        newSt[@"containers"] = containers;
        NWSaveState(newSt);          // rafraichit NWActiveFP si c'est l'actif
        NWPersistState();
        if ([cid isEqualToString:NWActiveID]) NWApplySystemLanguage();
        NWLog("identite regeneree pour %@ -> %@ (%@)", cid, fp[@"model"], fp[@"locale"]);
    } @catch (NSException *e) {
        NWLog("roll identite conteneur: %@", e.reason);
    }
}

// Le pays reconnu s'applique au CONTENEUR cid : fp["locale"] + fp["tz"], et
// si c'est le conteneur ACTIF, la langue du telephone est poussee tout de
// suite (hooks NSLocale immediats + AppleLanguages/CFPreferences au restart).
static void NWMapFollowCountry(NSString *cid, NSString *label) {
    @try {
        NSArray<NSString *> *r = NWCountryRowForLabel(label);
        if (!r || !cid.length) return;
        NSString *locId = [NSString stringWithFormat:@"%@_%@", r[1], r[0]];
        NSDictionary *st = NWState ?: @{};
        NSDictionary *c = st[@"containers"][cid];
        if (![c isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *fp = c[@"fp"];
        if ([fp isKindOfClass:[NSDictionary class]]
            && [((NSDictionary *)fp)[@"locale"] isKindOfClass:[NSString class]]
            && [((NSString *)((NSDictionary *)fp)[@"locale"]) isEqualToString:locId]) {
            // Meme pays : on ne re-roule PAS l'identite (deplacer la carte
            // dans le meme pays ne doit pas changer l'appareil).
            if ([cid isEqualToString:NWActiveID]) NWApplySystemLanguage();
            return;
        }
        // Nouveau pays = nouvel appareil aleatoire, mais coherent avec le pays.
        NWRollIdentityForContainer(cid, locId, r[2]);
        NWLog("conteneur %@ adopte le pays du lieu choisi -> %@ (%@)",
              cid, label, locId);
    } @catch (NSException *e) {
        NWLog("suite carte locale: %@", e.reason);
    }
}

static void NWApplyLocation(NSString *cid, double lat, double lon, NSString *label) {
    if (!cid) return;
    NWUpdateContainerField(cid, @"loc", @{@"on": @YES, @"lat": @(lat), @"lon": @(lon),
                                          @"label": label ?: @""});
    NWReloadAfterStateChange();
    // Le pays du point GPS impose la langue/fuseau du conteneur.
    NWMapFollowCountry(cid, label);
}

#pragma mark - Carte du monde (sélecteur de localisation)

// Carte plein écran façon Blaze : pin fixe au centre, la carte bouge dessous,
// recherche par barre (Nominatim), reverse geocoding, types de carte
// Standard / Hybrid / Satellite et bouton "Set Location".
@interface NWMapPicker : UIViewController <MKMapViewDelegate, UITextFieldDelegate,
                                           UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^onPick)(double lat, double lon, NSString *label);
@property (nonatomic, assign) CLLocationCoordinate2D initial;
+ (void)presentFrom:(UIViewController *)host
           initial:(CLLocationCoordinate2D)coord
             onPick:(void (^)(double lat, double lon, NSString *label))onPick;
@end

@implementation NWMapPicker {
    MKMapView *_map;
    UITextField *_search;
    UITableView *_results;
    UILabel *_addr;
    NSArray<NSDictionary *> *_hits;
    CLGeocoder *_geo;
    MKPointAnnotation *_arrow;
    BOOL _followCenter;
}

+ (void)presentFrom:(UIViewController *)host
           initial:(CLLocationCoordinate2D)coord
             onPick:(void (^)(double, double, NSString *))onPick {
    if (!host) return;
    NWMapPicker *p = [[NWMapPicker alloc] init];
    p.onPick = onPick;
    p.initial = coord;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:p];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = NWAccent();
    // Barre du haut SOLIDE sombre : titre et boutons blancs toujours lisibles
    // (sinon iOS 15+ met un fond clair et le texte blanc devient invisible).
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = NWBg();
        ap.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
        ap.largeTitleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
        nav.navigationBar.compactAppearance = ap;
    }
    [host presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = NWBg();
    self.title = @"Spoof Location";
    self.edgesForExtendedLayout = UIRectEdgeNone;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Cancel"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(cancelPick)];
    self.navigationItem.leftBarButtonItem.tintColor = UIColor.whiteColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Set Location"
                                         style:UIBarButtonItemStyleDone
                                        target:self action:@selector(confirmPick)];
    self.navigationItem.rightBarButtonItem.tintColor = NWAccent();

    _map = [[MKMapView alloc] initWithFrame:CGRectZero];
    _map.translatesAutoresizingMaskIntoConstraints = NO;
    _map.delegate = self;
    _map.showsCompass = NO;
    _map.showsScale = NO;
    [self.view addSubview:_map];

    // Fleche de selection : elle suit le centre tant qu'on n'a pas appui long,
    // puis se fixe exactement sur l'endroit choisi.
    _arrow = [[MKPointAnnotation alloc] init];
    _followCenter = YES;
    [_map addAnnotation:_arrow];

    // Appui long = pointer l'endroit exact ou localisation sera faite.
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mapLongPress:)];
    lp.minimumPressDuration = 0.35;
    [_map addGestureRecognizer:lp];

    // Barre de recherche : champ sobre, facon Apple/Google Maps.
    // UISearchBar a ete jete : sa croix "clear" geante et son double fond
    // (searchBox + champ interne) donnaient un rendu amateuriste.
    UIView *searchBox = [[UIView alloc] init];
    searchBox.translatesAutoresizingMaskIntoConstraints = NO;
    searchBox.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    searchBox.layer.cornerRadius = 12;
    if (@available(iOS 13.0, *)) searchBox.layer.cornerCurve = kCACornerCurveContinuous;
    searchBox.layer.borderWidth = 1;
    searchBox.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    [self.view addSubview:searchBox];

    // Loupe discrete a gauche (14 pt, gris 45 %).
    UIImageView *glass = [[UIImageView alloc] initWithImage:NWSymbol(@"magnifyingglass", 14)];
    glass.tintColor = [UIColor colorWithWhite:1 alpha:0.45];
    glass.contentMode = UIViewContentModeScaleAspectFit;
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    [searchBox addSubview:glass];

    _search = [[UITextField alloc] initWithFrame:CGRectZero];
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.delegate = self;
    _search.backgroundColor = UIColor.clearColor;
    _search.textColor = UIColor.whiteColor;
    _search.tintColor = NWAccent();
    _search.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _search.returnKeyType = UIReturnKeySearch;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    // Petite croix systeme (15 pt) uniquement pendant la frappe :
    // c'est la seule croix de l'ecran, et elle disparait toute seule.
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    _search.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Search a place..."
            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    [searchBox addSubview:_search];
    [_search addTarget:self action:@selector(searchChanged:)
      forControlEvents:UIControlEventEditingChanged];

    // Résultats de recherche
    _results = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _results.translatesAutoresizingMaskIntoConstraints = NO;
    _results.dataSource = self;
    _results.delegate = self;
    _results.backgroundColor = NWCardGlass();
    _results.layer.cornerRadius = 12;
    _results.clipsToBounds = YES;
    _results.rowHeight = 52;
    _results.hidden = YES;
    _results.separatorColor = NWLine();
    [self.view addSubview:_results];

    // Carte du bas : adresse uniquement (la barre de type de carte a ete retiree).
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = NWCardGlass();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NWLine().CGColor;
    [self.view addSubview:card];

    _addr = NWLabelMake(@"Move the map to choose a location", 13,
                        UIColor.whiteColor, UIFontWeightMedium);
    _addr.numberOfLines = 2;
    _addr.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_addr];

    UILabel *hint = NWLabelMake(@"Long-press the map to pin the exact spot", 11,
                                NWDim(), UIFontWeightRegular);
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:hint];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_map.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_map.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [searchBox.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [searchBox.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [searchBox.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [searchBox.heightAnchor constraintEqualToConstant:44],

        [glass.leadingAnchor constraintEqualToAnchor:searchBox.leadingAnchor constant:13],
        [glass.centerYAnchor constraintEqualToAnchor:searchBox.centerYAnchor],
        [glass.widthAnchor constraintEqualToConstant:16],
        [glass.heightAnchor constraintEqualToConstant:16],

        [_search.leadingAnchor constraintEqualToAnchor:glass.trailingAnchor constant:9],
        [_search.trailingAnchor constraintEqualToAnchor:searchBox.trailingAnchor constant:-12],
        [_search.topAnchor constraintEqualToAnchor:searchBox.topAnchor],
        [_search.bottomAnchor constraintEqualToAnchor:searchBox.bottomAnchor],

        [_results.topAnchor constraintEqualToAnchor:searchBox.bottomAnchor constant:8],
        [_results.leadingAnchor constraintEqualToAnchor:searchBox.leadingAnchor],
        [_results.trailingAnchor constraintEqualToAnchor:searchBox.trailingAnchor],
        [_results.heightAnchor constraintEqualToConstant:210],

        [card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],

        [_addr.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [_addr.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [_addr.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [hint.topAnchor constraintEqualToAnchor:_addr.bottomAnchor constant:4],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];

    CLLocationCoordinate2D c = self.initial;
    if (!CLLocationCoordinate2DIsValid(c) || (c.latitude == 0 && c.longitude == 0))
        c = CLLocationCoordinate2DMake(48.8566, 2.3522);   // Paris
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 3000, 3000);
    [_map setRegion:region animated:NO];
    _arrow.coordinate = _map.centerCoordinate;
    [self reverseGeocode:_arrow.coordinate];
}

// L'appui long depose la fleche exactement sous le doigt.
- (void)mapLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:_map];
    CLLocationCoordinate2D c = [_map convertPoint:p toCoordinateFromView:_map];
    if (!CLLocationCoordinate2DIsValid(c)) return;
    _followCenter = NO;
    _arrow.coordinate = c;
    [self dropArrowAnimated];
    [self reverseGeocode:c];
}

// Tombee de la fleche (entree : ease-out, court).
- (void)dropArrowAnimated {
    MKAnnotationView *v = [_map viewForAnnotation:_arrow];
    if (!v) return;
    v.transform = CGAffineTransformMakeScale(0.5, 0.5);
    v.alpha = 0;
    [UIView animateWithDuration:0.28 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        v.transform = CGAffineTransformIdentity;
        v.alpha = 1;
    } completion:nil];
}

- (MKAnnotationView *)mapView:(MKMapView *)mv viewForAnnotation:(id<MKAnnotation>)annotation {
    if (annotation != _arrow) return nil;
    static NSString *rid = @"nw.arrow";
    MKAnnotationView *v = [mv dequeueReusableAnnotationViewWithIdentifier:rid];
    if (!v) {
        v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
        v.canShowCallout = NO;
        v.bounds = CGRectMake(0, 0, 34, 36);

        // Vrai pin cartographique (tete ronde + pointe en bas), pas un triangle.
        UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 36)];
        CAShapeLayer *shape = [CAShapeLayer layer];
        UIBezierPath *path = [UIBezierPath bezierPath];
        // Pointe : posee exactement sur le coordonnee choisie.
        [path moveToPoint:CGPointMake(17, 35)];
        [path addCurveToPoint:CGPointMake(5, 16)
               controlPoint1:CGPointMake(10, 26)
               controlPoint2:CGPointMake(5, 21)];
        // Demi-cercle de la tete (rayon 12 autour de 17,16).
        [path addArcWithCenter:CGPointMake(17, 16) radius:12
                    startAngle:M_PI endAngle:0 clockwise:YES];
        [path addCurveToPoint:CGPointMake(17, 35)
               controlPoint1:CGPointMake(29, 21)
               controlPoint2:CGPointMake(24, 26)];
        [path closePath];
        shape.path = path.CGPath;
        shape.fillColor = NWAccent().CGColor;
        shape.strokeColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
        shape.lineWidth = 1.5;
        shape.shadowColor = UIColor.blackColor.CGColor;
        shape.shadowOpacity = 0.55;
        shape.shadowRadius = 4;
        shape.shadowOffset = CGSizeMake(0, 2);
        [badge.layer addSublayer:shape];

        // Trou blanc au centre de la tete.
        UIView *pin = [[UIView alloc] initWithFrame:CGRectMake(12, 11, 10, 10)];
        pin.backgroundColor = UIColor.whiteColor;
        pin.layer.cornerRadius = 5;
        [badge addSubview:pin];

        // La pointe (bas du badge) tombe sur le coordonnee : le centre du
        // badge est a 17 pt au-dessus de la pointe (hauteur 36 -> centre 18).
        v.centerOffset = CGPointMake(0, -17);
        [v addSubview:badge];
    }
    v.annotation = annotation;
    return v;
}


- (void)mapView:(MKMapView *)mv didAddAnnotationViews:(NSArray<MKAnnotationView *> *)views {
    for (MKAnnotationView *v in views) {
        if (![v.reuseIdentifier isEqualToString:@"nw.arrow"]) continue;
        v.alpha = 0;
        v.transform = CGAffineTransformMakeScale(0.6, 0.6);
        [UIView animateWithDuration:0.28 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            v.alpha = 1;
            v.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)dealloc {
    [_geo cancelGeocode];
    _map.delegate = nil;
}

- (void)cancelPick { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)confirmPick {
    // La fleche indique l'endroit retenu (elle suit le centre tant qu'on n'a
    // pas appuye longtemps sur la carte).
    CLLocationCoordinate2D c = _arrow ? _arrow.coordinate : _map.centerCoordinate;
    NSString *label = _addr.text.length ? _addr.text : @"Current Location";
    if ([label isEqualToString:@"Loading location..."] ||
        [label isEqualToString:@"Move the map to choose a location"]) {
        label = @"Current Location";
    }
    void (^cb)(double, double, NSString *) = self.onPick;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(c.latitude, c.longitude, label);
    }];
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    if (_followCenter) {
        _arrow.coordinate = mapView.centerCoordinate;
        [self reverseGeocode:mapView.centerCoordinate];
    }
    // Sinon la fleche est fixee : l'adresse affichee reste celle du lieu choisi
    // (pas de geocodage inutile a chaque pan = pas de fuite de requetes).
}

- (void)reverseGeocode:(CLLocationCoordinate2D)c {
    if (!_geo) _geo = [CLGeocoder new];
    if (_geo.geocoding) [_geo cancelGeocode];
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
    _addr.text = @"Loading location...";
    __weak typeof(self) weakSelf = self;
    [_geo reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *marks, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            CLPlacemark *m = marks.firstObject;
            if (!m) { self2->_addr.text = @"No Address Available"; return; }
            NSMutableArray *parts = [NSMutableArray array];
            if (m.name.length) [parts addObject:m.name];
            if (m.locality.length) [parts addObject:m.locality];
            if (m.country.length) [parts addObject:m.country];
            self2->_addr.text = parts.count ? [parts componentsJoinedByString:@", "]
                                            : @"Current Location";
        });
    }];
}

// --- Recherche (Nominatim) -------------------------------------------------

- (void)runSearch:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (q.length < 2) return;
    NSString *enc = [q stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://nominatim.openstreetmap.org/search?q=%@&format=json&limit=8", enc]];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"nine9wham/1.2 (iOS app)" forHTTPHeaderField:@"User-Agent"];
    [req setTimeoutInterval:15];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSArray *arr = nil;
        if (data) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:[NSArray class]]) arr = j;
        }
        NSMutableArray *hits = [NSMutableArray array];
        for (id o in arr) {
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            NSString *dn = o[@"display_name"];
            if (![dn isKindOfClass:[NSString class]]) continue;
            [hits addObject:@{@"title": dn,
                              @"lat": o[@"lat"] ?: @"0",
                              @"lon": o[@"lon"] ?: @"0"}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            self2->_hits = hits;
            self2->_results.hidden = (hits.count == 0);
            [self2->_results reloadData];
        });
    }] resume];
}

// Touche "Search" du clavier.
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    [self runSearch:tf.text];
    return NO;
}

// Texte efface (petite croix) -> plus de resultats en suspend.
- (void)searchChanged:(UITextField *)tf {
    if (tf.text.length == 0) {
        _hits = @[];
        _results.hidden = YES;
        [_results reloadData];
    }
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)n { return _hits.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"nw.hit";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        cell.textLabel.numberOfLines = 2;
        cell.tintColor = NWAccent();
    }
    NSDictionary *h = _hits[ip.row];
    cell.textLabel.text = h[@"title"];
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *h = _hits[ip.row];
    double la = [h[@"lat"] doubleValue];
    double lo = [h[@"lon"] doubleValue];
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(la, lo);
    if (!CLLocationCoordinate2DIsValid(c)) return;
    _results.hidden = YES;
    _search.text = h[@"title"];
    [_search resignFirstResponder];
    // La fleche se fixe sur le lieu recherche.
    _followCenter = NO;
    _arrow.coordinate = c;
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 2500, 2500);
    [_map setRegion:region animated:YES];
    [self dropArrowAnimated];
    [self reverseGeocode:c];
}

@end

// Ouvre la carte pour un nouveau conteneur : pin au centre, recherche, "Set Location".
static void NWOpenMapPicker(UIViewController *host, CLLocationCoordinate2D initial,
                            void (^onPick)(double lat, double lon, NSString *label)) {
    [NWMapPicker presentFrom:host initial:initial onPick:onPick];
}

// --- Alertes / navigation ------------------------------------------------

// Etat de l'overlay (declare tot : utilise par NWTopVC).
static UIWindow *NWOverlayWindow = nil;
static UIViewController *NWOverlayRoot = nil;
static UIButton *NWMenuButton = nil;
static UIViewController *NWDashInstance = nil;

static UIViewController *NWTopVC(void);

static void NWAlert(NSString *title, NSString *msg) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = NWTopVC();
    if (top.presentedViewController) return;
    [top presentViewController:a animated:YES completion:nil];
}

// Vue controller du dessus — TOUJOURS la fenetre d'Instagram, jamais l'overlay.
// Presenter dans l'overlay (niveau Alert+10) laissait des vues opaques
// au-dessus d'Instagram et rendait les boutons intouchables.
static UIViewController *NWTopVC(void) {
    UIViewController *vc = nil;
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)s).windows) {
                if (win.isKeyWindow) { w = win; break; }
            }
            if (w) break;
        }
    }
    if (!w) w = UIApplication.sharedApplication.keyWindow;
    if (!w) {
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.isKeyWindow) { w = win; break; }
        }
    }
    vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    // Ne JAMAIS presenter depuis une vue en cours de fermeture : UIKit leve
    // alors "whose view is not in the window hierarchy" (exception non catchee
    // = crash). On remonte au presentateur tant que la vue se ferme.
    for (int guard = 0; guard < 8 && vc.isBeingDismissed && vc.presentingViewController; guard++) {
        vc = vc.presentingViewController;
    }
    return vc;
}

// Relance requise pour qu'Instagram recharge prefs / cookies / empreinte
// ET relise AppleLanguages (la locale est figee par NSBundle au lancement).
static void NWAskRelaunchAfter(NSTimeInterval delay, NSString *raison);

// Une tentative : si une vue est presentee / en cours d'animation, on RETENTE
// quelques fois au lieu d'abandonner silencieusement (ca empechait le
// "Restart required" apres le choix d'une langue ou d'un pays).
static void NWAskRelaunchTry(NSString *raison, int n) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIViewController *top = NWTopVC();
    if (top.presentedViewController || top.isBeingDismissed || top.isBeingPresented) {
        if (n < 6) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ NWAskRelaunchTry(raison, n + 1); });
        } else {
            NWLog("relance proposee: une vue reste occupee (abandon)");
        }
        return;
    }
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Restart required"
        message:[NSString stringWithFormat:@"%@ needs to restart to apply this change.", raison]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        exit(0);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

static void NWAskRelaunchAfter(NSTimeInterval delay, NSString *raison) {
    if (delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NWAskRelaunchTry(raison, 0); });
    } else {
        NWAskRelaunchTry(raison, 0);
    }
}

static void NWAskRelaunch(NSString *raison) {
    NWAskRelaunchAfter(0, raison);
}

// Demande de relance un peu plus tard : laisse la feuille / l'alerte de choix
// se terminer de se fermer avant de proposer "Restart required".
static void NWAskRelaunchLater(NSString *raison) {
    NWAskRelaunchAfter(0.7, raison);
}

// Fenetre overlay persistante (geree plus bas)

@interface NWPassthroughView : UIView @end
@implementation NWPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;   // les zones vides laissent passer le toucher
}
@end

@interface NWOverlayVC : UIViewController @end
@implementation NWOverlayVC
- (void)loadView {
    self.view = [[NWPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}
@end

@interface NWOverlayUIWindow : UIWindow @end
@implementation NWOverlayUIWindow

// La fenetre overlay ne doit JAMAIS intercepter un toucher qui ne vise pas
// le bouton flottant. Sans ca, la moindre vue restante (alerte, dashboard)
// bloquerait tous les boutons d'Instagram (login, inscription, etc.).
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (!v || v == self) return nil;
    // Seul le bouton flottant (sous-vue de la racine) doit recevoir le toucher.
    if (v == self.rootViewController.view) return nil;
    return v;
}

// Jamais la fenetre principale : Instagram doit rester key window
// (sinon clavier / first responder / animations casses).
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFirstResponder { return NO; }

@end

static UIWindowScene *NWForegroundScene(void) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *fallback = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)s;
            if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
            if (!fallback) fallback = ws;
        }
        return fallback;
    }
    return nil;
}

static UIView *NWRootView(void) {
    if (!NWOverlayRoot) return nil;
    [NWOverlayRoot loadViewIfNeeded];
    return NWOverlayRoot.view;
}

// Cree (ou recree) la fenetre overlay au-dessus d'Instagram.
static void NWEnsureOverlay(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NWEnsureOverlay(); });
        return;
    }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    if (!NWOverlayRoot) NWOverlayRoot = [[NWOverlayVC alloc] init];

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = NWForegroundScene();
        if (!scene) return;
        if (NWOverlayWindow && NWOverlayWindow.windowScene == scene && !NWOverlayWindow.hidden) return;
        NWOverlayUIWindow *win = [[NWOverlayUIWindow alloc] initWithWindowScene:scene];
        win.frame = scene.coordinateSpace.bounds;
        win.windowLevel = UIWindowLevelAlert + 10.0;
        win.backgroundColor = [UIColor clearColor];
        win.rootViewController = NWOverlayRoot;
        win.hidden = NO;
        NWOverlayWindow = win;
    } else {
        if (NWOverlayWindow && !NWOverlayWindow.hidden) return;
        NWOverlayWindow = [[NWOverlayUIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        NWOverlayWindow.windowLevel = UIWindowLevelAlert + 10.0;
        NWOverlayWindow.backgroundColor = [UIColor clearColor];
        NWOverlayWindow.rootViewController = NWOverlayRoot;
        NWOverlayWindow.hidden = NO;
    }
    if (NWMenuButton && NWOverlayRoot.view && NWMenuButton.superview != NWOverlayRoot.view) {
        [NWOverlayRoot.view addSubview:NWMenuButton];
    }
    NWLog("overlay window installee (niveau alert+10)");
}

// ---------------------------------------------------------------------------
// Bouton flottant (draggable, design Blaze)
// ---------------------------------------------------------------------------

static void NWTogglePanel(void);   // declare avant NWFloatingButton

@interface NWFloatingButton : UIButton
@property (nonatomic, assign) CGPoint touchStart;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL touched;   // doigt en cours (glisser ou non)
@end

@implementation NWFloatingButton

// Feedback tactile (emil-design-eng : petites states en 120-180ms, ease-out).
- (void)pressIn {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.transform = CGAffineTransformMakeScale(0.94, 0.94); }
                     completion:nil];
}
- (void)pressOut {
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.transform = CGAffineTransformIdentity; }
                     completion:nil];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.touchStart = [touches.anyObject locationInView:self.superview];
    self.dragging = NO;
    self.touched = YES;
    [self pressIn];
    [super touchesBegan:touches withEvent:event];
}

// Persiste la position courante (fichier etat). Le timer de 2 s relit cet
// etat : si on ne l'ecrit pas a chaque glisser, le bouton revient au milieu.
- (void)nwSavePosition {
    UIView *v = self.superview;
    if (!v) return;
    CGSize sz = self.bounds.size;
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *ui = [st[@"ui"] mutableCopy] ?: [NSMutableDictionary dictionary];
    ui[@"x"] = @(self.center.x - sz.width / 2.0);
    ui[@"y"] = @(self.center.y - sz.height / 2.0);
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"ui"] = ui;
    NWSaveState(newSt);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self.superview];
    CGFloat dx = p.x - self.touchStart.x, dy = p.y - self.touchStart.y;
    if (!self.dragging && (fabs(dx) > 4 || fabs(dy) > 4)) self.dragging = YES;
    if (self.dragging) {
        UIView *v = self.superview;
        CGSize sz = self.bounds.size;
        CGPoint c = self.center;
        c.x += dx; c.y += dy;
        // Menage tres large : le bouton peut aller partout, y compris dans
        // les coins, mais il reste dans la fenetre (sinon le toucher est
        // annule par le systeme et la position est perdue).
        c.x = MIN(MAX(c.x, sz.width / 2.0 + 6),
                  v.bounds.size.width - sz.width / 2.0 - 6);
        c.y = MIN(MAX(c.y, sz.height / 2.0 + 18),
                  v.bounds.size.height - sz.height / 2.0 - 8);
        self.center = c;
        self.touchStart = p;

        // Ecriture filtree (au plus 4 fois par seconde : evite un disque a
        // chaque pointe de doigt tout en gardant la position en memoire).
        static CFTimeInterval lastSave = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastSave > 0.25) { lastSave = now; [self nwSavePosition]; }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.touched = NO;
    if (!self.dragging) {
        [self pressOut];
        NWTogglePanel();
        return;
    }
    // On garde EXACTEMENT l'endroit ou on a lache (pas de rabattement sur
    // un bord ni vers le centre) : "placer le bouton n'importe ou".
    UIView *v = self.superview;
    CGSize sz = self.bounds.size;
    CGPoint target = self.center;
    target.x = MIN(MAX(target.x, sz.width / 2.0 + 6),
                   v.bounds.size.width - sz.width / 2.0 - 6);
    target.y = MIN(MAX(target.y, sz.height / 2.0 + 18),
                   v.bounds.size.height - sz.height / 2.0 - 8);
    // ease-in-out (mouvement dans la vue) + retour a l'echelle 1.
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.center = target;
    } completion:nil];
    [self nwSavePosition];
    NWPersistState();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    // Le systeme annule le toucher (doigt dans la barre d'etat / geste
    // systeme). On garde la position atteinte : sinon le timer de 2 s
    // remettait le bouton a l'ancienne place = "il revient au milieu".
    BOOL wasDragging = self.dragging;
    self.dragging = NO;
    self.touched = NO;
    [self pressOut];
    if (wasDragging) {
        [self nwSavePosition];
        NWPersistState();
    }
}

@end

static void NWInstallFloatingButton(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NWInstallFloatingButton(); });
        return;
    }
    NWEnsureOverlay();
    UIView *root = NWRootView();
    if (!root) return;

    if (!NWMenuButton) {
        // --- Bouton flottant refait de zero : dimensions exactes et alignees ---
        // 56x56 partout (bouton = flou = rayon), icone 24x24 centree par UIKit
        // (aucun recalcul manuel de frame -> impossible de se decaler).
        NWFloatingButton *b = [NWFloatingButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 56, 56);
        b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
        b.layer.cornerRadius = 15;
        if (@available(iOS 13.0, *)) b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.borderWidth = 1.0;
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        b.layer.shadowColor = UIColor.blackColor.CGColor;
        b.layer.shadowOpacity = 0.50;
        b.layer.shadowRadius = 12;
        b.layer.shadowOffset = CGSizeMake(0, 4);
        [b setImage:NWGridIcon(30, [UIColor colorWithWhite:1 alpha:0.95]) forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeCenter;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        b.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        b.imageEdgeInsets = UIEdgeInsetsZero;
        // Flou exactement de la meme taille que le bouton.
        if (@available(iOS 13.0, *)) {
            UIVisualEffectView *blur = [[UIVisualEffectView alloc]
                initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
            blur.frame = CGRectMake(0, 0, 56, 56);
            blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blur.layer.cornerRadius = 15;
            blur.clipsToBounds = YES;
            blur.userInteractionEnabled = NO;
            [b addSubview:blur];
            [b sendSubviewToBack:blur];
        }
        b.accessibilityLabel = @"Menu nine9wham";
        NWMenuButton = b;
    }

    // Ajout au besoin AVANT toute garde : le bouton doit toujours etre present.
    if (NWMenuButton.superview != root) [root addSubview:NWMenuButton];

    // Ne JAMAIS repositionner pendant un glisser, pendant une animation ou
    // tant que le doigt est sur le bouton : le timer de 2 s remettait le
    // bouton a sa position sauvegardee en plein drag (retour au milieu).
    if (((NWFloatingButton *)NWMenuButton).dragging) return;
    if (((NWFloatingButton *)NWMenuButton).touched) return;
    if (NWMenuButton.layer.animationKeys.count > 0) return;

    NSDictionary *ui = (NWState ?: @{})[@"ui"];
    NSNumber *ux = [ui[@"x"] isKindOfClass:[NSNumber class]] ? ui[@"x"] : nil;
    NSNumber *uy = [ui[@"y"] isKindOfClass:[NSNumber class]] ? ui[@"y"] : nil;
    CGSize s = root.bounds.size;
    // Position par defaut : centre horizontalement, en bas, au-dessus du footer.
    CGFloat x = ux ? ux.doubleValue : (s.width / 2.0 - 28);
    CGFloat y = uy ? uy.doubleValue : (s.height - 56 - 96);
    // Limites larges : coins de l'ecran accessibles (meme marges que le drag).
    x = MAX(6, MIN(x, s.width - 56 - 6));
    y = MAX(18, MIN(y, s.height - 56 - 8));
    NWMenuButton.frame = CGRectMake(x, y, 56, 56);
    NWLog("bouton flottant installe (%.0f, %.0f)", x, y);

    // Pill "Device identity" (vague 7) : petit bouton flottant complementaire,
    // visible tant que l'app est ouverte (sauf safe-mode / masquage).
    NWEnsureDevPill(root);
}

// ---------------------------------------------------------------------------
// Pill "Device identity" (vague 7) — bouton flottant en haut a droite qui
// ouvre le module Device identity. Visible par defaut ; masquable via le
// module ("Hide button until relaunch" = one-shot consomme au boot) ou via
// le safe-mode.
// ---------------------------------------------------------------------------
static UIButton *NWDevicePillButton = nil;
static UIVisualEffectView *NWDevicePillBlur = nil;

static BOOL NWDevPillEnabled(void) {
    @try {
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:NWDevKeyPill];
        if (v == nil) return YES;    // defaut : le pill est visible
        return [v boolValue];
    } @catch (NSException *e) { return YES; }
}

// Vague 10 : le pill "Device identity" est DEPLACABLE (meme geste que le
// bouton principal). Sa position est conservee dans l'etat (ui.devX/devY),
// donc elle survit aux relances et au timer de 2 s qui rafraichit l'overlay.
@interface NWDevPillView : UIButton
@property (nonatomic, assign) CGPoint touchStart;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation NWDevPillView

- (void)nwSavePosition {
    UIView *v = self.superview;
    if (!v) return;
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *ui = [st[@"ui"] mutableCopy] ?: [NSMutableDictionary dictionary];
    ui[@"devX"] = @(CGRectGetMinX(self.frame));
    ui[@"devY"] = @(CGRectGetMinY(self.frame));
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"ui"] = ui;
    NWSaveState(newSt);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.touchStart = [touches.anyObject locationInView:self.superview];
    self.dragging = NO;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.transform = CGAffineTransformMakeScale(0.96, 0.96); }
                     completion:nil];
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self.superview];
    CGFloat dx = p.x - self.touchStart.x, dy = p.y - self.touchStart.y;
    if (!self.dragging && (fabs(dx) > 4 || fabs(dy) > 4)) self.dragging = YES;
    if (self.dragging) {
        UIView *v = self.superview;
        CGSize sz = self.bounds.size;
        CGPoint c = self.center;
        c.x += dx; c.y += dy;
        c.x = MIN(MAX(c.x, sz.width / 2.0 + 6),
                  v.bounds.size.width - sz.width / 2.0 - 6);
        c.y = MIN(MAX(c.y, sz.height / 2.0 + 18),
                  v.bounds.size.height - sz.height / 2.0 - 8);
        self.center = c;
        self.touchStart = p;
        static CFTimeInterval lastSave = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastSave > 0.25) { lastSave = now; [self nwSavePosition]; }
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    BOOL wasDragging = self.dragging;
    self.dragging = NO;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.transform = CGAffineTransformIdentity; }
                     completion:nil];
    if (!wasDragging) {
        if (self.onTap) self.onTap();
        return;
    }
    [self nwSavePosition];
    NWPersistState();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    BOOL wasDragging = self.dragging;
    self.dragging = NO;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.transform = CGAffineTransformIdentity; }
                     completion:nil];
    if (wasDragging) { [self nwSavePosition]; NWPersistState(); }
}

@end

static void NWEnsureDevPill(UIView *root) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NWEnsureDevPill(root); });
        return;
    }
    if (NWSafeModeOn() || NWDevPillHiddenNow || !NWDevPillEnabled()) {
        NWDevicePillButton.hidden = YES;
        return;
    }
    if (!NWDevicePillButton) {
        NWDevPillView *b = [NWDevPillView buttonWithType:UIButtonTypeSystem];
        [b setTitle:NWL(@"dev_pill", @"Device identity", @"Identite", @"Identidad")
          forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        // Noir translucide, meme famille visuelle que le bouton flottant
        // principal (flou sombre + voile noir).
        b.frame = CGRectMake(0, 0, 120, 28);
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
        b.layer.cornerRadius = 14;
        if (@available(iOS 13.0, *)) b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.borderWidth = 1.0;
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        b.layer.shadowColor = UIColor.blackColor.CGColor;
        b.layer.shadowOpacity = 0.45;
        b.layer.shadowRadius = 10;
        b.layer.shadowOffset = CGSizeMake(0, 3);
        if (@available(iOS 13.0, *)) {
            UIVisualEffectView *blur = [[UIVisualEffectView alloc]
                initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
            blur.frame = b.bounds;
            blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blur.layer.cornerRadius = 14;
            blur.clipsToBounds = YES;
            blur.userInteractionEnabled = NO;
            [b addSubview:blur];
            [b sendSubviewToBack:blur];
            NWDevicePillBlur = blur;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Meme empreinte que l'autre bouton : warning deprecation deja
        // present ailleurs, on n'ajoute pas un 14e warning a la CI.
        b.contentEdgeInsets = UIEdgeInsetsMake(5, 12, 5, 12);
#pragma clang diagnostic pop
        b.accessibilityLabel = @"Device identity";
        b.onTap = ^{ NWOpenDeviceIdentity(); };
        NWDevicePillButton = b;
    }
    if (NWDevicePillButton.superview != root) [root addSubview:NWDevicePillButton];
    NWDevicePillButton.hidden = NO;
    // Ne jamais re-positionner pendant un glisser : le timer de 2 s remettrait
    // le bouton a son ancienne place en plein deplacement.
    if (((NWDevPillView *)NWDevicePillButton).dragging) return;
    CGSize s = root.bounds.size;
    CGSize fit = [NWDevicePillButton sizeThatFits:CGSizeMake(CGFLOAT_MAX, 28)];
    CGFloat w = MAX(96.0, fit.width);
    CGFloat h = 28.0;
    NSDictionary *ui = (NWState ?: @{})[@"ui"];
    NSNumber *dx = [ui[@"devX"] isKindOfClass:[NSNumber class]] ? ui[@"devX"] : nil;
    NSNumber *dy = [ui[@"devY"] isKindOfClass:[NSNumber class]] ? ui[@"devY"] : nil;
    CGFloat x = dx ? dx.doubleValue : (s.width - w - 14);
    CGFloat y = dy ? dy.doubleValue : 54;
    x = MAX(6, MIN(x, s.width - w - 6));
    y = MAX(18, MIN(y, s.height - h - 8));
    NWDevicePillButton.frame = CGRectMake(x, y, w, h);
    if (NWDevicePillBlur) NWDevicePillBlur.frame = NWDevicePillButton.bounds;
}


// ---------------------------------------------------------------------------
// Composants UI (style Blaze : cartes, grille, listes, switches)
// ---------------------------------------------------------------------------

@interface NWGridCell : UIControl
@property (nonatomic, strong) UIView *tile;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
- (instancetype)initWithIcon:(NSString *)icon
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle
                        tint:(UIColor *)tint;
@end

@implementation NWGridCell

- (instancetype)initWithIcon:(NSString *)icon
                       title:(NSString *)title
                    subtitle:(NSString *)subtitle
                        tint:(UIColor *)tint {
    self = [super initWithFrame:CGRectMake(0, 0, 0, 0)];
    if (!self) return nil;
    self.backgroundColor = NWCardGlass();
    self.layer.cornerRadius = 20;
    self.layer.borderWidth = 1;
    self.layer.borderColor = NWLine().CGColor;

    _tile = [[UIView alloc] init];
    _tile.backgroundColor = [tint colorWithAlphaComponent:0.14];
    _tile.layer.cornerRadius = 10;
    _tile.userInteractionEnabled = NO;
    [self addSubview:_tile];

    _iconView = [[UIImageView alloc] initWithImage:NWSymbol(icon, 18)];
    _iconView.tintColor = tint;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [_tile addSubview:_iconView];

    _titleLabel = NWLabelMake(title, 14, UIColor.whiteColor, UIFontWeightSemibold);
    _titleLabel.numberOfLines = 2;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    _subLabel = NWLabelMake(subtitle, 10.5, NWDim(), UIFontWeightRegular);
    _subLabel.numberOfLines = 2;
    _subLabel.userInteractionEnabled = NO;
    [self addSubview:_subLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    BOOL hasSub = (_subLabel.text.length > 0);
    _tile.frame = CGRectMake(12, 12, 34, 34);
    _iconView.frame = CGRectMake(8, 8, 18, 18);
    if (hasSub) {
        _titleLabel.frame = CGRectMake(12, 52, w - 24, 36);
        _subLabel.frame = CGRectMake(12, 88, w - 24, 28);
        _subLabel.hidden = NO;
    } else {
        // GridCell Blaze : icone + titre seulement, titre centre sous l'icone.
        _titleLabel.frame = CGRectMake(10, 54, w - 20, h - 62);
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _subLabel.hidden = YES;
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.16 alpha:1];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.backgroundColor = NWCardGlass();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.backgroundColor = NWCardGlass();
}

@end

@interface NWRowView : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *chevronView;
- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title value:(NSString *)value;
@end

@implementation NWRowView

- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title value:(NSString *)value {
    self = [super initWithFrame:CGRectMake(0, 0, 0, 0)];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    _iconView = [[UIImageView alloc] initWithImage:NWSymbol(icon, 15)];
    _iconView.tintColor = NWAccent();
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _titleLabel = NWLabelMake(title, 14.5, UIColor.whiteColor, UIFontWeightRegular);
    _titleLabel.numberOfLines = 1;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    _valueLabel = NWLabelMake(value ?: @"", 12.5, NWDim(), UIFontWeightRegular);
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.numberOfLines = 1;
    _valueLabel.userInteractionEnabled = NO;
    [self addSubview:_valueLabel];

    _chevronView = [[UIImageView alloc] initWithImage:NWSymbol(@"chevron.right", 11)];
    _chevronView.tintColor = [UIColor colorWithWhite:1 alpha:0.3];
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    _chevronView.userInteractionEnabled = NO;
    [self addSubview:_chevronView];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _iconView.frame = CGRectMake(14, (h - 20) / 2.0, 20, 20);
    CGFloat right = _chevronView.hidden ? 14 : 28;
    CGFloat valueW = MIN(170, w * 0.46);
    _chevronView.frame = CGRectMake(w - 22, (h - 14) / 2.0, 14, 14);
    _valueLabel.frame = CGRectMake(w - right - valueW, 0, valueW, h);
    CGFloat titleW = w - 48 - right - valueW - 8;
    _titleLabel.frame = CGRectMake(48, 0, MAX(60, titleW), h);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.backgroundColor = UIColor.clearColor;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.backgroundColor = UIColor.clearColor;
}

@end

@interface NWSwitchRow : UIView
@property (nonatomic, strong) UIView *tile;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, copy) void (^onChange)(BOOL on);
- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title on:(BOOL)on;
- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title subtitle:(NSString *)subtitle on:(BOOL)on;
@end

@implementation NWSwitchRow

- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title on:(BOOL)on {
    return [self initWithIcon:icon title:title subtitle:nil on:on];
}

- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title subtitle:(NSString *)subtitle on:(BOOL)on {
    self = [super initWithFrame:CGRectMake(0, 0, 0, 0)];
    if (!self) return nil;

    // "Active" = VERT (Ghost / Localisation / Proxy), grise quand off.
    UIColor *live = NWGreen();

    // Tuile ronde derriere l'icone : fini le carre plat.
    _tile = [[UIView alloc] init];
    _tile.backgroundColor = [live colorWithAlphaComponent:on ? 0.20 : 0.08];
    _tile.layer.cornerRadius = 15;
    if (@available(iOS 13.0, *)) _tile.layer.cornerCurve = kCACornerCurveContinuous;
    _tile.userInteractionEnabled = NO;
    [self addSubview:_tile];

    _iconView = [[UIImageView alloc] initWithImage:NWSymbol(icon, 16)];
    _iconView.tintColor = on ? live : [UIColor colorWithWhite:1 alpha:0.35];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _titleLabel = NWLabelMake(title, 15, UIColor.whiteColor, UIFontWeightSemibold);
    _titleLabel.numberOfLines = 1;
    [self addSubview:_titleLabel];

    if (subtitle.length) {
        _subLabel = NWLabelMake(subtitle, 11, NWDim(), UIFontWeightRegular);
        _subLabel.numberOfLines = 1;
        [self addSubview:_subLabel];
    }

    _toggle = [[UISwitch alloc] init];
    _toggle.onTintColor = on ? live : [UIColor colorWithWhite:1 alpha:0.22];
    _toggle.tintColor = [UIColor colorWithWhite:1 alpha:0.20];
    _toggle.on = on;
    // Legere reduction : le switch standard reste trop massif a cote du texte.
    _toggle.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [self addSubview:_toggle];

    __weak typeof(self) weakSelf = self;
    NWBind(_toggle, ^(id sender) {
        BOOL nowOn = ((UISwitch *)sender).isOn;
        // Couleurs suivent l'etat immediatement (vert = active).
        weakSelf.iconView.tintColor = nowOn ? NWGreen() : [UIColor colorWithWhite:1 alpha:0.35];
        weakSelf.toggle.onTintColor = nowOn ? NWGreen() : [UIColor colorWithWhite:1 alpha:0.22];
        weakSelf.tile.backgroundColor = [NWGreen() colorWithAlphaComponent:nowOn ? 0.20 : 0.08];
        if (weakSelf.onChange) weakSelf.onChange(nowOn);
    });
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat textW = w - 54 - 14 - 58;
    // Tuile 30x30 + icone 16x16 parfaitement centrees dans la tuile.
    _tile.frame = CGRectMake(12, (h - 30) / 2.0, 30, 30);
    _iconView.frame = CGRectMake(12 + 7, (h - 16) / 2.0, 16, 16);
    _toggle.frame = CGRectMake(w - 14 - 51, (h - 31) / 2.0, 51, 31);
    if (_subLabel) {
        // SwitchListCell Blaze : titre + sous-titre empiles.
        _titleLabel.frame = CGRectMake(54, (h - 36) / 2.0, textW, 20);
        _subLabel.frame = CGRectMake(54, _titleLabel.frame.origin.y + 21, textW, 15);
    } else {
        _titleLabel.frame = CGRectMake(54, 0, textW, h);
    }
}

@end

// ---------------------------------------------------------------------------
// Selecteur generique (modeles, versions iOS, fuseaux, resultats Nominatim)
// ---------------------------------------------------------------------------

@interface NWOptionPickerVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *options;
@property (nonatomic, copy) NSString *selectedValue;
@property (nonatomic, copy) NSString *heading;
@property (nonatomic, copy) void (^onPick)(NSDictionary *option);
@end

@implementation NWOptionPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UIControl *dim = [[UIControl alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dim];

    UIView *sheet = [[UIView alloc] init];
    sheet.backgroundColor = [UIColor colorWithRed:0.063 green:0.063 blue:0.082 alpha:1];
    sheet.layer.cornerRadius = 22;
    sheet.layer.borderWidth = 1;
    sheet.layer.borderColor = NWLine().CGColor;
    sheet.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sheet];

    UILabel *title = NWLabelMake(self.heading ?: @"Choisir", 16, UIColor.whiteColor, UIFontWeightSemibold);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet addSubview:title];

    UIButton *close = NWIconButton(@"xmark", ^(id s){ [self closeSelf]; });
    [sheet addSubview:close];

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 0, 0) style:UITableViewStylePlain];
    table.backgroundColor = UIColor.clearColor;
    table.separatorColor = NWLine();
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 58;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet addSubview:table];

    CGFloat h = MIN(self.view.bounds.size.height * 0.72, 76 + self.options.count * 58.0);
    h = MAX(h, 220);
    [NSLayoutConstraint activateConstraints:@[
        [sheet.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [sheet.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [sheet.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [sheet.heightAnchor constraintEqualToConstant:h],
        [title.topAnchor constraintEqualToAnchor:sheet.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:18],
        [close.topAnchor constraintEqualToAnchor:sheet.topAnchor constant:12],
        [close.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-14],
        [table.topAnchor constraintEqualToAnchor:sheet.topAnchor constant:54],
        [table.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:6],
        [table.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-6],
        [table.bottomAnchor constraintEqualToAnchor:sheet.bottomAnchor constant:-8],
    ]];
}

- (void)closeSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.options.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"opt"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"opt"];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
        cell.detailTextLabel.textColor = NWDim();
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        cell.tintColor = NWGreen();
        // Option selectionnee : pastille arrondie (pas de carre plat).
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [NWGreen() colorWithAlphaComponent:0.16];
        sel.layer.cornerRadius = 12;
        if (@available(iOS 13.0, *)) sel.layer.cornerCurve = kCACornerCurveContinuous;
        cell.selectedBackgroundView = sel;
    }
    NSDictionary *opt = self.options[indexPath.row];
    cell.textLabel.text = opt[@"title"];
    cell.detailTextLabel.text = opt[@"subtitle"];
    BOOL selected = self.selectedValue.length && [opt[@"value"] isEqual:self.selectedValue];
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *opt = self.options[indexPath.row];
    [self closeSelf];
    if (self.onPick) self.onPick(opt);
}

@end

// ---------------------------------------------------------------------------
// Feuille "New Container" (copy Blaze : Container Name + Enable Spoof + Create)
// ---------------------------------------------------------------------------
@interface NWNewContainerSheet : UIViewController
@property (nonatomic, copy) void (^onCreate)(NSString *name, NSDictionary *locOpt, BOOL ghostOn);
@property (nonatomic, copy) NSDictionary *initialLoc;   // position deja choisie sur la carte
@end

@implementation NWNewContainerSheet {
    UITextField *_field;
    UISwitch *_ghostSwitch;
    UILabel *_locValue;
    NSDictionary *_loc;
    UIButton *_create;
    NSLayoutConstraint *_cardBottom;
    UIView *_cardView;
    CGFloat _kbOverlap;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIControl *dim = [[UIControl alloc] initWithFrame:CGRectZero];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [dim addTarget:self action:@selector(dimTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dim];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithRed:0.063 green:0.063 blue:0.082 alpha:1];
    card.layer.cornerRadius = 22;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NWLine().CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    // --- Entete : "New Container" + fermeture ---
    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    UILabel *title = NWLabelMake(@"New Container", 17, UIColor.whiteColor, UIFontWeightBold);
    __weak typeof(self) weakSelf = self;
    UIButton *close = NWIconButton(@"xmark", ^(id s){ [weakSelf closeSelf]; });
    [header addArrangedSubview:title];
    [header addArrangedSubview:NWSpacer()];
    [header addArrangedSubview:close];
    [stack addArrangedSubview:header];

    // --- Container Name ---
    [stack addArrangedSubview:NWLabelMake(@"Container Name", 12, NWDim(), UIFontWeightMedium)];

    UIView *fieldBox = [[UIView alloc] init];
    fieldBox.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    fieldBox.layer.cornerRadius = 14;
    fieldBox.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldBox.heightAnchor constraintEqualToConstant:52].active = YES;

    UIImageView *folder = [[UIImageView alloc] initWithImage:NWSymbol(@"folder.fill", 16)];
    folder.tintColor = NWAccent();
    folder.contentMode = UIViewContentModeScaleAspectFit;
    folder.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldBox addSubview:folder];

    _field = [[UITextField alloc] init];
    _field.textColor = UIColor.whiteColor;
    _field.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _field.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Enter container name..."
            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4]}];
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldBox addSubview:_field];

    [NSLayoutConstraint activateConstraints:@[
        [folder.leadingAnchor constraintEqualToAnchor:fieldBox.leadingAnchor constant:14],
        [folder.centerYAnchor constraintEqualToAnchor:fieldBox.centerYAnchor],
        [folder.widthAnchor constraintEqualToConstant:20],
        [folder.heightAnchor constraintEqualToConstant:20],
        [_field.leadingAnchor constraintEqualToAnchor:folder.trailingAnchor constant:10],
        [_field.trailingAnchor constraintEqualToAnchor:fieldBox.trailingAnchor constant:-14],
        [_field.centerYAnchor constraintEqualToAnchor:fieldBox.centerYAnchor],
    ]];
    [stack addArrangedSubview:fieldBox];

    // --- Enable Spoof / Random data with Ghost? ---
    NWSwitchRow *ghostRow = [[NWSwitchRow alloc] initWithIcon:@"shield.lefthalf.filled"
                                                        title:@"Enable Spoof"
                                                    subtitle:@"Random data with Ghost?"
                                                          on:YES];
    ghostRow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    ghostRow.layer.cornerRadius = 18;
    if (@available(iOS 13.0, *)) ghostRow.layer.cornerCurve = kCACornerCurveContinuous;
    ghostRow.translatesAutoresizingMaskIntoConstraints = NO;
    [ghostRow.heightAnchor constraintEqualToConstant:64].active = YES;
    [stack addArrangedSubview:ghostRow];
    _ghostSwitch = ghostRow.toggle;

    // --- Spoof Location (carte du monde) ---
    UIControl *locRow = [[UIControl alloc] init];
    locRow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    locRow.layer.cornerRadius = 14;
    locRow.translatesAutoresizingMaskIntoConstraints = NO;
    [locRow.heightAnchor constraintEqualToConstant:52].active = YES;

    UIImageView *pin = [[UIImageView alloc] initWithImage:NWSymbol(@"location.fill", 16)];
    pin.tintColor = NWGreen();
    pin.contentMode = UIViewContentModeScaleAspectFit;
    pin.translatesAutoresizingMaskIntoConstraints = NO;
    [locRow addSubview:pin];

    UILabel *locTitle = NWLabelMake(@"Spoof Location", 14.5, UIColor.whiteColor, UIFontWeightMedium);
    locTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [locRow addSubview:locTitle];

    _locValue = NWLabelMake(@"Set Location", 12.5, NWDim(), UIFontWeightRegular);
    _locValue.textAlignment = NSTextAlignmentRight;
    _locValue.translatesAutoresizingMaskIntoConstraints = NO;
    [locRow addSubview:_locValue];
    if ([self.initialLoc isKindOfClass:[NSDictionary class]]) {
        _loc = self.initialLoc;
        NSString *lb = _loc[@"label"];
        _locValue.text = [lb isKindOfClass:[NSString class]] && lb.length ? lb : @"Set Location";
    }

    UIImageView *chev = [[UIImageView alloc] initWithImage:NWSymbol(@"chevron.right", 13)];
    chev.tintColor = NWDim();
    chev.contentMode = UIViewContentModeScaleAspectFit;
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    [locRow addSubview:chev];

    [NSLayoutConstraint activateConstraints:@[
        [pin.leadingAnchor constraintEqualToAnchor:locRow.leadingAnchor constant:14],
        [pin.centerYAnchor constraintEqualToAnchor:locRow.centerYAnchor],
        [pin.widthAnchor constraintEqualToConstant:20],
        [pin.heightAnchor constraintEqualToConstant:20],
        [locTitle.leadingAnchor constraintEqualToAnchor:pin.trailingAnchor constant:10],
        [locTitle.centerYAnchor constraintEqualToAnchor:locRow.centerYAnchor],
        [chev.trailingAnchor constraintEqualToAnchor:locRow.trailingAnchor constant:-14],
        [chev.centerYAnchor constraintEqualToAnchor:locRow.centerYAnchor],
        [chev.widthAnchor constraintEqualToConstant:14],
        [chev.heightAnchor constraintEqualToConstant:16],
        [_locValue.trailingAnchor constraintEqualToAnchor:chev.leadingAnchor constant:-8],
        [_locValue.centerYAnchor constraintEqualToAnchor:locRow.centerYAnchor],
        [locTitle.trailingAnchor constraintLessThanOrEqualToAnchor:_locValue.leadingAnchor constant:-8],
    ]];

    NWBind(locRow, ^(id s){
        __strong typeof(weakSelf) sheet = weakSelf;
        if (!sheet) return;
        CLLocationCoordinate2D initial = CLLocationCoordinate2DMake(48.8566, 2.3522);
        if (sheet->_loc) {
            initial = CLLocationCoordinate2DMake([sheet->_loc[@"lat"] doubleValue],
                                                 [sheet->_loc[@"lon"] doubleValue]);
        }
        NWOpenMapPicker(sheet, initial, ^(double lat, double lon, NSString *label) {
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            s2->_loc = @{@"on": @YES, @"lat": @(lat), @"lon": @(lon),
                         @"label": label.length ? label : @"Current Location"};
            s2->_locValue.text = label.length ? label : @"Set Location";
        });
    });
    [stack addArrangedSubview:locRow];

    // --- Create (rayon 27.5 comme Blaze) : inactif tant que le nom est vide ---
    UIButton *create = [UIButton buttonWithType:UIButtonTypeSystem];
    [create setTitle:@"Create" forState:UIControlStateNormal];
    create.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    create.backgroundColor = NWAccent();
    create.layer.cornerRadius = 27.5;
    if (@available(iOS 13.0, *)) create.layer.cornerCurve = kCACornerCurveContinuous;
    create.translatesAutoresizingMaskIntoConstraints = NO;
    [create.heightAnchor constraintEqualToConstant:55].active = YES;
    create.enabled = NO;
    create.alpha = 0.55;
    [create setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [create setTitleColor:[UIColor colorWithWhite:1 alpha:0.40] forState:UIControlStateDisabled];
    NWBind(create, ^(id s){ [weakSelf doCreate]; });
    [stack addArrangedSubview:create];
    _create = create;
    [_field addTarget:self action:@selector(nameChanged:)
     forControlEvents:UIControlEventEditingChanged];

    [NSLayoutConstraint activateConstraints:@[
        [dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    // Evitement clavier (copy Blaze : keyboardWillShow / keyboardWillHide).
    // Sans ca, le clavier recouvre le bouton Create.
    _cardBottom = [card.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    _cardBottom.active = YES;
    _cardView = card;
    _kbOverlap = 0;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardFrame:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Premier tap sur le fond : on ferme le clavier (le 2e tap ferme la feuille),
// comme dans Blaze (contentViewLostFocus).
- (void)dimTapped {
    if (_field.isFirstResponder) {
        [_field resignFirstResponder];
        return;
    }
    [self closeSelf];
}

// Copy Blaze (textFieldDidChange:) : Create inactif tant que le nom est vide.
- (void)nameChanged:(UITextField *)tf {
    NSString *t = [tf.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL ok = t.length > 0;
    _create.enabled = ok;
    _create.alpha = ok ? 1.0 : 0.55;
    _create.backgroundColor = ok ? NWAccent() : [UIColor colorWithWhite:1 alpha:0.12];
}

// Recadre la carte au-dessus du clavier (affichage / masquage / retour clavier).
- (void)keyboardFrame:(NSNotification *)note {
    [self.view layoutIfNeeded];   // garantit une hauteur de carte valide
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endInView = [self.view convertRect:end fromView:nil];
    CGFloat overlap = self.view.bounds.size.height - endInView.origin.y;
    if (overlap < 0) overlap = 0;
    if (_cardBottom) {
        // Ne jamais faire remonter la carte au-dela de son propre haut.
        CGFloat cardH = _cardView ? _cardView.bounds.size.height : 0;
        CGFloat maxLift = self.view.bounds.size.height - cardH - 8;
        if (maxLift < 0) maxLift = 0;
        if (overlap > maxLift) overlap = maxLift;
        _cardBottom.constant = -overlap;
    }
    NSTimeInterval dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    if (dur <= 0) dur = 0.25;
    UIViewAnimationCurve curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [UIView animateWithDuration:dur
                          delay:0
                        options:(UIViewAnimationOptions)(curve << 16)
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:nil];
}

- (void)openMap {
    __weak typeof(self) weakSelf = self;
    CLLocationCoordinate2D initial = CLLocationCoordinate2DMake(48.8566, 2.3522);
    if (_loc) initial = CLLocationCoordinate2DMake([_loc[@"lat"] doubleValue], [_loc[@"lon"] doubleValue]);
    NWOpenMapPicker(self, initial, ^(double lat, double lon, NSString *label) {
        __strong typeof(weakSelf) sheet = weakSelf;
        if (!sheet) return;
        sheet->_loc = @{@"on": @YES, @"lat": @(lat), @"lon": @(lon),
                        @"label": label.length ? label : @"Current Location"};
        sheet->_locValue.text = label.length ? label : @"Set Location";
    });
}

- (void)doCreate {
    NSString *name = [_field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL ghost = _ghostSwitch.isOn;
    NSDictionary *loc = _loc;
    void (^cb)(NSString *, NSDictionary *, BOOL) = self.onCreate;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(name.length ? name : nil, loc, ghost);
    }];
}

- (void)closeSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// Cellule "container" (copy Blaze : dossier + nom + icones Ghost/Orbit/Proxy)
// Blaze : hauteur 70, bordure accent 1.3 si active, 4 iconees a droite.
// ---------------------------------------------------------------------------
@interface NWContainerCellView : UIControl
+ (UIButton *)iconButton:(NSString *)sym;
@property (nonatomic, strong) UIImageView *folderView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIButton *ghostBtn;
@property (nonatomic, strong) UIButton *locBtn;
@property (nonatomic, strong) UIButton *proxyBtn;
@property (nonatomic, strong) UIButton *moreBtn;
@property (nonatomic, copy) void (^onGhost)(void);
@property (nonatomic, copy) void (^onLocation)(void);
@property (nonatomic, copy) void (^onProxy)(void);
@property (nonatomic, copy) void (^onMore)(void);
@end

@implementation NWContainerCellView

+ (UIButton *)iconButton:(NSString *)sym {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:NWSymbol(sym, 16) forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
    b.imageView.contentMode = UIViewContentModeScaleAspectFit;
    b.accessibilityLabel = sym;
    return b;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = NWCardGlass();
    self.layer.cornerRadius = 20;
    self.layer.borderWidth = 1;
    self.layer.borderColor = NWLine().CGColor;

    _folderView = [[UIImageView alloc] initWithImage:NWSymbol(@"folder.fill", 18)];
    _folderView.contentMode = UIViewContentModeScaleAspectFit;
    _folderView.tintColor = NWDim();
    [self addSubview:_folderView];

    _titleLabel = NWLabelMake(@"", 15, UIColor.whiteColor, UIFontWeightSemibold);
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLabel];

    _subLabel = NWLabelMake(@"", 11, NWDim(), UIFontWeightRegular);
    _subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_subLabel];

    _ghostBtn  = [NWContainerCellView iconButton:@"shield.lefthalf.filled"];
    _locBtn    = [NWContainerCellView iconButton:@"location.fill"];
    _proxyBtn  = [NWContainerCellView iconButton:@"network"];
    _moreBtn   = [NWContainerCellView iconButton:@"ellipsis"];
    [self addSubview:_ghostBtn];
    [self addSubview:_locBtn];
    [self addSubview:_proxyBtn];
    [self addSubview:_moreBtn];

    __weak typeof(self) weakSelf = self;
    NWBind(_ghostBtn, ^(id s){
        __strong typeof(weakSelf) c = weakSelf;
        if (c.onGhost) c.onGhost();
    });
    NWBind(_locBtn, ^(id s){
        __strong typeof(weakSelf) c = weakSelf;
        if (c.onLocation) c.onLocation();
    });
    NWBind(_proxyBtn, ^(id s){
        __strong typeof(weakSelf) c = weakSelf;
        if (c.onProxy) c.onProxy();
    });
    NWBind(_moreBtn, ^(id s){
        __strong typeof(weakSelf) c = weakSelf;
        if (c.onMore) c.onMore();
    });
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    CGFloat pad = 14;
    CGFloat btnW = 34, gap = 2;
    CGFloat iconsW = 4 * btnW + 3 * gap;
    CGFloat iconsX = w - pad - iconsW;
    CGFloat by = (h - btnW) / 2;
    _ghostBtn.frame = CGRectMake(iconsX, by, btnW, btnW);
    _locBtn.frame   = CGRectMake(iconsX + (btnW + gap), by, btnW, btnW);
    _proxyBtn.frame = CGRectMake(iconsX + 2 * (btnW + gap), by, btnW, btnW);
    _moreBtn.frame  = CGRectMake(iconsX + 3 * (btnW + gap), by, btnW, btnW);

    _folderView.frame = CGRectMake(pad, (h - 22) / 2, 22, 22);

    CGFloat textX = pad + 22 + 10;
    CGFloat textW = iconsX - 10 - textX;
    if (textW < 60) textW = 60;
    CGFloat titleH = 18, subH = 14;
    CGFloat top = (h - (titleH + 2 + subH)) / 2;
    _titleLabel.frame = CGRectMake(textX, top, textW, titleH);
    _subLabel.frame = CGRectMake(textX, top + titleH + 2, textW, subH);
}

@end

// ---------------------------------------------------------------------------
// Dashboard principal
// ---------------------------------------------------------------------------

@interface NWDashboardViewController : UIViewController
@property (nonatomic, copy) NSString *module;
@property (nonatomic, strong) UIStackView *bar;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *content;
@property (nonatomic, strong) UIView *footer;
@property (nonatomic, strong) NSLayoutConstraint *contentBottom;
@end

@implementation NWDashboardViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Fond TRANSLUCIDE : flou sombre sur le contenu d'Instagram derriere.
    self.view.backgroundColor = UIColor.clearColor;
    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    backdrop.frame = self.view.bounds;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.userInteractionEnabled = NO;
    [self.view addSubview:backdrop];

    _bar = [[UIStackView alloc] init];
    _bar.axis = UILayoutConstraintAxisHorizontal;
    _bar.alignment = UIStackViewAlignmentCenter;
    _bar.spacing = 10;
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_bar];

    _scroll = [[UIScrollView alloc] init];
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];

    _content = [[UIStackView alloc] init];
    _content.axis = UILayoutConstraintAxisVertical;
    _content.spacing = 14;
    _content.alignment = UIStackViewAlignmentFill;
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_content];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _contentBottom = [_content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-28];
    [NSLayoutConstraint activateConstraints:@[
        [_bar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [_bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],
        [_bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],
        [_bar.heightAnchor constraintEqualToConstant:52],
        [_scroll.topAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:2],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:10],
        [_content.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:14],
        [_content.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-14],
        _contentBottom,
        [_content.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-28],
    ]];

    // Pied de page flottant "New Container" (copy Blaze : + etiquette centree,
    // 55 pt du bas). Vue passeuse : seule la zone du bouton capte le toucher.
    NWPassthroughView *footer = [[NWPassthroughView alloc] initWithFrame:CGRectZero];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.backgroundColor = UIColor.clearColor;
    footer.hidden = YES;
    [self.view addSubview:footer];
    _footer = footer;
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:140],
    ]];

    [self rebuild];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (NWDashInstance == self) NWDashInstance = nil;
}

- (void)rebuild {
    // Normalisation : on est TOUJOURS sur Containers (landing) ou un module.
    // L'ancien menu principal (grille Ghost/Orbit) n'est plus jamais construit.
    if (!self.module.length) self.module = @"containers";

    // TOUTES les sous-vues (pas seulement les arranged) : les vues ajoutees
    // hors stack s'accumulaient a chaque rebuild et le logo/@ partaient de travers.
    for (UIView *v in [self.bar.subviews copy]) {
        if ([self.bar.arrangedSubviews containsObject:v]) [self.bar removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (UIView *v in [self.content.arrangedSubviews copy]) {
        [self.content removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    [self buildTopBar];

    // Pied de page "New Container" : uniquement sur l'ecran Containers.
    BOOL isContainers = [self.module isEqualToString:@"containers"];
    self.footer.hidden = !isContainers;
    for (UIView *v in [self.footer.subviews copy]) [v removeFromSuperview];
    self.contentBottom.constant = isContainers ? -170 : -28;
    if (isContainers) [self buildContainersFooter];
    // Landing : Containers. L'ancien menu (grille Ghost/Orbit/Proxy) est supprime,
    // il ne doit plus etre affiche dans aucun cas.
    if (!self.module || [self.module isEqualToString:@"containers"]) {
        [self buildContainers];
    } else if ([self.module isEqualToString:@"device"] ||
               [self.module isEqualToString:@"about"]) {
        [self buildDevice];
    } else if ([self.module isEqualToString:@"location"]) {
        [self buildLocation];
    } else if ([self.module isEqualToString:@"ghost"]) {
        [self buildGhost];
    } else if ([self.module isEqualToString:@"proxy"]) {
        [self buildProxy];
    } else if ([self.module isEqualToString:@"changelog"]) {
        [self buildChangelog];
    } else if ([self.module isEqualToString:@"support"]) {
        [self buildSupport];
    } else if ([self.module isEqualToString:@"deviceid"]) {
        [self buildDeviceIdentity];
    } else if ([self.module isEqualToString:@"reset"]) {
        [self buildReset];
    }
}

- (NSString *)moduleTitle {
    NSDictionary *titles = @{
        @"device": @"App & Device", @"about": @"About",
        @"location": @"Location Spoofer", @"orbit": @"Location Spoofer",
        @"ghost": @"Ghost", @"containers": @"Containers",
        @"proxy": @"Proxy", @"changelog": @"Changelog",
        @"support": @"Support", @"reset": @"Reset",
        @"deviceid": @"Device identity",
    };
    return titles[self.module] ?: @"nine9wham";
}

// Rotation CONTINUE du logo Telegram (CABasicAnimation : infinie, lineaire,
// ne consomme pas de recursion et ne bloque pas le thread principal).
static void NWStartSpin(UIImageView *v) {
    if (!v) return;
    [v.layer removeAllAnimations];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0.0;
    spin.toValue = @(M_PI * 2.0);
    spin.duration = 1.6;
    spin.repeatCount = HUGE_VALF;
    spin.removedOnCompletion = NO;
    spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [v.layer addAnimation:spin forKey:@"nw.telegram.spin"];
}

- (void)buildTopBar {
    // Landing = Containers. L'ancien menu (Ghost/Orbit) n'existe plus :
    // toute navigation part de / revient a Containers.
    BOOL isLanding = (self.module == nil || [self.module isEqualToString:@"containers"]);

    // --- Slots lateraux de largeur FIXE et EGALE (32 pt) ------------------
    // Les deux cotes ont exactement la meme largeur : le groupe du milieu est
    // donc centre quoi qu'il arrive (aucune derive possible).
    // HAUTEUR EXPLICITE (44 pt) : sans elle un UIView nu dans une stack en
    // .center a une hauteur 0 -> le bouton 32x32 sort des bounds du slot ->
    // hitTest:withEvent: renvoie nil sur le slot -> le X et le chevron
    // etaient VISIBLES mais INTOUCHABLES (bug vague 4).
    UIView *leftSlot = [[UIView alloc] init];
    leftSlot.translatesAutoresizingMaskIntoConstraints = NO;
    [leftSlot.widthAnchor constraintEqualToConstant:32].active = YES;
    [leftSlot.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.bar addArrangedSubview:leftSlot];

    if (!isLanding) {
        UIButton *back = NWIconButton(@"chevron.left", ^(id s){
            self.module = @"containers";
            [self rebuild];
        });
        [leftSlot addSubview:back];
        [NSLayoutConstraint activateConstraints:@[
            [back.centerXAnchor constraintEqualToAnchor:leftSlot.centerXAnchor],
            [back.centerYAnchor constraintEqualToAnchor:leftSlot.centerYAnchor],
        ]];
    }

    UIView *spacerL = NWSpacer();
    [self.bar addArrangedSubview:spacerL];

    // --- Centre : logo Telegram (pastille bleue + avion blanc) + @nine9wham
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [UIColor colorWithRed:0.165 green:0.663 blue:0.933 alpha:1.0];
    badge.layer.cornerRadius = 15;
    if (@available(iOS 13.0, *)) badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.clipsToBounds = YES;
    [badge.widthAnchor constraintEqualToConstant:30].active = YES;
    [badge.heightAnchor constraintEqualToConstant:30].active = YES;

    UIImageView *tg = [[UIImageView alloc] initWithImage:NWSymbol(@"paperplane.fill", 15)];
    tg.tintColor = UIColor.whiteColor;
    tg.contentMode = UIViewContentModeScaleAspectFit;
    tg.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:tg];
    [NSLayoutConstraint activateConstraints:@[
        [tg.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [tg.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [tg.widthAnchor constraintEqualToConstant:16],
        [tg.heightAnchor constraintEqualToConstant:16],
    ]];
    NWStartSpin(tg);

    UILabel *t = NWLabelMake(@"@nine9wham", 16, UIColor.whiteColor, UIFontWeightBold);
    t.textAlignment = NSTextAlignmentCenter;
    t.numberOfLines = 1;
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.75;
    UILabel *sub = NWLabelMake(@"Instagram · nine9wham", 9.5, NWDim(), UIFontWeightRegular);
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 1;
    UIStackView *titles = [[UIStackView alloc] init];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.alignment = UIStackViewAlignmentCenter;
    titles.spacing = 1;
    [titles addArrangedSubview:t];
    [titles addArrangedSubview:sub];

    // Drapeau de la langue detectee sur le telephone (remplace le globe).
    UILabel *lang = NWLabelMake(NWLanguageFlag(), 17, UIColor.whiteColor, UIFontWeightRegular);
    lang.textAlignment = NSTextAlignmentCenter;
    lang.translatesAutoresizingMaskIntoConstraints = NO;
    lang.userInteractionEnabled = YES;
    [lang.widthAnchor constraintEqualToConstant:26].active = YES;
    [lang.heightAnchor constraintEqualToConstant:26].active = YES;
    UITapGestureRecognizer *tapLang = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(showLanguagePicker)];
    [lang addGestureRecognizer:tapLang];

    // Decalage optique : le couple [badge + @nine9wham] est a gauche du centre
    // car le drapeau (26) + son gap (8) sont a droite de ce couple. On ajoute
    // donc un padding de 26 pt en tete du groupe : le couple se retrouve
    // EXACTEMENT au centre de la barre (maths : centre = (106 + L)/2 des deux
    // cotes). Sans ce padding, "@nine9wham" restait ~17 pt sur la gauche.
    UIView *pad = [[UIView alloc] init];
    pad.translatesAutoresizingMaskIntoConstraints = NO;
    [pad.widthAnchor constraintEqualToConstant:26].active = YES;
    [pad.heightAnchor constraintEqualToConstant:1].active = YES;

    UIStackView *center = [[UIStackView alloc] initWithArrangedSubviews:@[pad, badge, titles, lang]];
    center.axis = UILayoutConstraintAxisHorizontal;
    center.alignment = UIStackViewAlignmentCenter;
    center.spacing = 8;
    // Le groupe du centre ne doit JAMAIS s'etirer : il garde sa largeur
    // intrinseque et les deux spacers (hugging 250) absorbent tout l'extra
    // a parts egales -> centre exact, quelle que soit la largeur d'ecran.
    [center setContentHuggingPriority:UILayoutPriorityDefaultHigh + 1
                              forAxis:UILayoutConstraintAxisHorizontal];
    [center setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh + 1
                                            forAxis:UILayoutConstraintAxisHorizontal];

    // Appui long sur @nine9wham = menu "Sort by" (les 3 points ont ete retires).
    if (isLanding) {
        UILongPressGestureRecognizer *sortPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(titleLongPress:)];
        [titles addGestureRecognizer:sortPress];
        titles.userInteractionEnabled = YES;
    }

    [self.bar addArrangedSubview:center];

    // Les deux spacers ont EXACTEMENT la meme largeur (contrainte d'egalite) :
    // la repartition de l'espace restant n'est plus laissee au solveur, le
    // groupe du milieu est donc toujours strictement centre.
    UIView *spacerR = NWSpacer();
    [self.bar addArrangedSubview:spacerR];
    [NSLayoutConstraint activateConstraints:@[
        [spacerR.widthAnchor constraintEqualToAnchor:spacerL.widthAnchor],
    ]];

    UIView *rightSlot = [[UIView alloc] init];
    rightSlot.translatesAutoresizingMaskIntoConstraints = NO;
    [rightSlot.widthAnchor constraintEqualToConstant:32].active = YES;
    [rightSlot.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.bar addArrangedSubview:rightSlot];
    UIButton *close = NWIconButton(@"xmark", ^(id s){
        [self dismissViewControllerAnimated:YES completion:nil];
    });
    [rightSlot addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [close.centerXAnchor constraintEqualToAnchor:rightSlot.centerXAnchor],
        [close.centerYAnchor constraintEqualToAnchor:rightSlot.centerYAnchor],
    ]];
}

// Appui long sur le titre -> tri des conteneurs (remplace les 3 points).
- (void)titleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self showSortSheet];
}

- (void)showSortSheet {
    NSString *cur = [self currentSort];
    __weak typeof(self) weakSelf = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Sort by"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *defs = @[
        @[@"name_az", @"Name (A-Z)"],
        @[@"name_za", @"Name (Z-A)"],
        @[@"date_new", @"Date Newest"],
        @[@"date_old", @"Date Oldest"],
    ];
    for (NSArray *d in defs) {
        BOOL on = [cur isEqualToString:d[0]];
        [a addAction:[UIAlertAction actionWithTitle:(on ? [NSString stringWithFormat:@"✓  %@", d[1]] : d[1])
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act){
            [weakSelf setSort:d[0]];
            [weakSelf rebuild];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = a.popoverPresentationController;
    if (pop) { pop.sourceView = self.view; pop.sourceRect = CGRectMake(self.view.bounds.size.width/2, 60, 1, 1); }
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showLanguagePicker {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:NWL(@"lang_title", @"Language", @"Langue", @"Idioma")
                                                               message:NWL(@"lang_msg", @"Choose the interface language", @"Choisir la langue de l'interface", @"Elegir el idioma de la interfaz")
                                                      preferredStyle:UIAlertControllerStyleAlert];
    // Langue automatique = celle du telephone (drapeau detecte automatiquement).
    // IMPORTANT : NSBundle fige la localisation au lancement -> apres chaque
    // choix on propose la RESTART pour qu'Instagram se retraduise vraiment
    // (c'etait le bug "l'application ne se traduit pas automatiquement").
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"📱  Auto (Phone language)"]
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull act) {
        NWSetLanguage(@"");
        [self rebuild];
        NWAskRelaunchLater(@"Instagram");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"🇺🇸  English"]
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull act) {
        NWSetLanguage(@"en");
        [self rebuild];
        NWAskRelaunchLater(@"Instagram");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"🇫🇷  Français"]
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull act) {
        NWSetLanguage(@"fr");
        [self rebuild];
        NWAskRelaunchLater(@"Instagram");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"🇪🇸  Español"]
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull act) {
        NWSetLanguage(@"es");
        [self rebuild];
        NWAskRelaunchLater(@"Instagram");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:NWL(@"cancel", @"Cancel", @"Annuler", @"Cancelar")
                                         style:UIAlertActionStyleCancel
                                       handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)openModule:(NSString *)module {
    self.module = module;
    [self.scroll setContentOffset:CGPointMake(0, 0) animated:NO];
    [self rebuild];
}

// --- Tri des conteneurs (copy Blaze : "Sort by") --------------------------
- (NSString *)currentSort {
    id ui = (NWState ?: @{})[@"ui"];
    if ([ui isKindOfClass:[NSDictionary class]]) {
        id s = ((NSDictionary *)ui)[@"sort"];
        if ([s isKindOfClass:[NSString class]]) return s;
    }
    return @"date_new";
}

- (void)setSort:(NSString *)sort {
    NSDictionary *st = NWState ?: @{};
    id raw = st[@"ui"];
    NSMutableDictionary *ui = [raw isKindOfClass:[NSDictionary class]]
        ? [raw mutableCopy] : [NSMutableDictionary dictionary];
    if (![ui isKindOfClass:[NSMutableDictionary class]]) ui = [NSMutableDictionary dictionary];
    ui[@"sort"] = sort;
    NSMutableDictionary *newSt = [st isKindOfClass:[NSDictionary class]] ? [st mutableCopy] : [NSMutableDictionary dictionary];
    if (![newSt isKindOfClass:[NSMutableDictionary class]]) newSt = [NSMutableDictionary dictionary];
    newSt[@"ui"] = ui;
    NWSaveState(newSt);
}

- (UIMenu *)sortMenu {
    NSString *cur = [self currentSort];
    __weak typeof(self) weakSelf = self;
    NSArray *defs = @[
        @[@"name_az", @"Name (A-Z)"],
        @[@"name_za", @"Name (Z-A)"],
        @[@"date_new", @"Date Newest"],
        @[@"date_old", @"Date Oldest"],
    ];
    NSMutableArray *items = [NSMutableArray array];
    for (NSArray *d in defs) {
        BOOL on = [cur isEqualToString:d[0]];
        [items addObject:[UIAction actionWithTitle:d[1]
                                              image:(on ? NWSymbol(@"checkmark", 15) : nil)
                                         identifier:nil
                                            handler:^(UIAction *a){
            [weakSelf setSort:d[0]];
            [weakSelf rebuild];
        }]];
    }
    return [UIMenu menuWithTitle:@"Sort by" image:nil identifier:nil options:0 children:items];
}

// Petits feedbacks tactiles communs (emil-design-eng : 140-180 ms, ease-out).
- (void)nwPressIn:(UIButton *)b {
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ b.transform = CGAffineTransformMakeScale(0.97, 0.97); }
                     completion:nil];
}
- (void)nwPressOut:(UIButton *)b {
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ b.transform = CGAffineTransformIdentity; }
                     completion:nil];
}

// --- Pied de page "New Container" (rectangle semi-transparent) ------------
- (void)buildContainersFooter {
    __weak typeof(self) weakSelf = self;

    // Bouton RECTANGLE arrondi, semi-transparent : icone + libelle dedans,
    // parfaitement centres (le libelle n'est plus une vue orpheline).
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    // Noir translucide (demande explicite) : lisible sur n'importe quel fond.
    pill.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    pill.layer.cornerRadius = 16;
    if (@available(iOS 13.0, *)) pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    pill.layer.shadowColor = UIColor.blackColor.CGColor;
    pill.layer.shadowOpacity = 0.35;
    pill.layer.shadowRadius = 10;
    pill.layer.shadowOffset = CGSizeMake(0, 4);
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.accessibilityLabel = @"New Container";
    [self.footer addSubview:pill];

    UIImageView *ic = [[UIImageView alloc] initWithImage:NWSymbol(@"plus", 16)];
    ic.tintColor = [UIColor colorWithWhite:1 alpha:0.95];
    ic.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *lab = NWLabelMake(@"New Container", 13.5,
                               [UIColor colorWithWhite:1 alpha:0.92], UIFontWeightSemibold);

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ic, lab]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 7;
    row.userInteractionEnabled = NO;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:self.footer.centerXAnchor],
        [pill.bottomAnchor constraintEqualToAnchor:self.footer.bottomAnchor constant:-28],
        [pill.widthAnchor constraintEqualToConstant:214],
        [pill.heightAnchor constraintEqualToConstant:52],
        [row.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor],
        [row.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
    ]];

    // Feedback tactile (emil-design-eng : 140 ms ease-out).
    [pill addTarget:self action:@selector(nwPressIn:) forControlEvents:UIControlEventTouchDown];
    [pill addTarget:self action:@selector(nwPressOut:)
       forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    NWBind(pill, ^(id s){
        __strong typeof(weakSelf) self2 = weakSelf;
        if (self2) [self2 presentNewContainerSheet:nil];
    });
}

// Menu d'actions d'un conteneur (Rename / Delete).
- (void)containerActions:(NSString *)cid name:(NSString *)name {
    __weak typeof(self) weakSelf = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:name
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Rename Container" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        [weakSelf promptRename:cid current:name];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete Container" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [weakSelf confirmDelete:cid name:name];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                            self.view.bounds.size.height - 80, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

// Cartes ---------------------------------------------------------------

// Carte avec marges internes (titres, textes).
- (UIStackView *)addPaddedCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = NWCardGlass();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NWLine().CGColor;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.layoutMargins = UIEdgeInsetsMake(14, 14, 14, 14);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    [self.content addArrangedSubview:card];
    return stack;
}

// Carte de lignes (les lignes ont leur propre marge de 14).
- (UIStackView *)addRowsCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = NWCardGlass();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NWLine().CGColor;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:6],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-6],
    ]];
    [self.content addArrangedSubview:card];
    return stack;
}

- (NWRowView *)addRow:(UIStackView *)stack
                 icon:(NSString *)icon
                title:(NSString *)title
                value:(NSString *)value
               action:(void (^)(void))action {
    NWRowView *r = [[NWRowView alloc] initWithIcon:icon title:title value:value];
    [r.heightAnchor constraintEqualToConstant:54].active = YES;
    r.chevronView.hidden = (action == nil);
    if (action) NWBind(r, ^(id s){ action(); });
    [stack addArrangedSubview:r];
    return r;
}

- (void)addSection:(NSString *)title {
    UILabel *l = NWSectionLabel(title);
    [self.content addArrangedSubview:l];
    [self.content setCustomSpacing:6 afterView:l];
}

// --- Hero unifie (copy Blaze) : tuile icone + kicker + titre + sous-titre
// + badges. Utilise par Dashboard / App & Device / Ghost / Proxy / Orbit pour
// que tous les modules aient exactement le meme bandeau.
- (UIView *)addHeroIcon:(NSString *)icon
                  tint:(UIColor *)tint
                kicker:(NSString *)kicker
                 title:(NSString *)title
              subtitle:(NSString *)subtitle
                badges:(NSArray *)badges {   // @[ @[text, color], ... ]
    UIView *hero = [[UIView alloc] init];
    hero.backgroundColor = NWCardGlass();
    hero.layer.cornerRadius = 20;
    hero.layer.borderWidth = 1;
    hero.layer.borderColor = [tint colorWithAlphaComponent:0.35].CGColor;

    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 8;
    v.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    v.layoutMarginsRelativeArrangement = YES;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:hero.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],
        [v.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
    ]];

    UIStackView *head = [[UIStackView alloc] init];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.spacing = 12;
    head.alignment = UIStackViewAlignmentCenter;

    UIView *tile = [[UIView alloc] init];
    tile.backgroundColor = [tint colorWithAlphaComponent:0.16];
    tile.layer.cornerRadius = 14;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile.widthAnchor constraintEqualToConstant:48].active = YES;
    [tile.heightAnchor constraintEqualToConstant:48].active = YES;
    UIImageView *ic = [[UIImageView alloc] initWithImage:NWSymbol(icon, 22)];
    if (!ic.image) ic.image = NWSymbol(@"shield.lefthalf.filled", 22);
    ic.tintColor = tint;
    ic.contentMode = UIViewContentModeScaleAspectFit;
    ic.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:ic];
    [NSLayoutConstraint activateConstraints:@[
        [ic.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [ic.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];

    UIStackView *tv = [[UIStackView alloc] init];
    tv.axis = UILayoutConstraintAxisVertical;
    tv.spacing = 2;
    if (kicker.length) {
        UILabel *k = NWLabelMake(kicker, 11, tint, UIFontWeightBold);
        [tv addArrangedSubview:k];
    }
    UILabel *t1 = NWLabelMake(title, 21, UIColor.whiteColor, UIFontWeightBold);
    UILabel *t2 = NWLabelMake(subtitle, 12.5, NWDim(), UIFontWeightRegular);
    [tv addArrangedSubview:t1];
    [tv addArrangedSubview:t2];
    [head addArrangedSubview:tile];
    [head addArrangedSubview:tv];
    [v addArrangedSubview:head];

    if (badges.count) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 6;
        row.distribution = UIStackViewDistributionFill;
        row.alignment = UIStackViewAlignmentCenter;
        for (NSArray *b in badges) {
            if (![b isKindOfClass:[NSArray class]] || b.count < 2) continue;
            [row addArrangedSubview:NWBadge([b[0] description], b[1])];
        }
        [v addArrangedSubview:row];
    }

    [self.content addArrangedSubview:hero];
    return hero;
}

- (void)buildHome {
    NSDictionary *c = NWActiveContainerDict();
    NSDictionary *fp = c[@"fp"] ?: @{};
    NSDictionary *loc = c[@"loc"] ?: @{};
    NSString *name = c[@"name"] ?: @"No active container";
    NSString *model = NWModelName(fp[@"model"]);
    NSString *ios = fp[@"sysVer"] ?: UIDevice.currentDevice.systemVersion;
    BOOL gpsOn = [loc[@"on"] boolValue];
    __weak typeof(self) weakSelf = self;

    // --- HeaderView (copy Blaze : tuile + kicker + titre + badges) ---------
    [self addHeroIcon:@"private:emoji.ghost"
                tint:NWAccent()
              kicker:@"Dashboard"
               title:name
            subtitle:@"nine9wham Your Way"
              badges:@[
                  @[gpsOn ? @"GPS ON" : @"GPS OFF", gpsOn ? NWGreen() : NWDim()],
              ]];

    // --- Grille de modules (GridCell Blaze : 2 colonnes, icone + titre) ---
    // Couleur propre a chaque module (comme Blaze).
    NSArray *mods = @[
        @[@"Ghost", @"private:emoji.ghost", @"ghost", NWGreen()],
        @[@"Orbit", @"location.fill", @"location", NWBlue()],
        @[@"Proxy", @"shield.lefthalf.filled", @"proxy", NWAccent()],
        @[@"Containers", @"square.stack.3d.up.fill", @"containers", NWAccent()],
        @[@"App & Device", @"iphone", @"device", NWBlue()],
        @[@"Changelog", @"note.text", @"changelog", NWDim()],
    ];

    for (NSUInteger i = 0; i < mods.count; i += 2) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger k = i; k < MIN(i + 2, mods.count); k++) {
            NSArray *m = mods[k];
            UIColor *tint = [m[3] isKindOfClass:[UIColor class]] ? m[3] : NWAccent();
            NWGridCell *cell = [[NWGridCell alloc] initWithIcon:m[1] title:m[0] subtitle:nil tint:tint];
            NWBind(cell, ^(id s){ [weakSelf openModule:m[2]]; });
            [row addArrangedSubview:cell];
        }
        if ((mods.count - i) == 1) [row addArrangedSubview:[[UIView alloc] init]];
        [row.heightAnchor constraintEqualToConstant:110].active = YES;
        [self.content addArrangedSubview:row];
    }

    // --- Section "nine9wham" (Version + Changelog) ---
    [self addSection:@"nine9wham"];
    UIStackView *ver = [self addRowsCard];
    [self addRow:ver icon:@"number" title:@"Version"
           value:[NSString stringWithFormat:@"Version: %@",
                   NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"453.0"]
          action:nil];
    [self addRow:ver icon:@"note.text" title:@"Changelog"
           value:@"A list of updates and bug fixes" action:^{
        [weakSelf openModule:@"changelog"];
    }];

    // --- Section "Support" ---
    [self addSection:@"Support"];
    UIStackView *sup = [self addRowsCard];
    [self addRow:sup icon:@"paperplane.fill" title:@"Mon Telegram"
           value:@"@nine9wham" action:^{
        [weakSelf openModule:@"support"];
    }];
    [self addRow:sup icon:@"quote.bubble.fill" title:@"Telegram - @nine9wham"
           value:@"Join our channel" action:^{
        [weakSelf openModule:@"support"];
    }];

    // --- Section "Reset" ---
    [self addSection:@"Reset"];
    UIStackView *rst = [self addRowsCard];
    [self addRow:rst icon:@"trash.fill" title:@"Reset everything"
           value:@"Erase all containers & settings" action:^{
        [weakSelf openModule:@"reset"];
    }];

    UILabel *foot = NWLabelMake(@"nine9wham 1.2.0 · Instagram 453.0\nIsolated containers · Fake GPS · Ghost fingerprint",
                                10.5, NWDim(), UIFontWeightRegular);
    foot.textAlignment = NSTextAlignmentCenter;
    [self.content addArrangedSubview:foot];
}


// --- App & Device ---------------------------------------------------------

- (void)buildDevice {
    NSBundle *b = NSBundle.mainBundle;
    NSDictionary *info = b.infoDictionary ?: @{};
    NSDictionary *fp = NWActiveFP ?: @{};
    NSDictionary *c = NWActiveContainerDict();
    __weak typeof(self) weakSelf = self;

    // --- Hero unifie "App & Device" --------------------------------------
    [self addHeroIcon:@"iphone"
                tint:NWBlue()
              kicker:@"About"
               title:@"App & Device"
            subtitle:@"General info about @nine9wham"
              badges:@[
                  @[c[@"name"] ?: @"default", NWAccent()],
                  @[NWGhostEnabled() ? @"Ghost ON" : @"Ghost OFF",
                    NWGhostEnabled() ? NWGreen() : NWDim()],
              ]];

    // --- Section "About" (copy Blaze) --------------------------------------
    [self addSection:@"About"];
    UIStackView *app = [self addRowsCard];
    [self addRow:app icon:@"info" title:@"About"
           value:[NSString stringWithFormat:@"General info about %@", @"@nine9wham"] action:nil];
    [self addRow:app icon:@"shippingbox" title:@"Bundle Identifier"
           value:(b.bundleIdentifier ?: @"—") action:nil];
    [self addRow:app icon:@"number" title:@"Version"
           value:[NSString stringWithFormat:@"Version: %@ (%@)",
                   info[@"CFBundleShortVersionString"] ?: @"453.0",
                   info[@"CFBundleVersion"] ?: @"—"] action:nil];
    [self addRow:app icon:@"note.text" title:@"Changelog"
           value:@"A list of updates and bug fixes" action:^{
        [weakSelf openModule:@"changelog"];
    }];

    // --- Section "Device" (valeurs spoofees) --------------------------------
    [self addSection:@"Device"];
    UIStackView *dev = [self addRowsCard];
    [self addRow:dev icon:@"iphone" title:@"Model"
           value:[NSString stringWithFormat:@"%@ · %@", NWModelName(fp[@"model"]), fp[@"model"] ?: @"—"]
          action:nil];
    [self addRow:dev icon:@"gear" title:@"System"
           value:[NSString stringWithFormat:@"iOS %@", fp[@"sysVer"] ?: @"—"] action:nil];
    [self addRow:dev icon:@"memorychip" title:@"Memory"
           value:[NSString stringWithFormat:@"%@ GB RAM", fp[@"memGB"] ?: @6] action:nil];
    [self addRow:dev icon:@"cpu" title:@"Cores" value:@"Cores: 6" action:nil];
    [self addRow:dev icon:@"tag" title:@"Device Name" value:(fp[@"deviceName"] ?: @"—") action:nil];
    [self addRow:dev icon:@"globe" title:@"Locale" value:(fp[@"locale"] ?: @"—") action:nil];
    [self addRow:dev icon:@"clock" title:@"TimeZone" value:(fp[@"tz"] ?: @"—") action:nil];

    // --- Section "Real Device" --------------------------------------------
    [self addSection:@"Real Device"];
    UIStackView *real = [self addRowsCard];
    [self addRow:real icon:@"iphone" title:@"Model" value:NWRealMachine() action:nil];
    [self addRow:real icon:@"gear" title:@"iOS" value:NWRealSystemVersion() action:nil];
    [self addRow:real icon:@"square.stack.3d.up" title:@"Container"
           value:(c[@"name"] ?: @"—") action:nil];

    UILabel *note = NWLabelMake(@"The hooks serve the active container fingerprint. Nothing is shared between containers.",
                                11, NWDim(), UIFontWeightRegular);
    [self.content addArrangedSubview:note];
}

// --- Location Spoofer -----------------------------------------------------

- (void)buildLocation {
    NSDictionary *loc = NWActiveLoc ?: @{};
    NSDictionary *c = NWActiveContainerDict();
    BOOL on = [loc[@"on"] boolValue];
    double lat = [loc[@"lat"] doubleValue];
    double lon = [loc[@"lon"] doubleValue];
    NSString *label = loc[@"label"];
    if (!label.length) label = on ? @"Current Location" : @"No Address Available";

    // --- Hero unifie "Location Spoofer" -----------------------------------
    NSString *cname = c[@"name"] ?: @"default";
    [self addHeroIcon:@"location.fill"
                tint:(on ? NWGreen() : NWDim())
              kicker:@"Orbit"
               title:@"Location Spoofer"
            subtitle:@"Fake GPS per container, applied through the hooks"
              badges:@[
                  @[on ? @"GPS ON" : @"GPS OFF", on ? NWGreen() : NWDim()],
              ]];

    // --- Section "Orbit" (copy Blaze) -------------------------------------
    [self addSection:@"Orbit"];
    NWSwitchRow *sw = [[NWSwitchRow alloc] initWithIcon:@"location.fill"
                                                   title:@"Enable"
                                               subtitle:[NSString stringWithFormat:@"Orbit for %@ container", cname]
                                                     on:on];
    [sw.heightAnchor constraintEqualToConstant:64].active = YES;
    __weak typeof(self) weakSelf = self;
    sw.onChange = ^(BOOL value) {
        NSString *cid = NWActiveID;
        if (!cid) return;
        if (value) {
            NSDictionary *l = NWActiveLoc ?: @{};
            double la = [l[@"lat"] doubleValue];
            double lo = [l[@"lon"] doubleValue];
            NSString *lb = l[@"label"];
            if (la == 0 && lo == 0) { la = 48.8566; lo = 2.3522; lb = @"Paris"; }
            NWApplyLocation(cid, la, lo, lb.length ? lb : @"Current Location");
        } else {
            NSDictionary *l = NWActiveLoc ?: @{};
            NWUpdateContainerField(cid, @"loc", @{@"on": @NO,
                                                  @"lat": l[@"lat"] ?: @0,
                                                  @"lon": l[@"lon"] ?: @0,
                                                  @"label": l[@"label"] ?: @""});
            NWReloadAfterStateChange();
        }
        [weakSelf rebuild];
    };
    UIStackView *toggleCard = [self addRowsCard];
    [toggleCard addArrangedSubview:sw];

    // --- Section "Maps" (copy Blaze) --------------------------------------
    [self addSection:@"Maps"];
    UIStackView *actions = [self addRowsCard];
    [self addRow:actions icon:@"map.fill" title:@"Choose"
           value:@"Location from the Maps picker" action:^{
        CLLocationCoordinate2D initial = CLLocationCoordinate2DMake(lat, lon);
        if (!on || (lat == 0 && lon == 0)) initial = CLLocationCoordinate2DMake(48.8566, 2.3522);
        NWOpenMapPicker(weakSelf, initial, ^(double la, double lo, NSString *label) {
            NWApplyLocation(NWActiveID, la, lo, label.length ? label : @"Current Location");
            [weakSelf rebuild];
        });
    }];
    [self addRow:actions icon:@"antenna.radiowaves.left.and.right" title:@"Load"
           value:@"Location from your proxy I.P" action:^{
        NSDictionary *p = NWActiveProxy() ?: @{};
        id onV = p[@"on"], hostV = p[@"host"];
        BOOL onP = [onV isKindOfClass:[NSNumber class]] && [onV boolValue];
        NSString *hostS = [hostV isKindOfClass:[NSString class]] ? hostV : nil;
        if (!onP || !hostS.length) {
            NWAlert(@"Load", @"Unable to load coordinates from the proxy");
            return;
        }
        [weakSelf lookupProxyIP:hostS];
    }];
    [self addRow:actions icon:@"magnifyingglass" title:@"Search..."
           value:@"Country, place, restaurant..." action:^{
        [weakSelf promptSearchPlace];
    }];
    [self addRow:actions icon:@"location.north.fill" title:@"Latitude"
           value:[NSString stringWithFormat:@"%.6f", lat] action:^{
        [weakSelf promptCoordinates];
    }];
    [self addRow:actions icon:@"location.fill" title:@"Longitude"
           value:[NSString stringWithFormat:@"%.6f", lon] action:^{
        [weakSelf promptCoordinates];
    }];

    // --- Section "Current Location" (copy Blaze) --------------------------
    [self addSection:@"Current Location"];
    UIStackView *hero = [self addPaddedCard];
    UIStackView *head = [[UIStackView alloc] init];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.spacing = 12;
    head.alignment = UIStackViewAlignmentCenter;
    UIView *tile = [[UIView alloc] init];
    tile.backgroundColor = [NWAccent() colorWithAlphaComponent:0.16];
    tile.layer.cornerRadius = 14;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile.widthAnchor constraintEqualToConstant:48].active = YES;
    [tile.heightAnchor constraintEqualToConstant:48].active = YES;
    UIImageView *icon = [[UIImageView alloc] initWithImage:NWSymbol(@"location.fill", 22)];
    icon.tintColor = NWAccent();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];
    UIStackView *tv = [[UIStackView alloc] init];
    tv.axis = UILayoutConstraintAxisVertical;
    tv.spacing = 2;
    UILabel *t1 = NWLabelMake(label, 15, UIColor.whiteColor, UIFontWeightSemibold);
    UILabel *t2 = NWLabelMake(on ? [NSString stringWithFormat:@"%f, %f", lat, lon] : @"No Address Available",
                              11.5, NWDim(), UIFontWeightRegular);
    [tv addArrangedSubview:t1];
    [tv addArrangedSubview:t2];
    [head addArrangedSubview:tile];
    [head addArrangedSubview:tv];
    [hero addArrangedSubview:head];

    UIStackView *tools = [self addRowsCard];
    [self addRow:tools icon:@"mappin.and.ellipse" title:@"Generate"
           value:@"Random location" action:^{
        double la = -55.0 + (double)arc4random_uniform(11500) / 100.0;
        double lo = -180.0 + (double)arc4random_uniform(36000) / 100.0;
        NWApplyLocation(NWActiveID, la, lo, [NSString stringWithFormat:@"Random %f, %f", la, lo]);
        [weakSelf rebuild];
    }];
    [self addRow:tools icon:@"xmark.circle" title:@"Disable"
           value:@"Turn off the location spoofer" action:^{
        NSDictionary *l = NWActiveLoc ?: @{};
        NWUpdateContainerField(NWActiveID, @"loc", @{@"on": @NO,
                                                     @"lat": l[@"lat"] ?: @0,
                                                     @"lon": l[@"lon"] ?: @0,
                                                     @"label": l[@"label"] ?: @""});
        NWReloadAfterStateChange();
        [weakSelf rebuild];
    }];

    // --- Section "Cities" --------------------------------------------------
    [self addSection:@"Cities"];
    UIStackView *cities = [self addRowsCard];
    for (NSArray *city in NWCities()) {
        NSString *cityName = city[0];
        NSNumber *la = city[1];
        NSNumber *lo = city[2];
        [self addRow:cities icon:@"mappin.and.ellipse" title:cityName
               value:[NSString stringWithFormat:@"%f, %f", la.doubleValue, lo.doubleValue]
              action:^{
            NWApplyLocation(NWActiveID, la.doubleValue, lo.doubleValue, cityName);
            [weakSelf rebuild];
        }];
    }

    UILabel *note = NWLabelMake(@"Spoofed the location with coordinates is applied per container. The real location is never used while this is enabled.",
                                11, NWDim(), UIFontWeightRegular);
    [self.content addArrangedSubview:note];
}

- (void)promptSearchPlace {
    __weak typeof(self) weakSelf = self;
    [self promptTextWithTitle:@"Search..."
                  placeholder:@"Country, place, restaurant..."
                        value:nil
                       secure:NO
                   completion:^(NSString *text) {
        if (text.length < 2) return;
        [weakSelf searchPlace:text];
    }];
}

- (void)searchPlace:(NSString *)text {
    NSString *encoded = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://nominatim.openstreetmap.org/search?q=%@&format=json&limit=10", encoded]];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"nine9wham/1.1 (iOS app)" forHTTPHeaderField:@"User-Agent"];
    [req setTimeoutInterval:15];
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *json = nil;
        if (data) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![json isKindOfClass:[NSArray class]] || json.count == 0) {
                NWAlert(@"Search...", @"There's no result found...");
                return;
            }
            NSMutableArray *opts = [NSMutableArray array];
            for (NSDictionary *r in json) {
                NSString *name = r[@"display_name"] ?: r[@"name"];
                if (![name isKindOfClass:[NSString class]]) continue;
                NSString *lat = [NSString stringWithFormat:@"%@", r[@"lat"]];
                NSString *lon = [NSString stringWithFormat:@"%@", r[@"lon"]];
                [opts addObject:@{
                    @"title": name,
                    @"subtitle": [NSString stringWithFormat:@"%@, %@", lat, lon],
                    @"value": name,
                    @"lat": @(lat.doubleValue),
                    @"lon": @(lon.doubleValue),
                }];
            }
            [weakSelf presentOptions:opts selected:nil heading:@"Search..." pick:^(NSDictionary *opt) {
                NWApplyLocation(NWActiveID, [opt[@"lat"] doubleValue], [opt[@"lon"] doubleValue], opt[@"title"]);
                [weakSelf rebuild];
            }];
        });
    }] resume];
}

// Geolocalise l'I.P du proxy (host) et applique la position correspondante.
- (void)lookupProxyIP:(NSString *)host {
    NSString *enc = [host stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://ipapi.co/%@/json/", enc ?: @""]];
    if (!url) { NWAlert(@"Load", @"Unable to load coordinates from the proxy"); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"nine9wham/1.2 (iOS app)" forHTTPHeaderField:@"User-Agent"];
    [req setTimeoutInterval:15];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSDictionary *j = nil;
        if (data) {
            id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([o isKindOfClass:[NSDictionary class]]) j = o;
        }
        NSNumber *la = j[@"latitude"], *lo = j[@"longitude"];
        NSString *city = [j[@"city"] isKindOfClass:[NSString class]] ? j[@"city"] : nil;
        NSString *cc = [j[@"country_name"] isKindOfClass:[NSString class]] ? j[@"country_name"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!la || !lo || ![la isKindOfClass:[NSNumber class]] || ![lo isKindOfClass:[NSNumber class]]) {
                NWAlert(@"Load", @"Unable to load coordinates from the proxy");
                return;
            }
            NSString *lb = cc.length ? (city.length ? [NSString stringWithFormat:@"%@, %@", city, cc] : cc)
                                     : [NSString stringWithFormat:@"%f, %f", la.doubleValue, lo.doubleValue];
            NWApplyLocation(NWActiveID, la.doubleValue, lo.doubleValue, lb);
            [weakSelf rebuild];
        });
    }] resume];
}

- (void)promptCoordinates {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Set Location"
                                                               message:@"Latitude and longitude in decimal format."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Latitude...";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Longitude...";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Set Location" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        double la = a.textFields[0].text.doubleValue;
        double lo = a.textFields[1].text.doubleValue;
        if (la < -90 || la > 90 || lo < -180 || lo > 180) {
            NWAlert(@"Set Location", @"Latitude must be between -90 and 90, longitude between -180 and 180.");
            return;
        }
        NWApplyLocation(NWActiveID, la, lo, [NSString stringWithFormat:@"%f, %f", la, lo]);
        [weakSelf rebuild];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// --- Ghost (empreinte) ----------------------------------------------------

- (void)buildGhost {
    NSDictionary *fp = NWActiveFP ?: @{};
    NSDictionary *c = NWActiveContainerDict();
    NSString *cname = c[@"name"] ?: @"default";
    NSString *model = fp[@"model"] ?: @"";
    BOOL ghostOn = NWGhostEnabled();
    __weak typeof(self) weakSelf = self;

    // --- Hero unifie "Ghost" (sans badge "Spoof ON" : demande explicite) ----
    // VERT quand Ghost est actif, gris sinon.
    [self addHeroIcon:@"private:emoji.ghost"
                tint:(ghostOn ? NWGreen() : NWDim())
              kicker:nil
               title:@"Ghost"
            subtitle:@"Device Fingerprint Spoofer"
              badges:@[]];

    // --- Section "Ghost" (copy Blaze : Enable · Ghost for %@ container) -----
    [self addSection:@"Ghost"];
    NWSwitchRow *sw = [[NWSwitchRow alloc] initWithIcon:@"globe"
                                               title:@"Enable"
                                           subtitle:[NSString stringWithFormat:@"Ghost for %@ container", cname]
                                                 on:ghostOn];
    [sw.heightAnchor constraintEqualToConstant:64].active = YES;
    sw.onChange = ^(BOOL value) {
        NWUpdateContainerField(NWActiveID, @"ghostOn", @(value));
        NWReloadAfterStateChange();
        [weakSelf rebuild];
    };
    UIStackView *ghostCard = [self addRowsCard];
    [ghostCard addArrangedSubview:sw];

    // --- Section "Preferred Country (global)" ------------------------------
    [self addSection:@"Preferred Country (global)"];
    UIStackView *country = [self addRowsCard];
    NSString *locId = fp[@"locale"] ?: @"en_US";
    NSString *iso = locId.length >= 3 ? [locId substringFromIndex:locId.length - 2] : @"US";
    [self addRow:country icon:@"flag.fill" title:@"Choose your preferred country"
           value:NWCountryDisplayName(iso) action:^{
        [weakSelf pickPreferredCountry];
    }];

    // --- Section "Generate" (copy Blaze : Formulate) -----------------------
    [self addSection:@"Generate"];
    UIStackView *gen = [self addRowsCard];
    [self addRow:gen icon:@"plus.forwardslash.minus" title:@"Formulate"
           value:@"Random data for all modules" action:^{
        NSMutableDictionary *nfp = [NWGenerateFingerprintKeepingLocale(NWActiveFP) mutableCopy];
        NWUpdateActiveFP(nfp);
        NWReloadAfterStateChange();
        [weakSelf rebuild];
        NWAlert(@"Generate", @"Successfully generated new random data");
    }];

    // --- Section "Modules" (copy Blaze) ------------------------------------
    [self addSection:@"Modules"];

    UIStackView *mods = [self addRowsCard];
    [self addRow:mods icon:@"iphone" title:@"Device"
           value:@"Random data for the Device module only" action:^{
        NSMutableDictionary *nfp = [NWGenerateFingerprintKeepingLocale(NWActiveFP) mutableCopy];
        NWUpdateActiveFP(nfp);
        NWReloadAfterStateChange();
        [weakSelf rebuild];
        NWAlert(@"Generate", @"Successfully generated new random data");
    }];
    [self addRow:mods icon:@"textformat.size" title:@"Locale"
           value:@"Random data for the Locale module only" action:^{
        [weakSelf pickLocale];
    }];
    [self addRow:mods icon:@"clock" title:@"TimeZone"
           value:@"Random data for the TimeZone module only" action:^{
        [weakSelf pickTimezone];
    }];
    [self addRow:mods icon:@"folder.fill.badge.gearshape" title:@"Other"
           value:@"Random data for the Other module only" action:^{
        [weakSelf promptDeviceName];
    }];

    // --- Section "Containers" (transfert entre telephones) -----------------
    // Vague 10 : exporter les conteneurs d'un iPhone puis les importer sur un
    // autre. Le fichier part avec prefs + cookies : les comptes arrivent deja
    // connectes, aucun compte n'est recree.
    [self addSection:@"Containers"];
    UIStackView *ctrans = [self addRowsCard];
    [self addRow:ctrans icon:@"square.and.arrow.up" title:@"Export containers"
           value:NWL(@"ct_exp_v", @"Send to another iPhone (encrypted file)",
                     @"Envoyer vers un autre iPhone (fichier chiffre)",
                     @"Enviar a otro iPhone (archivo cifrado)") action:^{
        __strong typeof(weakSelf) s2 = weakSelf;
        if (!s2) return;
        [s2 promptBackupPassword:YES completion:^(NSString *pw) {
            NSError *err = nil;
            NSString *path = NWContainersExport(pw, &err);
            if (!path) {
                NWAlert(NWL(@"err_exp", @"Export error", @"Erreur export", @"Error de exportacion"),
                        err.localizedDescription ?: NWL(@"fail", @"Failed", @"Echec", @"Fallo"));
                return;
            }
            UIActivityViewController *av = [[UIActivityViewController alloc]
                initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            av.popoverPresentationController.sourceView = s2.view;
            av.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(s2.view.bounds), s2.view.bounds.size.height - 80, 1, 1);
            [s2 presentViewController:av animated:YES completion:nil];
        }];
    }];
    [self addRow:ctrans icon:@"square.and.arrow.down" title:@"Import containers"
           value:NWL(@"ct_imp_v", @"Add containers from a file (merge)",
                     @"Ajouter des conteneurs depuis un fichier (fusion)",
                     @"Anadir contenedores desde un archivo (fusion)") action:^{
        __strong typeof(weakSelf) s2 = weakSelf;
        if (!s2) return;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        NWContainerImportPicker *d = [NWContainerImportPicker new];
        NWImportPickerHolder = d;   // le delegate d'un picker est faible
        d.completion = ^(NSURL *u) {
            NWImportPickerHolder = nil;
            if (!u) return;
            __strong typeof(weakSelf) s3 = weakSelf;
            if (!s3) return;
            [s3 promptBackupPassword:NO completion:^(NSString *pw) {
                NSError *err = nil;
                NSInteger n = NWContainersImport(u, pw, &err);
                if (n > 0) {
                    [s3 rebuild];
                    NSString *fmt = NWL(@"ct_imp_ok2",
                        @"%ld container(s) imported. Tap one to launch it.",
                        @"%ld conteneur(s) importe(s). Touchez-en un pour le lancer.",
                        @"%ld contenedor(es) importado(s). Toca uno para iniciarlo.");
                    NWAlert(NWL(@"ct_imp_ok", @"Containers imported",
                                @"Conteneurs importes", @"Contenedores importados"),
                            [NSString stringWithFormat:fmt, (long)n]);
                } else {
                    NWAlert(NWL(@"err_imp", @"Import error", @"Erreur import", @"Error de importacion"),
                            err.localizedDescription ?: NWL(@"fail", @"Failed", @"Echec", @"Fallo"));
                }
            }];
        };
        picker.delegate = d;
        picker.allowsMultipleSelection = NO;
        [s2 presentViewController:picker animated:YES completion:nil];
    }];

    // --- Section "App & Device" (dans Ghost) ---------------------------------
    [self addSection:@"App & Device"];
    UIStackView *ad = [self addRowsCard];
    NSBundle *b = NSBundle.mainBundle;
    NSDictionary *info = b.infoDictionary ?: @{};
    [self addRow:ad icon:@"info" title:@"About"
           value:[NSString stringWithFormat:@"General info about %@", @"@nine9wham"] action:nil];
    [self addRow:ad icon:@"shippingbox" title:@"Bundle Identifier"
           value:(b.bundleIdentifier ?: @"—") action:nil];

    // --- Section "Device" (copy Blaze : Enable Spoof / Choose an iPhone) ----
    [self addSection:@"Device"];
    UIStackView *dev = [self addRowsCard];
    [self addRow:dev icon:@"apps.iphone.badge.plus" title:@"Choose an iPhone"
           value:NWModelName(model) action:^{
        [weakSelf pickModel];
    }];
    [self addRow:dev icon:@"number" title:@"Choose Version"
           value:[NSString stringWithFormat:@"iOS %@", fp[@"sysVer"] ?: @"—"] action:^{
        [weakSelf pickIOS];
    }];
    [self addRow:dev icon:@"externaldrive.fill" title:@"Choose Storage"
           value:[NSString stringWithFormat:@"%@ GB RAM", fp[@"memGB"] ?: @6] action:^{
        [weakSelf pickRAM];
    }];
    [self addRow:dev icon:@"n.circle.fill" title:@"Set Device Name"
           value:(fp[@"deviceName"] ?: @"No name available") action:^{
        [weakSelf promptDeviceName];
    }];

    // --- Section "Identifiers" (copy Blaze) --------------------------------
    [self addSection:@"Identifiers"];
    UIStackView *ids = [self addRowsCard];
    NSString *idfv = fp[@"idfv"] ?: @"—";
    NSString *idfa = fp[@"idfa"] ?: @"—";
    [self addRow:ids icon:@"key.fill" title:@"Vendor"
           value:[idfv substringToIndex:MIN(8, idfv.length)] action:nil];
    [self addRow:ids icon:@"a.circle.fill" title:@"Advertising"
           value:[idfa substringToIndex:MIN(8, idfa.length)] action:nil];
    [self addRow:ids icon:@"arrow.clockwise" title:@"Generate New Identifier"
           value:@"Generate Identifier" action:^{
        NWUpdateActiveFPKey(@"idfv", [[NSUUID UUID] UUIDString]);
        NWUpdateActiveFPKey(@"idfa", [[NSUUID UUID] UUIDString]);
        [weakSelf rebuild];
        NWAlert(@"Generate", @"Successfully generated new random data");
    }];

    // --- Section "Locale" / "TimeZone" (copy Blaze) ------------------------
    [self addSection:@"Locale"];
    UIStackView *lc = [self addRowsCard];
    [self addRow:lc icon:@"textformat.size" title:@"Choose Locale & Language"
           value:(fp[@"locale"] ?: @"—") action:^{
        [weakSelf pickLocale];
    }];

    [self addSection:@"TimeZone"];
    UIStackView *tz = [self addRowsCard];
    [self addRow:tz icon:@"clock" title:@"Choose TimeZone"
           value:(fp[@"tz"] ?: @"—") action:^{
        [weakSelf pickTimezone];
    }];

    // --- Fin de page Ghost : Support + Version (deplaces de l'ancien menu) --
    [self addSection:@"Support"];
    UIStackView *sup = [self addRowsCard];
    [self addRow:sup icon:@"paperplane.fill" title:@"Mon Telegram"
           value:@"@nine9wham" action:^{
        [weakSelf openModule:@"support"];
    }];

    [self addSection:@"nine9wham"];
    UIStackView *ver = [self addRowsCard];
    [self addRow:ver icon:@"number" title:@"Version"
           value:[NSString stringWithFormat:@"Version: %@ (%@)",
                   info[@"CFBundleShortVersionString"] ?: @"453.0",
                   info[@"CFBundleVersion"] ?: @"—"]
          action:nil];

    UILabel *note = NWLabelMake(@"Spoofed values are applied per container through the hooks. Restart Instagram so the app reads the new fingerprint.",
                                11, NWDim(), UIFontWeightRegular);
    [self.content addArrangedSubview:note];
}

// Pays preferentiel global (copy Blaze) : ouvre la liste des locales/pays.
// Vague 9 : noms COMPLETS (France, francais) et choix d'un pays = nouvel
// appareil aleatoire du pays, langue du telephone comprise.
- (void)pickPreferredCountry {
    NSArray *opts = NWCountryOptions();
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:(NWActiveFP[@"locale"] ?: @"")
                 heading:@"Preferred Country (global)"
                    pick:^(NSDictionary *opt) {
        NSString *loc = opt[@"value"];
        NSString *tz = opt[@"tz"];
        NSString *newCC = opt[@"cc"];
        NSString *oldLoc = NWActiveFP[@"locale"];
        NSString *oldCC = nil;
        if ([oldLoc isKindOfClass:[NSString class]] && oldLoc.length >= 2) {
            NSArray *p = [oldLoc componentsSeparatedByString:@"_"];
            oldCC = p.count > 1 ? p.lastObject : nil;
        }
        if (![newCC isEqualToString:oldCC ?: @""]) {
            // Nouveau pays : identite d'appareil entierement regeneree, mais
            // avec la langue et le fuseau du pays choisi (aucun conflit).
            NWRollIdentityForContainer(NWActiveID, loc, tz);
        } else {
            NWUpdateActiveFPKey(@"locale", loc);
            if (tz) NWUpdateActiveFPKey(@"tz", tz);
        }
        NWApplySystemLanguage();   // pays -> langue du telephone (US = anglais)
        NWReloadAfterStateChange();
        [weakSelf rebuild];
        // Pays/langue ecrits dans AppleLanguages : Instagram ne se retraduit
        // qu'apres rechargement de NSBundle -> on propose la RESTART.
        NWAskRelaunchLater(@"Instagram");
    }];
}

// RAM (copy Blaze : "Choose Storage" / "8 GB RAM" ... "2 GB RAM").
- (void)pickRAM {
    NSMutableArray *opts = [NSMutableArray array];
    for (int gb = 8; gb >= 2; gb--) {
        [opts addObject:@{@"title": [NSString stringWithFormat:@"%d GB RAM", gb],
                          @"subtitle": @"Memory capacity",
                          @"value": [NSString stringWithFormat:@"%d", gb]}];
    }
    __weak typeof(self) weakSelf = self;
    NSNumber *cur = NWActiveFP[@"memGB"] ?: @6;
    [self presentOptions:opts
                selected:[NSString stringWithFormat:@"%d", cur.intValue]
                 heading:@"Choose Storage"
                    pick:^(NSDictionary *opt) {
        NWUpdateActiveFPKey(@"memGB", @([opt[@"value"] intValue]));
        NWReloadAfterStateChange();
        [weakSelf rebuild];
    }];
}

- (void)pickModel {
    NSMutableArray *opts = [NSMutableArray array];
    for (NSDictionary *m in NWModelList()) {
        [opts addObject:@{
            @"title": m[@"name"],
            @"subtitle": [NSString stringWithFormat:@"%@ · %@ Go", m[@"id"], m[@"ram"]],
            @"value": m[@"id"],
        }];
    }
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:(NWActiveFP[@"model"] ?: @"") heading:@"Choose an iPhone" pick:^(NSDictionary *opt) {
        NSString *mid = opt[@"value"];
        NSDictionary *info = NWModelInfo(mid);
        if (!info) return;
        NWUpdateActiveFPKey(@"model", mid);
        NWUpdateActiveFPKey(@"memGB", info[@"ram"]);
        NWUpdateActiveFPKey(@"cpu", @6);
        [weakSelf rebuild];
    }];
}

- (void)pickIOS {
    NSMutableArray *opts = [NSMutableArray array];
    for (NSString *v in NWIOSVersions()) {
        [opts addObject:@{@"title": [NSString stringWithFormat:@"iOS %@", v],
                          @"subtitle": @"Spoofed system version",
                          @"value": v}];
    }
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:(NWActiveFP[@"sysVer"] ?: @"") heading:@"Choose Version" pick:^(NSDictionary *opt) {
        NWUpdateActiveFPKey(@"sysVer", opt[@"value"]);
        [weakSelf rebuild];
    }];
}

- (void)pickLocale {
    // Meme source que "Preferred Country", mais la LANGUE est le titre :
    // "French — France" au lieu de "fr_FR".
    NSMutableArray *opts = [NSMutableArray array];
    for (NSDictionary *o in NWCountryOptions()) {
        [opts addObject:@{
            @"title": NWLanguageDisplayName(o[@"lang"]),
            @"subtitle": [NSString stringWithFormat:@"%@ · %@",
                          NWCountryDisplayName(o[@"cc"]), o[@"tz"]],
            @"value": o[@"value"],
            @"tz": o[@"tz"],
            @"cc": o[@"cc"],
            @"lang": o[@"lang"],
        }];
    }
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:(NWActiveFP[@"locale"] ?: @"") heading:@"Choose Locale & Language" pick:^(NSDictionary *opt) {
        NSString *loc = opt[@"value"];
        NSString *tz = opt[@"tz"];
        NSString *newCC = opt[@"cc"];
        NSString *oldLoc = NWActiveFP[@"locale"];
        NSString *oldCC = nil;
        if ([oldLoc isKindOfClass:[NSString class]] && oldLoc.length >= 2) {
            NSArray *p = [oldLoc componentsSeparatedByString:@"_"];
            oldCC = p.count > 1 ? p.lastObject : nil;
        }
        if (![newCC isEqualToString:oldCC ?: @""]) {
            // Nouveau pays : appareil regenere avec la langue de ce pays.
            NWRollIdentityForContainer(NWActiveID, loc, tz);
        } else {
            NWUpdateActiveFPKey(@"locale", loc);
            if (tz) NWUpdateActiveFPKey(@"tz", tz);
        }
        NWApplySystemLanguage();   // locale -> langue du telephone
        [weakSelf rebuild];
        // AppleLanguages change -> Instagram ne se retraduit qu'au rechargement
        // de NSBundle : on propose la RESTART ( meme mecanique que le pays ).
        NWAskRelaunchLater(@"Instagram");
    }];
}

- (void)pickTimezone {
    NSMutableArray *opts = [NSMutableArray array];
    NSString *current = NWActiveFP[@"tz"] ?: @"";
    for (NSString *tz in [NSTimeZone knownTimeZoneNames]) {
        [opts addObject:@{@"title": tz, @"subtitle": @"", @"value": tz}];
    }
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:current heading:@"Choose TimeZone" pick:^(NSDictionary *opt) {
        NWUpdateActiveFPKey(@"tz", opt[@"value"]);
        [weakSelf rebuild];
    }];
}

- (void)promptDeviceName {
    __weak typeof(self) weakSelf = self;
    [self promptTextWithTitle:@"Set Device Name"
                  placeholder:@"Device name..."
                        value:(NWActiveFP[@"deviceName"] ?: @"")
                       secure:NO
                   completion:^(NSString *text) {
        if (!text.length) return;
        NWUpdateActiveFPKey(@"deviceName", text);
        [weakSelf rebuild];
    }];
}

// --- Containers -----------------------------------------------------------

- (void)buildContainers {
    NSDictionary *st = NWState ?: @{};
    NSDictionary *raw = st[@"containers"];
    NSDictionary *containers = [raw isKindOfClass:[NSDictionary class]] ? raw : @{};

    // Tri (copy Blaze : menu "Sort by")
    NSString *sort = [self currentSort];
    // Le conteneur par defaut (le plus ancien) reste TOUJOURS en haut.
    NSString *firstId = nil;
    double firstT = 0;
    for (NSString *cid in containers) {
        id c = containers[cid];
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        double t = [((NSDictionary *)c)[@"createdAt"] doubleValue];
        if (!firstId || t < firstT) { firstId = cid; firstT = t; }
    }
    NSArray *ids = containers.allKeys;
    ids = [ids sortedArrayUsingComparator:^NSComparisonResult(id objA, id objB) {
        if (firstId) {
            if ([objA isEqualToString:firstId]) return NSOrderedAscending;
            if ([objB isEqualToString:firstId]) return NSOrderedDescending;
        }
        NSString *a = objA, *b = objB;
        NSDictionary *ca = [containers[a] isKindOfClass:[NSDictionary class]] ? containers[a] : @{};
        NSDictionary *cb = [containers[b] isKindOfClass:[NSDictionary class]] ? containers[b] : @{};
        if ([sort isEqualToString:@"name_az"] || [sort isEqualToString:@"name_za"]) {
            NSString *na = [ca[@"name"] isKindOfClass:[NSString class]] ? ca[@"name"] : @"";
            NSString *nb = [cb[@"name"] isKindOfClass:[NSString class]] ? cb[@"name"] : @"";
            NSComparisonResult r = [na localizedCaseInsensitiveCompare:nb];
            if ([sort isEqualToString:@"name_za"]) return (NSComparisonResult)(-((NSInteger)r));
            return r;
        }
        double da = [ca[@"createdAt"] doubleValue];
        double db = [cb[@"createdAt"] doubleValue];
        if (da == db) return NSOrderedSame;
        BOOL newestFirst = ![sort isEqualToString:@"date_old"];
        BOOL aFirst = newestFirst ? (da > db) : (da < db);
        return aFirst ? NSOrderedAscending : NSOrderedDescending;
    }];
    __weak typeof(self) weakSelf = self;

    if (!ids.count) {
        UIStackView *empty = [self addPaddedCard];
        UILabel *l = NWLabelMake(@"No container yet. Tap New Container to create your first one.",
                                 13, NWDim(), UIFontWeightRegular);
        [empty addArrangedSubview:l];
    }

    NSDictionary *px = NWActiveProxy();
    BOOL proxyOn = [px isKindOfClass:[NSDictionary class]] && [px[@"on"] boolValue];

    for (NSString *cid in ids) {
        NSDictionary *c = containers[cid];
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *fp = [c[@"fp"] isKindOfClass:[NSDictionary class]] ? c[@"fp"] : @{};
        NSDictionary *loc = [c[@"loc"] isKindOfClass:[NSDictionary class]] ? c[@"loc"] : @{};
        BOOL active = [cid isEqualToString:NWActiveID];
        BOOL gpsOn = [loc[@"on"] boolValue];
        BOOL ghostOn = c[@"ghostOn"] ? [c[@"ghostOn"] boolValue] : YES;
        NSString *cname = ([c[@"name"] isKindOfClass:[NSString class]] && [c[@"name"] length])
            ? c[@"name"] : cid;
        NSString *locLabel = [loc[@"label"] isKindOfClass:[NSString class]] ? loc[@"label"] : @"";

        // --- Cellule (copy Blaze : 70 pt, dossier + nom + 4 iconees) --------
        NWContainerCellView *cell = [[NWContainerCellView alloc] initWithFrame:CGRectZero];
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        cell.folderView.tintColor = active ? NWGreen() : NWDim();
        cell.titleLabel.text = cname;
        cell.subLabel.text = [NSString stringWithFormat:@"%@ · iOS %@ · %@%@",
                              NWModelName(fp[@"model"]), fp[@"sysVer"] ?: @"—",
                              gpsOn ? (locLabel.length ? locLabel : @"Spoofed") : @"Location off",
                              active ? @" · ACTIVE" : @""];
        if (active) {
            cell.layer.borderWidth = 1.3;
            cell.layer.borderColor = [NWAccent() colorWithAlphaComponent:0.9].CGColor;
        }
        cell.ghostBtn.tintColor = ghostOn ? NWGreen()
                                          : [UIColor colorWithWhite:1 alpha:0.25];
        cell.locBtn.tintColor = gpsOn ? NWGreen() : [UIColor colorWithWhite:1 alpha:0.25];
        cell.proxyBtn.tintColor = proxyOn ? NWAccent() : [UIColor colorWithWhite:1 alpha:0.25];

        NSString *cidS = cid;
        NSString *nameS = cname;
        BOOL activeB = active;
        NSDictionary *locS = loc;

        NWBind(cell, ^(id s){
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2 || activeB) return;          // Blaze : tap = basculer
            [self2 confirmSwitch:cidS name:nameS];
        });
        cell.onGhost = ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2) [self2 openModule:@"ghost"];   // menu Ghost complet
        };
        cell.onLocation = ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            CLLocationCoordinate2D initial = CLLocationCoordinate2DMake(48.8566, 2.3522);
            if ([locS[@"on"] boolValue]) {
                initial = CLLocationCoordinate2DMake([locS[@"lat"] doubleValue],
                                                     [locS[@"lon"] doubleValue]);
            }
            NWOpenMapPicker(self2, initial, ^(double lat, double lon, NSString *label) {
                __strong typeof(weakSelf) s3 = weakSelf;
                if (!s3) return;
                NSDictionary *newLoc = @{@"on": @YES, @"lat": @(lat), @"lon": @(lon),
                                         @"label": label.length ? label : @"Current Location"};
                NWUpdateContainerField(cidS, @"loc", newLoc);
                // Le pays du lieu choisi donne la langue + fuseau au conteneur.
                NWMapFollowCountry(cidS, label);
                if ([cidS isEqualToString:NWActiveID]) {
                    NWActiveLoc = newLoc;
                    NWReloadAfterStateChange();
                }
                [s3 rebuild];
            });
        };
        cell.onProxy = ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2) [self2 openModule:@"proxy"];
        };
        cell.onMore = ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2) [self2 containerActions:cidS name:nameS];
        };

        [self.content addArrangedSubview:cell];
        [cell.heightAnchor constraintEqualToConstant:70].active = YES;
    }

    UILabel *note = NWLabelMake(@"Each container keeps its own prefs, cookies, keychain, fingerprint and location. Tap a container to switch to it.",
                                11, NWDim(), UIFontWeightRegular);
    [self.content addArrangedSubview:note];

    // --- Reset (seule section module restante sur Containers) ---------------
    // Location Spoofer, Changelog, Version et Mon Telegram ont ete retires
    // d'ici : Mon Telegram + Version sont maintenant dans Ghost (fin de page).
    [self addSection:@"Reset"];
    UIStackView *rst = [self addRowsCard];
    [self addRow:rst icon:@"trash.fill" title:@"Reset everything"
           value:@"Erase all containers & settings" action:^{
        [weakSelf openModule:@"reset"];
    }];
}

// Feuille "New Container" (copy Blaze). locOpt : position choisie sur la carte.
- (void)presentNewContainerSheet:(NSDictionary *)locOpt {
    NWNewContainerSheet *sheet = [[NWNewContainerSheet alloc] init];
    sheet.initialLoc = locOpt;
    __weak typeof(self) weakSelf = self;
    sheet.onCreate = ^(NSString *name, NSDictionary *loc, BOOL ghostOn) {
        NSString *cid = NWCreateContainerWithLocGhost(name, loc ? loc : locOpt, ghostOn);
        // La position initiale choisie donne son pays -> langue + fuseau du
        // nouveau conteneur (chaque conteneur = un telephone unique).
        if (cid.length) {
            NSDictionary *src = loc ?: locOpt;
            NSString *lbl = src[@"label"];
            if ([lbl isKindOfClass:[NSString class]]) NWMapFollowCountry(cid, lbl);
        }
        [weakSelf rebuild];
        // Pas d'activation ni de redemarrage automatique : le conteneur reste
        // inactif dans la liste, l'utilisateur le lance en tapant dessus.
        NWAlert(@"New Container",
                [NSString stringWithFormat:@"%@ created. Tap it to launch.",
                 name.length ? name : (cid ?: @"Container")]);
    };
    sheet.modalPresentationStyle = UIModalPresentationOverFullScreen;
    sheet.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Bascule de conteneur (copy Blaze : "Are you sure you want to switch...").
- (void)confirmSwitch:(NSString *)cid name:(NSString *)name {
    __weak typeof(self) weakSelf = self;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Containers"
        message:[NSString stringWithFormat:@"Are you sure you want to switch to the %@ container? Restarting the app is required!", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Yes, I'm sure!" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NWSwitchContainer(cid);
        [weakSelf rebuild];
        NWAskRelaunch([NSString stringWithFormat:@"The container %@", name]);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// Renommage (copy Blaze).
- (void)promptRename:(NSString *)cid current:(NSString *)current {
    __weak typeof(self) weakSelf = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Rename Container"
                                                               message:@"Enter the name you want to change your container to"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Container name...";
        tf.text = current;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Rename Container" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *t = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!t.length) {
            NWAlert(@"Rename Container", @"Cannot rename the container because the name is blank!");
            return;
        }
        NWUpdateContainerField(cid, @"name", t);
        [weakSelf rebuild];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// Suppression (copy Blaze : "Are you sure you want to delete the %@ container?").
- (void)confirmDelete:(NSString *)cid name:(NSString *)name {
    __weak typeof(self) weakSelf = self;
    BOOL wasActive = [cid isEqualToString:NWActiveID];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Delete Container"
        message:[NSString stringWithFormat:@"Are you sure you want to delete the %@ container? This action cannot be undone and will delete everything associated with the container.", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Yes, I'm sure!" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        NWDeleteContainer(cid);
        [weakSelf rebuild];
        if (wasActive) NWAskRelaunch(@"Instagram");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// --- Proxy ----------------------------------------------------------------

- (void)buildProxy {
    NSDictionary *p = NWActiveProxy() ?: @{};
    id onV = p[@"on"];
    BOOL on = [onV isKindOfClass:[NSNumber class]] && [onV boolValue];
    NSString *cname = NWActiveContainerDict()[@"name"] ?: @"default";
    NSString *host = [p[@"host"] isKindOfClass:[NSString class]] ? p[@"host"] : @"";
    NSString *port = [p[@"port"] isKindOfClass:[NSString class]] ? p[@"port"] : @"";
    NSString *user = [p[@"user"] isKindOfClass:[NSString class]] ? p[@"user"] : @"";
    NSString *pass = [p[@"pass"] isKindOfClass:[NSString class]] ? p[@"pass"] : @"";
    __weak typeof(self) weakSelf = self;

    // --- Hero unifie "Proxy" ----------------------------------------------
    [self addHeroIcon:@"shield.lefthalf.filled"
                tint:NWAccent()
              kicker:@"BETA"
               title:@"Stay Invisible"
            subtitle:@"HTTPS and SOCKS5 proxy per container. Host, port and credentials below."
              badges:@[
                  @[on ? @"Proxy ON" : @"Proxy OFF", on ? NWGreen() : NWDim()],
              ]];

    // --- Section "Proxy (BETA)" (switch copy Blaze) ------------------------
    [self addSection:@"Proxy (BETA)"];
    NWSwitchRow *sw = [[NWSwitchRow alloc] initWithIcon:on ? @"shield.fill" : @"shield.lefthalf.filled"
                                                   title:@"Enable"
                                               subtitle:[NSString stringWithFormat:@"Proxy for %@ container", cname]
                                                     on:on];
    sw.iconView.tintColor = on ? NWGreen() : [UIColor colorWithWhite:1 alpha:0.25];
    sw.toggle.onTintColor = on ? NWGreen() : [UIColor colorWithWhite:1 alpha:0.25];
    [sw.heightAnchor constraintEqualToConstant:64].active = YES;
    sw.onChange = ^(BOOL value) {
        NWUpdateProxyKey(@"on", @(value));
        [weakSelf rebuild];
    };
    UIStackView *toggleCard = [self addRowsCard];
    [toggleCard addArrangedSubview:sw];

    // --- Configuration -----------------------------------------------------
    [self addSection:@"Configuration"];
    UIStackView *rows = [self addRowsCard];
    [self addRow:rows icon:@"server.rack" title:@"Host/I.P"
           value:(host.length ? host : @"No host available...") action:^{
        [weakSelf promptTextWithTitle:@"Host/I.P"
                          placeholder:@"Enter host name..."
                                value:host
                               secure:NO
                           completion:^(NSString *t) {
            NWUpdateProxyKey(@"host", t);
            [weakSelf rebuild];
        }];
    }];
    [self addRow:rows icon:@"number" title:@"Port"
           value:(port.length ? port : @"No port available...") action:^{
        [weakSelf promptTextWithTitle:@"Port"
                          placeholder:@"Enter port number..."
                                value:port
                               secure:NO
                           completion:^(NSString *t) {
            NWUpdateProxyKey(@"port", t);
            [weakSelf rebuild];
        }];
    }];

    // --- Authentication (copy Blaze) ---------------------------------------
    [self addSection:@"Authentication"];
    UIStackView *auth = [self addRowsCard];
    [self addRow:auth icon:@"lock.fill" title:@"Authentication with credentials"
           value:(user.length ? @"Enabled" : @"Disabled") action:^{
        id authV = p[@"auth"];
        BOOL authOn = [authV isKindOfClass:[NSNumber class]] && [authV boolValue];
        NWUpdateProxyKey(@"auth", @(!authOn));
        [weakSelf rebuild];
    }];
    [self addRow:auth icon:@"person" title:@"Username"
           value:(user.length ? user : @"No username available...") action:^{
        [weakSelf promptTextWithTitle:@"Username"
                          placeholder:@"Enter username..."
                                value:user
                               secure:NO
                           completion:^(NSString *t) {
            NWUpdateProxyKey(@"user", t);
            [weakSelf rebuild];
        }];
    }];
    [self addRow:auth icon:@"lock.shield.fill" title:@"Password"
           value:(pass.length ? @"••••••••" : @"No password available...") action:^{
        [weakSelf promptTextWithTitle:@"Password"
                          placeholder:@"Enter password..."
                                value:pass
                               secure:YES
                           completion:^(NSString *t) {
            NWUpdateProxyKey(@"pass", t);
            [weakSelf rebuild];
        }];
    }];

    // --- Actions (copy Blaze) ---------------------------------------------
    [self addSection:@"Actions"];
    UIStackView *tools = [self addRowsCard];
    [self addRow:tools icon:@"globe" title:@"I.P Checker"
           value:@"Proxy connection and details" action:^{
        [weakSelf checkIP];
    }];
    [self addRow:tools icon:@"trash.fill" title:@"Proxy data to default settings"
           value:@"Reset" action:^{
        NWUpdateContainerField(NWActiveID, @"proxy",
                               @{@"on": @NO, @"host": @"", @"port": @"", @"user": @"", @"pass": @""});
        NWAlert(@"Proxy", @"Proxy successfully reset to default settings");
        [weakSelf rebuild];
    }];
}

- (void)checkIP {
    NSURL *url = [NSURL URLWithString:@"https://api.ipify.org?format=json"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"nine9wham/1.1" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSString *ip = nil;
        if (data) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) ip = j[@"ip"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ip.length) {
                NWAlert(@"I.P Address", ip);
            } else {
                NWAlert(@"I.P Address", @"Failed to check for I.P data, please try again later.");
            }
            (void)weakSelf;
        });
    }] resume];
}

// --- Changelog / Support / Reset -----------------------------------------

- (void)buildChangelog {
    [self addSection:@"Version 1.3.0 · 04/11/2026"];
    UIStackView *v4 = [self addPaddedCard];
    UILabel *b4 = NWLabelMake(
        @"• Device identity floating button: device ID, family ID, machine ID\n"
         "• Mask everything & relaunch, roll a new fingerprint, manual IDs\n"
         "• Block Apple attestation (DeviceCheck / App Attest), off by default\n"
         "• Keychain C calls (SecItem*) now get the real access group\n"
         "• Group containers + CloudKit entitlements repaired for sideload\n"
         "• Safe mode: disable all tweaks & relaunch (Support → Crash log)",
        12.5, [UIColor colorWithWhite:0.85 alpha:1], UIFontWeightRegular);
    [v4 addArrangedSubview:b4];

    [self addSection:@"Version 1.2.1 · 03/11/2026"];
    UIStackView *v3 = [self addPaddedCard];
    UILabel *b3 = NWLabelMake(
        @"• Translucent square floating button with the 4-square icon (no badge)\n"
         "• Frosted-glass cards and container cells, unified module heroes\n"
         "• Map: long-press drops an arrow on the exact spot, type bar removed\n"
         "• Readable dark navigation bar, solid search field, no dead ends",
        12.5, [UIColor colorWithWhite:0.85 alpha:1], UIFontWeightRegular);
    [v3 addArrangedSubview:b3];

    [self addSection:@"Version 1.2.0 · 03/11/2026"];
    UIStackView *v2 = [self addPaddedCard];
    UILabel *b2 = NWLabelMake(
        @"• Menu rebuilt on the Blaze design: dashboard, grid, cards, icons\n"
         "• Full-screen world map picker with search (OpenStreetMap / Nominatim)\n"
         "• Map icon on every new container creation\n"
         "• Ghost master switch (Enable · Ghost for ... container)\n"
         "• Container dialogs copied from Blaze: New / Rename / Delete\n"
         "• Fake GPS: real location no longer overwrites the spoofed one",
        12.5, [UIColor colorWithWhite:0.85 alpha:1], UIFontWeightRegular);
    [v2 addArrangedSubview:b2];

    [self addSection:@"Version 1.1.0 · 02/11/2026"];
    UIStackView *card = [self addPaddedCard];
    UILabel *body = NWLabelMake(
        @"• Floating button made persistent (dedicated overlay window)\n"
         "• iPhone 13 → 17 models and iOS 26.0 → 27.0.1\n"
         "• Immediate fake GPS + world search\n"
         "• Ghost: model, iOS, RAM, locale, timezone, IDFV / IDFA\n"
         "• Containers: create, rename, switch, delete\n"
         "• Instagram 453.0 base cleaned (no injected extras)",
        12.5, [UIColor colorWithWhite:0.85 alpha:1], UIFontWeightRegular);
    [card addArrangedSubview:body];

    [self addSection:@"Version 1.0.0"];
    UIStackView *old = [self addPaddedCard];
    UILabel *o = NWLabelMake(@"• First release: containers, fingerprint, fake GPS, keychain vault.",
                             12.5, NWDim(), UIFontWeightRegular);
    [old addArrangedSubview:o];
}

// ---------------------------------------------------------------------------
// Module "Device identity" (vague 7) — items exactement ceux du menu
// flottant : Real • <court>, Machine ID / No machine ID yet, Mask
// everything & relaunch, Roll a new fingerprint, Enter ID manually...,
// Enter machine ID manually..., Copy current ID, Copy machine ID, Block
// Apple attestation: Off/On, Relaunch now, Hide button until relaunch.
// ---------------------------------------------------------------------------
- (void)buildDeviceIdentity {
    __weak typeof(self) weakSelf = self;

    [self addSection:NWL(@"dev_title", @"Device identity",
                         @"Identite de l'appareil",
                         @"Identidad del dispositivo")];
    // --- "How it works" : le fonctionnement est explique DANS l'ecran -------
    UIStackView *how = [self addPaddedCard];
    UILabel *howTitle = NWLabelMake(NWL(@"dev_how_t", @"How it works",
                                        @"Comment ca marche", @"Como funciona"),
                                    14, UIColor.whiteColor, UIFontWeightSemibold);
    [how addArrangedSubview:howTitle];
    UILabel *howBody = NWLabelMake(NWL(@"dev_how_b",
        @"Each container is a different iPhone.\n"
        @"• Country and language come from the container, or from the city you pick when creating an account.\n"
        @"• Device ID, Machine ID and the rest are generated automatically for every new container: no conflicts.\n"
        @"• Mask / Roll only changes this container, never the others.\n"
        @"• After a country or language change, Instagram must be relaunched to translate.",
        @"Chaque conteneur est un iPhone different.\n"
        @"• Le pays et la langue viennent du conteneur, ou de la ville choisie a la creation du compte.\n"
        @"• Device ID, Machine ID et le reste sont generes automatiquement pour chaque nouveau conteneur : aucun conflit.\n"
        @"• Mask / Roll ne modifie que ce conteneur, jamais les autres.\n"
        @"• Apres un changement de pays ou de langue, Instagram doit etre relance pour se traduire.",
        @"Cada contenedor es un iPhone distinto.\n"
        @"• El pais y el idioma vienen del contenedor, o de la ciudad elegida al crear la cuenta.\n"
        @"• Device ID, Machine ID y lo demas se generan automaticamente en cada contenedor: sin conflictos.\n"
        @"• Mask / Roll solo cambia este contenedor, nunca los otros.\n"
        @"• Tras cambiar pais o idioma, Instagram debe reiniciarse para traducirse."),
        12, NWDim(), UIFontWeightRegular);
    howBody.numberOfLines = 0;
    [how addArrangedSubview:howBody];

    // --- "This container" : etat reel, pour verifier d'un coup d'oeil --------
    UIStackView *tc = [self addPaddedCard];
    UILabel *tcTitle = NWLabelMake(NWL(@"dev_tc_t", @"This container",
                                        @"Ce conteneur", @"Este contenedor"),
                                    14, UIColor.whiteColor, UIFontWeightSemibold);
    [tc addArrangedSubview:tcTitle];

    NSDictionary *cont = NWActiveContainerDict();
    NSString *cname = [cont[@"name"] isKindOfClass:[NSString class]] ? cont[@"name"] : @"—";
    NSString *locId = NWActiveFP[@"locale"];
    NSString *cc = nil, *lang = nil;
    if ([locId isKindOfClass:[NSString class]] && locId.length >= 2) {
        NSArray *parts = [locId componentsSeparatedByString:@"_"];
        lang = parts.firstObject;
        cc = parts.count > 1 ? parts.lastObject : nil;
    }
    NSString *where = @"—";
    if (cc.length == 2) {
        where = [NSString stringWithFormat:@"%@ · %@",
                 NWCountryDisplayName(cc), NWLanguageDisplayName(lang)];
    }
    NSString *hw = [NSString stringWithFormat:@"%@ · iOS %@",
                    NWModelName(NWActiveFP[@"model"]),
                    NWActiveFP[@"sysVer"] ?: UIDevice.currentDevice.systemVersion];
    UILabel *tcBody = NWLabelMake([NSString stringWithFormat:
        @"%@: %@\n%@: %@\n%@: %@",
        NWL(@"dev_tc_name", @"Container", @"Conteneur", @"Contenedor"), cname,
        NWL(@"dev_tc_where", @"Country & language", @"Pays & langue", @"Pais e idioma"), where,
        NWL(@"dev_tc_dev", @"Device", @"Appareil", @"Dispositivo"), hw],
        12, NWDim(), UIFontWeightRegular);
    tcBody.numberOfLines = 0;
    [tc addArrangedSubview:tcBody];

    UIStackView *c = [self addRowsCard];

    NSString *curID = NWDevDevIDCurrent();
    NSString *curMid = NWDevMidCurrent();

    // Real • <5 derniers caracteres de l'identite courante>
    [self addRow:c icon:@"fingerprint"
            title:NWL(@"dev_real", @"Real •", @"Reel •", @"Real •")
            value:curID.length ? NWDevShort(curID) : @"—"
           action:nil];

    // Machine ID (= mid) : "No machine ID yet" tant que non pose.
    [self addRow:c icon:@"number"
            title:NWL(@"dev_mid", @"Machine ID", @"ID machine", @"ID de maquina")
            value:curMid.length ? curMid
 : NWL(@"dev_no_mid", @"No machine ID yet", @"Aucun ID machine", @"Sin ID de maquina")
           action:nil];

    // Mask everything & relaunch
    [self addRow:c icon:@"theatermasks"
            title:NWL(@"dev_mask", @"Mask everything & relaunch",
                      @"Tout masquer & relancer",
                      @"Enmascarar todo y reiniciar")
            value:nil
           action:^{
        NWDevRollIdentity(YES);
        NWAlert(NWL(@"dev_masked", @"Masked", @"Masque", @"Enmascarado"),
                NWL(@"dev_masked2", @"New device identity. Relaunching...",
                    @"Nouvelle identite d'appareil. Relance...",
                    @"Nueva identidad. Reiniciando..."));
        NWAskRelaunchLater(@"Instagram");
    }];

    // Roll a new fingerprint
    [self addRow:c icon:@"dice"
            title:NWL(@"dev_roll", @"Roll a new fingerprint",
                      @"Nouvelle empreinte", @"Nueva huella")
            value:nil
           action:^{
        NWDevRollIdentity(NO);
        [weakSelf rebuild];
        NWAlert(NWL(@"dev_rolled", @"Rolled", @"Renouvelee", @"Renovada"),
                NWL(@"dev_rolled2", @"Fresh device identity generated.",
                    @"Nouvelle identite d'appareil generee.",
                    @"Nueva identidad de dispositivo generada."));
    }];

    // Enter ID manually...
    [self addRow:c icon:@"square.and.pencil"
            title:NWL(@"dev_enter_id", @"Enter ID manually...",
                      @"Entrer l'ID manuellement...",
                      @"Introducir ID manualmente...")
            value:nil
           action:^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:NWL(@"dev_enter_id", @"Enter ID manually...",
                                         @"Entrer l'ID manuellement...",
                                         @"Introducir ID manualmente...")
                             message:nil
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"E4E47...";
            tf.text = NWDevGetStr(NWDevKeyDevID);
            tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [a addAction:[UIAlertAction actionWithTitle:NWL(@"dev_set", @"Set", @"Definir", @"Establecer")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            NSString *v = a.textFields.firstObject.text;
            if (v.length) {
                NWDevSetStr(NWDevKeyDevID, v);
                [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:NWDevKeyOn];
                if (NWActiveID) [[NSUserDefaults standardUserDefaults] setObject:NWActiveID forKey:NWDevKeyPinOwner];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [weakSelf rebuild];
            }
        }]];
        [a addAction:[UIAlertAction actionWithTitle:NWL(@"cancel", @"Cancel", @"Annuler", @"Cancelar")
                                              style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:a animated:YES completion:nil];
    }];

    // Enter machine ID manually...
    [self addRow:c icon:@"number.circle"
            title:NWL(@"dev_enter_mid", @"Enter machine ID manually...",
                      @"Entrer l'ID machine manuellement...",
                      @"Introducir ID de maquina manualmente...")
            value:nil
           action:^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:NWL(@"dev_enter_mid", @"Enter machine ID manually...",
                                         @"Entrer l'ID machine manuellement...",
                                         @"Introducir ID de maquina manualmente...")
                             message:nil
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"687C4B6F-...";
            tf.text = NWDevGetStr(NWDevKeyMid);
            tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [a addAction:[UIAlertAction actionWithTitle:NWL(@"dev_set", @"Set", @"Definir", @"Establecer")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
            NSString *v = a.textFields.firstObject.text;
            if (v.length) {
                NWDevSetStr(NWDevKeyMid, v);
                [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:NWDevKeyOn];
                if (NWActiveID) [[NSUserDefaults standardUserDefaults] setObject:NWActiveID forKey:NWDevKeyPinOwner];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [weakSelf rebuild];
            }
        }]];
        [a addAction:[UIAlertAction actionWithTitle:NWL(@"cancel", @"Cancel", @"Annuler", @"Cancelar")
                                              style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:a animated:YES completion:nil];
    }];

    // Copy current ID
    [self addRow:c icon:@"doc.on.doc"
            title:NWL(@"dev_copy_id", @"Copy current ID", @"Copier l'ID actuel", @"Copiar ID actual")
            value:nil
           action:^{
        NSString *v = NWDevDevIDCurrent();
        UIPasteboard.generalPasteboard.string = v ?: @"";
        NWAlert(NWL(@"dev_copy_id", @"Copy current ID", @"Copier l'ID actuel", @"Copiar ID actual"),
                v.length ? v : NWL(@"dev_none", @"Nothing to copy", @"Rien a copier", @"Nada que copiar"));
    }];

    // Copy machine ID
    [self addRow:c icon:@"doc.on.doc.fill"
            title:NWL(@"dev_copy_mid", @"Copy machine ID", @"Copier l'ID machine", @"Copiar ID de maquina")
            value:nil
           action:^{
        NSString *v = NWDevMidCurrent();
        UIPasteboard.generalPasteboard.string = v ?: @"";
        NWAlert(NWL(@"dev_copy_mid", @"Copy machine ID", @"Copier l'ID machine", @"Copiar ID de maquina"),
                v.length ? v : NWL(@"dev_no_mid", @"No machine ID yet", @"Aucun ID machine", @"Sin ID de maquina"));
    }];

    // Block Apple attestation: Off / On (defaut Off)
    [self addRow:c icon:@"shield.slash"
            title:[NSString stringWithFormat:
                    NWL(@"dev_attest", @"Block Apple attestation: %@",
                        @"Bloquer l'attestation Apple : %@",
                        @"Bloquear atestacion Apple: %@"),
                    NWBlockAttest() ? NWL(@"dev_on", @"On", @"Oui", @"Si")
                                    : NWL(@"dev_off", @"Off", @"Non", @"No")]
            value:nil
           action:^{
        BOOL cur = NWBlockAttest();
        [[NSUserDefaults standardUserDefaults] setObject:(cur ? @NO : @YES) forKey:NWDevKeyAttBlock];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [weakSelf rebuild];
    }];

    // Relaunch now
    [self addRow:c icon:@"arrow.triangle.2.circlepath"
            title:NWL(@"dev_relaunch", @"Relaunch now", @"Relancer maintenant", @"Reiniciar ahora")
            value:nil
           action:^{
        NWAskRelaunchLater(@"Instagram");
    }];

    // Hide button until relaunch (one-shot : consomme au boot suivant)
    [self addRow:c icon:@"eye.slash"
            title:NWL(@"dev_hide", @"Hide button until relaunch",
                      @"Masquer le bouton jusqu'au relancement",
                      @"Ocultar el boton hasta reiniciar")
            value:nil
           action:^{
        [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:NWDevKeyHidePill];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NWDevicePillButton.hidden = YES;
        NWAlert(NWL(@"dev_hidden", @"Hidden", @"Masque", @"Oculto"),
                NWL(@"dev_hidden2", @"The Device identity button is hidden until the next relaunch.",
                    @"Le bouton Device identity est masque jusqu'au prochain relancement.",
                    @"El boton Device identity esta oculto hasta el proximo reinicio."));
    }];
}

- (void)buildSupport {
    __weak typeof(self) weakSelf = self;

    // --- Section "Support" (copy Blaze) ------------------------------------
    [self addSection:@"Support"];
    UIStackView *rows = [self addRowsCard];
    [self addRow:rows icon:@"paperplane.fill" title:@"Mon Telegram"
           value:@"@nine9wham" action:^{
        NSURL *u = [NSURL URLWithString:@"https://github.com/mpouki04-tech/nine9wham"];
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
        (void)weakSelf;
    }];
    [self addRow:rows icon:@"quote.bubble.fill" title:@"Telegram - @nine9wham"
           value:@"Join our channel" action:^{
        NSURL *u = [NSURL URLWithString:@"https://github.com/mpouki04-tech/nine9wham/releases"];
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }];

    // --- Section "nine9wham" ----------------------------------------------
    [self addSection:@"nine9wham"];
    UIStackView *info = [self addRowsCard];
    [self addRow:info icon:@"link" title:@"GitHub"
           value:@"mpouki04-tech/nine9wham" action:^{
        NSURL *u = [NSURL URLWithString:@"https://github.com/mpouki04-tech/nine9wham"];
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }];
    [self addRow:info icon:@"arrow.down.circle" title:@"Download"
           value:@"Release nine9wham" action:^{
        NSURL *u = [NSURL URLWithString:@"https://github.com/mpouki04-tech/nine9wham/releases"];
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }];
    [self addRow:info icon:@"doc.on.doc" title:@"Copy link"
           value:@"Release page copied" action:^{
        UIPasteboard.generalPasteboard.string = @"https://github.com/mpouki04-tech/nine9wham/releases";
        NWAlert(@"nine9wham", @"The token data was copied to the clipboard");
    }];
    [self addRow:info icon:@"number" title:@"Version"
           value:[NSString stringWithFormat:@"Version: %@",
                   NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"453.0"]
          action:nil];

    // Preuve du plantage (creation de compte) : nom + raison + pile, ecrits
    // par le rapporteur installe au demarrage. A consulter apres un crash.
    NSString *crashPath = NWCrashLogPath();
    BOOL hasCrash = [[NSFileManager defaultManager] fileExistsAtPath:crashPath];
    [self addRow:info icon:@"exclamationmark.triangle" title:@"Crash log"
           value:hasCrash ? @"View / copy" : @"None yet"
          action:^{
        NSString *txt = [NSString stringWithContentsOfFile:NWCrashLogPath()
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (!txt.length) {
            NWAlert(@"Crash log", @"No crash recorded yet.");
            return;
        }
        NSString *shown = txt.length > 1400 ? [txt substringFromIndex:txt.length - 1400] : txt;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Crash log"
                                                                   message:shown
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            UIPasteboard.generalPasteboard.string = txt;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:a animated:YES completion:nil];
    }];

    // Safe mode (vague 7) : coupe TOUS les hooks au prochain lancement. En
    // cas de doute sur un plantage, c'est le diagnostic de base.
    [self addRow:info icon:@"power"
            title:NWL(@"safe_off", @"Disable all tweaks & relaunch",
                      @"Desactiver tous les tweaks & relancer",
                      @"Desactivar todos los ajustes y reiniciar")
            value:NWL(@"safe_off_v", @"Safe mode on next launch",
                      @"Mode securise au prochain lancement",
                      @"Modo seguro en el proximo arranque")
           action:^{
        [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:NWSafeModeKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NWAskRelaunchLater(@"Instagram");
    }];

    // Entree directe vers le module Device identity (le pill flottant
    // disparait si l'utilisateur a choisi « Hide button until relaunch »).
    [self addRow:info icon:@"fingerprint"
            title:NWL(@"dev_open", @"Device identity",
                      @"Identite de l'appareil", @"Identidad del dispositivo")
            value:NWL(@"dev_open_v", @"IDs, machine ID, attestation",
                      @"IDs, ID machine, attestation",
                      @"IDs, ID de maquina, atestacion")
           action:^{
        NWCloseMenu();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NWOpenDeviceIdentity();
        });
    }];

    UILabel *foot = NWLabelMake(@"Instagram modified · isolated containers · fake GPS · ghost fingerprint",
                                11, NWDim(), UIFontWeightRegular);
    foot.textAlignment = NSTextAlignmentCenter;
    [self.content addArrangedSubview:foot];

    // --- Section "Backup & Restore" (survie re-install Sideloadly / mise a jour) ---
    [self addSection:@"Backup & Restore"];
    UIStackView *bak = [self addRowsCard];
    [self addRow:bak icon:@"arrow.down.to.square" title:@"Export backup"
           value:NWL(@"bk_exp", @"Encrypted backup of all accounts",
                     @"Sauvegarde chiffree de tous les comptes",
                     @"Cifrado de todas las cuentas") action:^{
        [weakSelf promptBackupPassword:YES completion:^(NSString *pw) {
            NSError *err = nil;
            NSString *path = NWBackupExport(pw, &err);
            if (path) {
                NWAlert(NWL(@"bk_done", @"Backup exported", @"Backup exporte", @"Backup exportado"),
                        [NSString stringWithFormat:@"%@: %@", NWL(@"file", @"File", @"Fichier", @"Archivo"),
                         path.lastPathComponent]);
            } else {
                NWAlert(NWL(@"err_exp", @"Export error", @"Erreur export", @"Error de exportacion"),
                        err.localizedDescription ?: NWL(@"fail", @"Failed", @"Echec", @"Fallo"));
            }
        }];
    }];
    [self addRow:bak icon:@"arrow.up.from.square" title:@"Import backup"
           value:NWL(@"bk_imp", @"Restore accounts from a file",
                     @"Restaurer les comptes depuis un fichier",
                     @"Restaurar cuentas desde un archivo") action:^{
        NSArray *backups = NWListBackups();
        if (backups.count == 0) {
            NWAlert(NWL(@"no_bk", @"No backup", @"Aucun backup", @"Sin backup"),
                    NWL(@"no_bk2", @"No backup found in Documents/nine9wham_backups/",
                        @"Aucune sauvegarde trouvee dans Documents/nine9wham_backups/",
                        @"No se encontro ninguna copia en Documents/nine9wham_backups/"));
            return;
        }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:NWL(@"choose_bk", @"Choose a backup", @"Choisir un backup", @"Elegir un backup")
                                                                   message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *f in backups) {
            [a addAction:[UIAlertAction actionWithTitle:f
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * _Nonnull act) {
                [weakSelf promptBackupPassword:NO completion:^(NSString *pw) {
                    NSString *path = [NWBackupDir() stringByAppendingPathComponent:f];
                    NSError *err = nil;
                    if (NWBackupImport(path, pw, &err)) {
                        NWAlert(NWL(@"bk_restored", @"Backup restored", @"Backup restaure", @"Backup restaurado"),
                                NWL(@"bk_restored2", @"All accounts were restored. Restarting...",
                                    @"Tous les comptes ont ete restaures. Redemarrage...",
                                    @"Todas las cuentas fueron restauradas. Reiniciando..."));
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{ exit(0); });
                    } else {
                        NWAlert(NWL(@"err_imp", @"Import error", @"Erreur import", @"Error de importacion"),
                                err.localizedDescription ?: NWL(@"fail", @"Failed", @"Echec", @"Fallo"));
                    }
                }];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:NWL(@"cancel", @"Cancel", @"Annuler", @"Cancelar")
                                             style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                self.view.bounds.size.height - 80, 1, 1);
        [self presentViewController:a animated:YES completion:nil];
    }];
}

- (void)buildReset {
    __weak typeof(self) weakSelf = self;

    [self addSection:@"Reset"];
    UIStackView *card = [self addRowsCard];
    [self addRow:card icon:@"trash.fill" title:@"Erase nine9wham's"
           value:@"Containers & settings to default" action:^{
        [weakSelf confirmReset];
    }];

    UILabel *note = NWLabelMake(@"If you only want to delete a container, do it from the container list.",
                                11, NWDim(), UIFontWeightRegular);
    [self.content addArrangedSubview:note];
}

- (void)promptBackupPassword:(BOOL)isExport completion:(void (^)(NSString *password))completion {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:isExport ? @"Export backup" : @"Import backup"
                                                                message:isExport ? NWL(@"pw_exp", @"Password to encrypt the backup:", @"Mot de passe pour chiffrer la sauvegarde :", @"Contrasena para cifrar la copia :") : NWL(@"pw_imp", @"Password to decrypt the backup:", @"Mot de passe pour dechiffrer la sauvegarde :", @"Contrasena para descifrar la copia :")
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = NWL(@"pw", @"Password", @"Mot de passe", @"Contrasena");
        tf.secureTextEntry = YES;
    }];
    [al addAction:[UIAlertAction actionWithTitle:isExport ? NWL(@"export", @"Export", @"Exporter", @"Exportar")
                                                            : NWL(@"import", @"Import", @"Importer", @"Importar")
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull act) {
        NSString *pw = al.textFields.firstObject.text ?: @"";
        if (completion) completion(pw);
    }]];
    [al addAction:[UIAlertAction actionWithTitle:NWL(@"cancel", @"Cancel", @"Annuler", @"Cancelar") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

// Confirmation du reset (copy Blaze : "Yes, I'm sure!" / "Cancel").
- (void)confirmReset {
    __weak typeof(self) weakSelf = self;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"nine9wham"
        message:@"Are you sure you want to reset nine9wham? Please note it will erase everything including all containers, settings and any config files. If you only want to delete the container then please do it from the container list."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Yes, I'm sure!" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [[NSFileManager defaultManager] removeItemAtPath:NWSupportDir() error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:NWStatePath() error:nil];
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NWBundleID()];
        [NSUserDefaults.standardUserDefaults synchronize];
        [NSHTTPCookieStorage.sharedHTTPCookieStorage removeCookiesSinceDate:[NSDate dateWithTimeIntervalSince1970:0]];
        NWVaultDelete();
        NWState = @{};
        NWActiveID = nil;
        NWActiveFP = nil;
        NWActiveLoc = nil;
        NWLog("reset complet effectue");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    (void)weakSelf;
}

// --- Outils du dashboard --------------------------------------------------

- (void)promptTextWithTitle:(NSString *)title
                placeholder:(NSString *)placeholder
                      value:(NSString *)value
                     secure:(BOOL)secure
                 completion:(void (^)(NSString *text))completion {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = placeholder;
        tf.text = value ?: @"";
        tf.secureTextEntry = secure;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *t = a.textFields.firstObject.text ?: @"";
        if (completion) completion(t);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)presentOptions:(NSArray<NSDictionary *> *)options
              selected:(NSString *)selected
               heading:(NSString *)heading
                  pick:(void (^)(NSDictionary *option))pick {
    NWOptionPickerVC *p = [[NWOptionPickerVC alloc] init];
    p.options = options;
    p.selectedValue = selected;
    p.heading = heading;
    p.onPick = pick;
    p.modalPresentationStyle = UIModalPresentationOverFullScreen;
    p.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:p animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// Ouverture / fermeture du dashboard
// ---------------------------------------------------------------------------

// Ouverture d'un module du dashboard. Les appels historiques passent par
// NWOpenMenu (Containers) ; le pill Device identity ouvre "deviceid".
static void NWOpenModuleMenu(NSString *module) {
    if (NWDashInstance) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NWInstallFloatingButton();
    NWDashboardViewController *d = [[NWDashboardViewController alloc] init];
    // Copy Blaze : le bouton flottant ouvre directement la liste Containers
    // (grille Dashboard accessible via le chevron en haut a gauche).
    d.module = module.length ? module : @"containers";
    d.modalPresentationStyle = UIModalPresentationOverFullScreen;
    d.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    NWDashInstance = d;
    UIViewController *top = NWTopVC();
    if (top.presentedViewController) {
        NWDashInstance = nil;
        return;
    }
    [top presentViewController:d animated:YES completion:nil];
    NWLog("dashboard ouvert (%@)", d.module);
}

static void NWOpenMenu(void) { NWOpenModuleMenu(@"containers"); }

static void NWOpenDeviceIdentity(void) { NWOpenModuleMenu(@"deviceid"); }

static void NWCloseMenu(void) {
    UIViewController *d = NWDashInstance;
    NWDashInstance = nil;
    [d dismissViewControllerAnimated:YES completion:nil];
}

static void NWTogglePanel(void) {
    // Toujours en @try : appele depuis touchesEnded du bouton flottant, une
    // exception UIKit ("not in the window hierarchy") tuerait l'app.
    @try {
        if (NWDashInstance) NWCloseMenu();
        else NWOpenMenu();
    } @catch (NSException *e) {
        NWLog("toggle panel: %@", e.reason);
        NWDashInstance = nil;
    }
}

// ---------------------------------------------------------------------------
// Hook proxy NSURLSession (best effort, Instagram utilise son propre reseau)
// ---------------------------------------------------------------------------

static id (*NWOrig_defaultSessionCfg)(id, SEL);
static id NWHook_defaultSessionCfg(id self, SEL _cmd) {
    // Securise : la moindre exception ici tue l'app au moment ou Instagram
    // ouvre une session (verification du nom de compte = creation de compte).
    id cfg = nil;
    @try {
        cfg = NWOrig_defaultSessionCfg ? NWOrig_defaultSessionCfg(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("defaultSessionConfiguration: %@", e.reason);
    }
    // Si l'original a ete avale, on fournit quand meme une configuration
    // valide : retourner nil ferait planter sessionWithConfiguration: au
    // moment ou Instagram verifie le nom de compte (= creation de compte).
    if (!cfg) {
        @try { cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration]; }
        @catch (NSException *e) { NWLog("ephemeralSessionConfiguration: %@", e.reason); }
    }
    if (!cfg) {
        @try { cfg = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.nine9wham.fb"]; }
        @catch (NSException *e) { NWLog("backgroundSessionConfiguration: %@", e.reason); }
    }
    if (!cfg) return cfg;   // dernier recours (quasi impossible)
    @try {
        NSDictionary *p = NWActiveProxy();
        if (![p isKindOfClass:[NSDictionary class]]) return cfg;
        id on = p[@"on"], host = p[@"host"], port = p[@"port"];
        BOOL enabled = [on isKindOfClass:[NSNumber class]] && [on boolValue];
        NSString *h = [host isKindOfClass:[NSString class]] ? host : nil;
        NSString *po = [port isKindOfClass:[NSString class]] ? port : nil;
        if (enabled && h.length && po.length && cfg) {
            NSMutableDictionary *proxy = [NSMutableDictionary dictionary];
            proxy[@"HTTPSEnable"] = @YES;
            proxy[@"HTTPSProxy"] = h;
            proxy[@"HTTPSPort"] = @([po integerValue]);
            proxy[@"HTTPEnable"] = @YES;
            proxy[@"HTTPProxy"] = h;
            proxy[@"HTTPPort"] = @([po integerValue]);
            [cfg setConnectionProxyDictionary:proxy];
        }
    } @catch (NSException *e) {
        NWLog("proxy ignore: %@", e.reason);
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// Sideload fix v2 — conteneurs de groupe + keychain en trois couches
// ---------------------------------------------------------------------------
// PREUVE (projets independants qui fonctionnent) :
//   - IGSideloadFix : "Fix crash on login when Instagram is installed via
//     sideloading" -> hook NSFileManager (conteneur de groupe) + accessGroup
//     keychain (FBSDKKeychainStore / FBKeychainItemController / UICKeyChainStore).
// MECANISME : en sideloading le certificat personnel n'a PAS l'entitlement
//   com.apple.security.application-groups -> la methode renvoie nil (et
//   l'access group keychain reel n'est pas celui qu'Instagram demande ->
//   errSecMissingEntitlement). Instagram plante a l'inscription sur ce nil.
// COUCHE 1 : conteneur de groupe FACTICE dans Documents/FakeGroupContainers
//           (creer les dossiers, comme IGSideloadFix).
// COUCHE 2 : accessGroup = le VRAI groupe du certificat, obtenu en posant un
//           item bidon dans le keychain (puis supprime).
// COUCHE 3 (vague 7) : le chemin C — Instagram appelle SecItem* en C avec
//           kSecAttrAccessGroup en dur -> reecriture du groupe dans les
//           wrappers SecItemAdd/CopyMatching/Update/Delete (rebinding de
//           toutes les images), LSBundleProxy.groupContainerURLs (merge) et
//           CKEntitlements (entitlements CloudKit).
// Note : InstagramAppCoreFramework est ABSENT des bases 453/454 (compile en
//   statique) -> le dlopen d'IGSideloadFix est inutile ici.

static NSString *NWAccessGroupReal = nil;
static NSInteger NWAccessGroupTries = 0;
static NSURL *(*NWOrig_containerURL)(id, SEL, NSString *);

// Vrai access group du certificat : un item bidon SANS accessGroup est
// assigne par le systeme au groupe reel de l'app (celui du profil).
static void NWLoadAccessGroupReal(void) {
    if (NWAccessGroupReal.length || NWAccessGroupTries >= 3) return;
    NWAccessGroupTries++;

    // Vague 10 : la sonde SecItemAdd depend d'un ajout reussi, qui peut etre
    // refuse si le profil Sideloadly n'accorde pas le groupe attendu. Le shim
    // RyukGram, lui, lisait directement l'entitlement du certificat
    // ("application-identifier", cstring "MH9GU9K5PX."). On fait pareil en
    // premier : c'est la source de verite du profil signe.
    // ATTENTION : un access group keychain est le plus souvent le prefixe
    // d'equipe COLLE au bundle id ("MH9GU9K5PX.com.burbn.instagram"). On ne
    // retire donc PAS le prefixe : on garde la valeur entiere.
    @try {
        typedef const struct __NW_SecTask *NWSecTaskRef;
        NWSecTaskRef (*createTask)(CFAllocatorRef) =
            (NWSecTaskRef (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        CFTypeRef (*copyEnt)(NWSecTaskRef, CFStringRef, CFErrorRef *) =
            (CFTypeRef (*)(NWSecTaskRef, CFStringRef, CFErrorRef *))
            dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
        if (createTask && copyEnt) {
            NWSecTaskRef task = createTask(NULL);
            if (task) {
                NSString *appid = nil;
                CFTypeRef appidRef = copyEnt(task, CFSTR("application-identifier"), NULL);
                if (appidRef && CFGetTypeID(appidRef) == CFStringGetTypeID()) {
                    appid = [(__bridge NSString *)appidRef copy];
                }

                // 1) keychain-access-groups : LE groupe reel du profil. On
                //    prefere celui qui correspond a application-identifier,
                //    sinon le premier de la liste.
                CFTypeRef groups = copyEnt(task, CFSTR("keychain-access-groups"), NULL);
                if (groups && CFGetTypeID(groups) == CFArrayGetTypeID()) {
                    CFArrayRef arr = (CFArrayRef)groups;
                    NSString *first = nil, *match = nil;
                    for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                        CFTypeRef g = CFArrayGetValueAtIndex(arr, i);
                        if (!g || CFGetTypeID(g) != CFStringGetTypeID()) continue;
                        NSString *gs = (__bridge NSString *)g;
                        if (!first.length) first = [gs copy];
                        if (appid.length && [gs isEqualToString:appid]) { match = [gs copy]; break; }
                    }
                    NWAccessGroupReal = match.length ? match : first;
                }
                if (groups) CFRelease(groups);

                // 2) Repli : application-identifier entier (identique au
                //    groupe keychain par defaut sur un profil standard).
                if (!NWAccessGroupReal.length && appid.length) {
                    NWAccessGroupReal = appid;
                }
                if (appidRef) CFRelease(appidRef);
                CFRelease(task);
                if (NWAccessGroupReal.length)
                    NWLog("sideload: access group entitlement = %@", NWAccessGroupReal);
            }
        }
        if (NWAccessGroupReal.length) return;
    } @catch (NSException *e) {
        NWLog("sideload entitlement access group: %@", e.reason);
    }

    @try {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"nine9wham.sideload",
            (__bridge id)kSecAttrService: @"nine9wham.sideload",
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        };
        // SecItemAdd n'accepte pas kSecMatchLimit : dictionnaire separe.
        NSDictionary *add = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"nine9wham.sideload",
            (__bridge id)kSecAttrService: @"nine9wham.sideload",
            (__bridge id)kSecReturnAttributes: @YES,
        };
        CFTypeRef res = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &res);
        if (st == errSecItemNotFound) st = SecItemAdd((__bridge CFDictionaryRef)add, &res);
        // Garde de type : sans MatchLimit le systeme peut renvoyer un NSArray.
        if (st == errSecSuccess && res && CFGetTypeID(res) == CFDictionaryGetTypeID()) {
            NSString *g = ((__bridge NSDictionary *)res)[(__bridge id)kSecAttrAccessGroup];
            if ([g isKindOfClass:[NSString class]] && g.length) {
                NWAccessGroupReal = g;
                NWLog("sideload: access group reelle = %@", g);
            }
        }
        if (res) CFRelease(res);
        // Nettoyage de l'item bidon (la valeur est deja retenue).
        SecItemDelete((__bridge CFDictionaryRef)@{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"nine9wham.sideload",
            (__bridge id)kSecAttrService: @"nine9wham.sideload",
        });
    } @catch (NSException *e) {
        NWLog("sideload access group: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Antidetection v2 : CHAPITRE C (le vrai cap manquant).
// Instagram va au keychain en C DIRECT : SecItemAdd/CopyMatching/Update/
// Delete avec kSecAttrAccessGroup pose en dur. Les wrappers ci-dessous sont
// installes par le rebinding global (NWRbFillTargets) : chaque requete
// portant un access group dont l'app n'a pas le droit est re-ecrite vers le
// vrai groupe du certificat (NWAccessGroupReal, sonde SecItemParams).
// ---------------------------------------------------------------------------

// Reels (remplis par le rebinding global) :
static OSStatus (*NWSecReal_Add)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NWSecReal_CopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*NWSecReal_Update)(CFDictionaryRef, CFDictionaryRef, CFTypeRef *);
static OSStatus (*NWSecReal_Delete)(CFDictionaryRef);

// Copie mutable de la requete avec kSecAttrAccessGroup remplace par le VRAI
// groupe du certificat. Retour : +1 CFDictionaryRef ou NULL (rien a changer).
static CFDictionaryRef NWKeychainRemapAccessGroup(CFDictionaryRef q) {
    @try {
        if (!q || CFGetTypeID(q) != CFDictionaryGetTypeID()) return NULL;
        CFTypeRef g = CFDictionaryGetValue(q, kSecAttrAccessGroup);
        if (!g) return NULL;
        NWLoadAccessGroupReal();
        if (NWAccessGroupReal.length == 0) return NULL;
        // Groupe present mais DIFFERENT -> re-ecriture.
        if (CFGetTypeID(g) == CFStringGetTypeID()) {
            if ([(__bridge NSString *)g isEqualToString:NWAccessGroupReal]) return NULL;
            NSMutableDictionary *m = [(__bridge NSDictionary *)q mutableCopy];
            m[(__bridge id)kSecAttrAccessGroup] = NWAccessGroupReal;
            return CFBridgingRetain(m);
        }
        // kSecAttrAccessGroup peut arriver en liste (plusieurs groupes).
        if (CFGetTypeID(g) == CFArrayGetTypeID()) {
            NSMutableArray *gs = [(__bridge NSArray *)g mutableCopy];
            BOOL chg = NO;
            for (NSInteger i = (NSInteger)gs.count - 1; i >= 0; i--) {
                id e = gs[i];
                if ([e isKindOfClass:[NSString class]] &&
                    ![(NSString *)e isEqualToString:NWAccessGroupReal]) {
                    gs[i] = NWAccessGroupReal; chg = YES;
                }
            }
            if (!chg) return NULL;
            NSMutableDictionary *m = [(__bridge NSDictionary *)q mutableCopy];
            m[(__bridge id)kSecAttrAccessGroup] = gs;
            return CFBridgingRetain(m);
        }
        return NULL;
    } @catch (NSException *e) {
        NWLog("remap accessGroup: %@", e.reason);
        return NULL;
    }
}

// Vague 10-2 : TOUS les groupes d'app que les SDK Meta lisent (releves dans
// Instagram + FBSharedFramework). En sideloading le certificat personnel ne
// porte AUCUN entitlement com.apple.security.application-groups : chaque
// groupContainerURL... renvoie nil, y compris le groupe App Attest
// (group.com.facebook.family.appattestation) dont le keystore est exige a
// l'inscription. On fabrique donc un conteneur pour CHACUN d'eux.
static NSArray<NSString *> *NWAppGroupIDs(void) {
    static NSArray<NSString *> *a = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"group.com.burbn.instagram",
            @"group.com.burbn.family",
            @"group.com.facebook.family",
            @"group.com.facebook.family.appattestation",
            @"group.com.facebook.family.instagramtokenshare.key",
            @"group.com.facebook.family.instagramtokenshare.service",
            @"group.com.facebook.Bishop",
            @"group.com.facebook.Messenger",
            @"group.com.facebook.msysstorage",
            @"group.com.facebook.internal.lantern",
            @"group.metaplatforms.family",
            @"group.meta.bizapp.instagram.work.token",
            @"group.meta.workaccounts.login.sdk",
        ];
    });
    return a;
}

// Conteneur de groupe FACTICE (dossier dans Documents) : utilise a la fois
// par le hook NSFileManager (REPLI 1, historique) et par LSBundleProxy.
static NSURL *NWFakeGroupContainerURL(NSString *gid) {
    if (![gid isKindOfClass:[NSString class]] || !gid.length) return nil;
    NSString *root = [NWDocumentsDir() stringByAppendingPathComponent:@"FakeGroupContainers"];
    NSURL *u = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:gid] isDirectory:YES];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"", @"Library", @"Library/Caches"]) {
        NSString *p = [u.path stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:p]) {
            [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
    return u;
}

// LSBundleProxy : SDK Meta lit les URLs de conteneurs via le bundle proxy
// (chemin secondaire, pas NSFileManager). On ajoute notre gp a la table
// retournee, en gardant les entrees deja presentes (motif 'merge').
static NSDictionary *(*NWOrig_groupContainers)(id, SEL);
static NSDictionary *NWHook_groupContainers(id self, SEL _cmd) {
    @try {
        NSDictionary *real = NWOrig_groupContainers ? NWOrig_groupContainers(self, _cmd) : nil;
        NSMutableDictionary *m = [real isKindOfClass:[NSDictionary class]]
            ? [real mutableCopy] : [NSMutableDictionary dictionary];
        for (NSString *gid in NWAppGroupIDs()) {
            if (m[gid]) continue;
            NSURL *u = NWFakeGroupContainerURL(gid);
            if (u) {
                m[gid] = u;
                NWLog("lsbundle: appGroup resolved %@ -> %@ (sandbox fallback)", gid, u.path);
            }
        }
        return m;
    } @catch (NSException *e) {
        NWLog("lsbundle groupContainerURLs: %@", e.reason);
        return NWOrig_groupContainers ? NWOrig_groupContainers(self, _cmd) : nil;
    }
}

// CloudKit : CKEntitlements checke com.apple.security.application-groups
// pour valider les conteneurs. On ajoute notre groupe au dict passe a
// -initWithEntitlementsDict: (les autres initialisateurs CSP restent
// spread sans scrim: leur signature precise est inconnue, ne pas casser
// l'ABI en devinant).
static id (*NWOrig_ckEnt)(id, SEL, NSDictionary *);
static id NWHook_ckEnt(id self, SEL _cmd, NSDictionary *d) {
    @try {
        NSMutableDictionary *m = [d isKindOfClass:[NSDictionary class]]
            ? [d mutableCopy] : [NSMutableDictionary dictionary];
        NSString *key = @"com.apple.security.application-groups";
        NSMutableArray *gs = [m[key] isKindOfClass:[NSArray class]]
            ? [m[key] mutableCopy] : [NSMutableArray array];
        for (NSString *gid in NWAppGroupIDs()) {
            if (![gs containsObject:gid]) [gs addObject:gid];
        }
        m[key] = gs;
        return NWOrig_ckEnt(self, _cmd, m);
    } @catch (NSException *e) {
        NWLog("ckEntitlements: %@", e.reason);
        return NWOrig_ckEnt(self, _cmd, d);
    }
}

// Vague 10-2 : dernier repli. Si le keychain refuse encore (-34018
// errSecMissingEntitlement ou -50 errSecParam, et -25300 errSecItemNotFound en
// lecture), on retire COMPLETEMENT kSecAttrAccessGroup : le systeme attribue
// alors le groupe par defaut du certificat, toujours autorise.
static CFDictionaryRef NWKeychainStripAccessGroup(CFDictionaryRef q) {
    @try {
        if (!q || CFGetTypeID(q) != CFDictionaryGetTypeID()) return NULL;
        if (!CFDictionaryContainsKey(q, kSecAttrAccessGroup)) return NULL;
        NSMutableDictionary *m = [(__bridge NSDictionary *)q mutableCopy];
        [m removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        return CFBridgingRetain(m);
    } @catch (NSException *e) {
        NWLog("strip accessGroup: %@", e.reason);
        return NULL;
    }
}

static BOOL NWKeychainErrNeedsStrip(OSStatus st, BOOL reading) {
    if (st == -34018 /* errSecMissingEntitlement */) return YES;
    if (st == -50 /* errSecParam */) return YES;
    if (reading && st == -25300 /* errSecItemNotFound */) return YES;
    return NO;
}

static OSStatus NWHook_SecItemAdd(CFDictionaryRef q, CFTypeRef *r) {
    CFDictionaryRef qq = NWKeychainRemapAccessGroup(q);
    OSStatus st = NWSecReal_Add ? NWSecReal_Add(qq ? qq : q, r)
                                : SecItemAdd(qq ? qq : q, r);
    if (qq) CFRelease(qq);
    if (NWKeychainErrNeedsStrip(st, NO)) {
        CFDictionaryRef qs = NWKeychainStripAccessGroup(q);
        if (qs) {
            st = NWSecReal_Add ? NWSecReal_Add(qs, r) : SecItemAdd(qs, r);
            CFRelease(qs);
            NWLog("keychain add : retry sans access group -> %d", (int)st);
        }
    }
    return st;
}

static OSStatus NWHook_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
    CFDictionaryRef qq = NWKeychainRemapAccessGroup(q);
    OSStatus st = NWSecReal_CopyMatching ? NWSecReal_CopyMatching(qq ? qq : q, r)
                                         : SecItemCopyMatching(qq ? qq : q, r);
    if (qq) CFRelease(qq);
    if (NWKeychainErrNeedsStrip(st, YES)) {
        CFDictionaryRef qs = NWKeychainStripAccessGroup(q);
        if (qs) {
            st = NWSecReal_CopyMatching ? NWSecReal_CopyMatching(qs, r)
                                        : SecItemCopyMatching(qs, r);
            CFRelease(qs);
            NWLog("keychain copy : retry sans access group -> %d", (int)st);
        }
    }
    return st;
}

static OSStatus NWHook_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef attrs, CFTypeRef *r) {
    CFDictionaryRef qq = NWKeychainRemapAccessGroup(q);
    // SecItemUpdate n'a que 2 parametres (query, attrsToUpdate) : r sert
    // uniquement au pointeur reel (l'API C n'en prend pas).
    OSStatus st = NWSecReal_Update ? NWSecReal_Update(qq ? qq : q, attrs, r)
                                   : SecItemUpdate(qq ? qq : q, attrs);
    if (qq) CFRelease(qq);
    if (NWKeychainErrNeedsStrip(st, NO)) {
        CFDictionaryRef qs = NWKeychainStripAccessGroup(q);
        if (qs) {
            st = NWSecReal_Update ? NWSecReal_Update(qs, attrs, r)
                                  : SecItemUpdate(qs, attrs);
            CFRelease(qs);
            NWLog("keychain update : retry sans access group -> %d", (int)st);
        }
    }
    return st;
}

static OSStatus NWHook_SecItemDelete(CFDictionaryRef q) {
    CFDictionaryRef qq = NWKeychainRemapAccessGroup(q);
    OSStatus st = NWSecReal_Delete ? NWSecReal_Delete(qq ? qq : q)
                                   : SecItemDelete(qq ? qq : q);
    if (qq) CFRelease(qq);
    if (NWKeychainErrNeedsStrip(st, NO)) {
        CFDictionaryRef qs = NWKeychainStripAccessGroup(q);
        if (qs) {
            st = NWSecReal_Delete ? NWSecReal_Delete(qs) : SecItemDelete(qs);
            CFRelease(qs);
            NWLog("keychain delete : retry sans access group -> %d", (int)st);
        }
    }
    return st;
}

// REPLI 1 : au lieu de nil, Instagram recoit un URL de conteneur valide.
static NSURL *NWHook_containerURL(id self, SEL _cmd, NSString *gid) {
    @try {
        NSURL *real = NWOrig_containerURL ? NWOrig_containerURL(self, _cmd, gid) : nil;
        if (real) return real;                 // comportement d'origine si dispo
        NSURL *u = NWFakeGroupContainerURL(gid);
        if (u) NWLog("sideload: conteneur de groupe factice -> %@", gid);
        return u;
    } @catch (NSException *e) {
        NWLog("sideload containerURL: %@", e.reason);
        return nil;
    }
}

// REPLI 2 : le meme IMP pour les 3 classes, chaque origine dans son propre slot
// (sinon l'appel d'origine d'une classe pourrait viser l'IMP d'une autre).
static NSString *(*NWOrig_acFBC)(id, SEL);
static NSString *(*NWOrig_acUIC)(id, SEL);
static NSString *(*NWOrig_acFBSDK)(id, SEL);

static NSString *NWAccessGroupOrOrig(id self, SEL _cmd, NSString *(*orig)(id, SEL)) {
    @try {
        NWLoadAccessGroupReal();
        if (NWAccessGroupReal.length) return NWAccessGroupReal;
        return orig ? orig(self, _cmd) : nil;
    } @catch (NSException *e) {
        NWLog("sideload accessGroup: %@", e.reason);
        return NWAccessGroupReal;
    }
}
static NSString *NWHook_acFBC(id s, SEL c)   { return NWAccessGroupOrOrig(s, c, NWOrig_acFBC); }
static NSString *NWHook_acUIC(id s, SEL c)   { return NWAccessGroupOrOrig(s, c, NWOrig_acUIC); }
static NSString *NWHook_acFBSDK(id s, SEL c) { return NWAccessGroupOrOrig(s, c, NWOrig_acFBSDK); }

static void NWInstallSideloadFix(void) {
    // 1. Conteneur de groupe : LA cause documentee du crash a l'inscription.
    NWSwizzle([NSFileManager class],
              @selector(containerURLForSecurityApplicationGroupIdentifier:),
              (IMP)NWHook_containerURL, &NWOrig_containerURL);

    // 2. Access group keychain : seules les classes PRESENTES sont hookes
    //    (FBSDKKeychainStore n'existe plus dans 453/454, les deux autres oui).
    int n = 0;
    Class c = NSClassFromString(@"FBKeychainItemController");
    if (c) { NWSwizzle(c, @selector(accessGroup), (IMP)NWHook_acFBC, &NWOrig_acFBC); n++; }
    c = NSClassFromString(@"UICKeyChainStore");
    if (c) { NWSwizzle(c, @selector(accessGroup), (IMP)NWHook_acUIC, &NWOrig_acUIC); n++; }
    c = NSClassFromString(@"FBSDKKeychainStore");
    if (c) { NWSwizzle(c, @selector(accessGroup), (IMP)NWHook_acFBSDK, &NWOrig_acFBSDK); n++; }

    // 3. Vernis v2 (le chemin completement fabrique chez eux, ici re-ecrit) :
    //    LSBundleProxy.groupContainerURLs (table merge) + CKEntitlements
    //    (com.apple.security.application-groups ajoute aux dicts Client).
    Class lbp = NSClassFromString(@"LSBundleProxy");
    if (lbp) {
        NWSwizzle(lbp, @selector(groupContainerURLs),
                  (IMP)NWHook_groupContainers, &NWOrig_groupContainers);
        n++;
    }
    Class ck = NSClassFromString(@"CKEntitlements");
    if (ck) {
        NWSwizzle(ck, @selector(initWithEntitlementsDict:),
                  (IMP)NWHook_ckEnt, &NWOrig_ckEnt);
        n++;
    }

    NWLoadAccessGroupReal();
    NWLog("sideload fix installe (conteneur de groupe + %d accessGroup, groupe=%@)",
          n, NWAccessGroupReal ?: @"(reel si dispo)");
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

// Sauvegarde le conteneur actif avant fermeture (minimise la perte de comptes).
static void NWFlushOnExit(void) {
    if (NWActiveID) {
        NWSnapshotActive();
        NWPersistState();
    }
}

// ---------------------------------------------------------------------------
// Device identity — identite PAR APPAREIL (device id, family device id,
// vendor id, machine id = mid) + blocage de l'attestation Apple.
// Portefeuille : les cles EPINGLEES sont les NOTRES (prefixe nw9.*) ; la
// lecture se fait par conteneur (fp deviceId/fdid/mid) et le pin global
// (masque manuel) gagne quand il est pose. L'attestation est OFF par defaut
// (comme chez eux).
// ---------------------------------------------------------------------------

// Cles device identity : #define en TETE de fichier (au-dessus) pour etre
// visibles avant leur premier usage dans le fil.

static BOOL NWDevPillHiddenNow = NO;

static NSString *NWDevGetStr(NSString *k) {
    @try {
        NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:k];
        return (v && v.length) ? v : nil;
    } @catch (NSException *e) { NWLog("devGetStr: %@", e.reason); return nil; }
}

static void NWDevSetStr(NSString *k, NSString *v) {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        if (v && v.length) [u setObject:v forKey:k];
        else [u removeObjectForKey:k];
        if (v && v.length) [u synchronize];
    } @catch (NSException *e) { NWLog("devSetStr: %@", e.reason); }
}

static BOOL NWDevBool(NSString *k) {
    @try {
        return [[[NSUserDefaults standardUserDefaults] objectForKey:k] boolValue];
    } @catch (NSException *e) { return NO; }
}

static BOOL NWDevMaskOn(void)   { return NWDevBool(NWDevKeyOn); }

// Vague 10-2 : blocage par DEFAUT. Une app sideloadee n'a jamais l'entitlement
// com.apple.developer.devicecheck.appattest-environment : l'attestation ne
// peut pas aboutir et le keystore App Attest d'Instagram reste vide -> crash
// a la saisie du prenom. On repond donc "non supporte" tant que l'utilisateur
// n'a pas explicitement remis le blocage sur Off.
static BOOL NWBlockAttest(void) {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        if ([u objectForKey:NWDevKeyAttBlock] == nil) return YES;   // defaut
        return [u boolForKey:NWDevKeyAttBlock];
    } @catch (NSException *e) { return YES; }
}
static BOOL NWSafeModeOn(void)  { return NWDevBool(NWSafeModeKey); }

// Le pin global n'appartient qu'AU conteneur qui l'a cree. Un autre conteneur
// ne doit jamais heriter de cette identite : sinon deux "telephones" partagent
// le meme device id (conflit signale en vague 9). Pas de proprietaire = ancien
// build -> on garde l'ancien comportement global.
static BOOL NWDevPinActive(void) {
    if (!NWDevMaskOn()) return NO;
    NSString *owner = NWDevGetStr(NWDevKeyPinOwner);
    if (!owner.length) return YES;
    return (NWActiveID && [owner isEqualToString:NWActiveID]);
}

static NSString *NWDevPinnedStr(NSString *k) {
    if (!NWDevPinActive()) return nil;
    return NWDevGetStr(k);
}

// Valeur activee : pin global > empreinte du conteneur > nil.
static NSString *NWDevDevIDCurrent(void) {
    NSString *g = NWDevPinnedStr(NWDevKeyDevID);
    if (g) return g;
    return NWFPStr(@"deviceId");
}
static NSString *NWDevFDIDCurrent(void) {
    NSString *g = NWDevPinnedStr(NWDevKeyFDID);
    if (g) return g;
    return NWFPStr(@"fdid");
}
static NSString *NWDevMidCurrent(void) {
    NSString *g = NWDevPinnedStr(NWDevKeyMid);
    if (g) return g;
    return NWFPStr(@"mid");
}
static NSString *NWDevMidHdrCurrent(void) {
    NSString *g = NWDevPinnedStr(NWDevKeyMidHdr);
    if (g) return g;
    return NWFPStr(@"midHeader");
}

// Suffixe court (5 caracteres) affiche a cote de « Real • ».
static NSString *NWDevShort(NSString *s) {
    NSString *t = s ?: @"";
    if (t.length < 5) return t;
    return [t substringFromIndex:t.length - 5];
}

// (Re)genere l'empreinte du conteneur actif + les valeurs epinglees globales.
// La langue / le fuseau du conteneur sont CONSERVES : changer d'appareil ne
// doit jamais casser le pays choisi (vague 9).
static void NWDevRollIdentity(BOOL makeMask) {
    @try {
        if (NWActiveID) {
            NSDictionary *nfp = NWGenerateFingerprintKeepingLocale(NWActiveFP);
            if (nfp) { NWActiveFP = nfp; NWUpdateActiveFP(nfp); }
        }
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        [u setObject:[[NSUUID UUID] UUIDString] forKey:NWDevKeyDevID];
        [u setObject:[[NSUUID UUID] UUIDString] forKey:NWDevKeyFDID];
        [u setObject:[[NSUUID UUID] UUIDString] forKey:NWDevKeyMid];
        [u setObject:[[NSUUID UUID] UUIDString] forKey:NWDevKeyMidHdr];
        // Le pin appartient a CE conteneur : les autres gardent leur identite.
        if (NWActiveID) [u setObject:NWActiveID forKey:NWDevKeyPinOwner];
        if (makeMask) [u setObject:@YES forKey:NWDevKeyOn];
        [u synchronize];
    } @catch (NSException *e) { NWLog("devRoll: %@", e.reason); }
}

// — getDeviceId : scan INCREMENTAL des classes (vague 9). L'ancien scan
// appelait class_getInstanceMethod sur TOUTES les classes d'un coup, ce qui
// forcait la realisation de toutes les classes Swift d'Instagram et faisait
// fermer l'app ~5 s apres le lancement. Ici : class_copyMethodList (qui ne
// realise PAS la classe), par petits lots de 100 classes toutes les 45 ms
// sur la main queue, avec un @try par classe.
static NSMutableDictionary<NSString *, NSValue *> *NWGetIdOrigMap = nil;
static Class *NWGetIdClasses = NULL;
static unsigned int NWGetIdClassCount = 0;
static unsigned int NWGetIdScanIndex = 0;
static BOOL NWGetIdScanRunning = NO;
static NSMutableArray<NSValue *> *NWGetIdSeen = nil;

static id NWHook_getDeviceId(id self, SEL _cmd) {
    @try {
        // 1. L'identite du conteneur passe TOUJOURS en premier (plus de nil
        // risque pour l'appelant). Si Ghost est OFF, NWFPStr renvoie nil et
        // on retombe sur l'implementation d'origine (vraie valeur Apple).
        NSString *p = NWDevDevIDCurrent();
        if (p.length) return p;
        NSValue *v = nil;
        Class c = object_getClass(self);
        while (c && !v) {
            NSString *cn = NSStringFromClass(c);
            v = cn ? NWGetIdOrigMap[cn] : nil;
            c = class_getSuperclass(c);
        }
        IMP old = v ? (IMP)v.pointerValue : NULL;
        if (old) return ((id (*)(id, SEL))old)(self, _cmd);
        return nil;
    } @catch (NSException *e) {
        NWLog("getDeviceId: %@", e.reason);
        return nil;
    }
}

static void NWScanGetDeviceIdStep(void) {
    @autoreleasepool {
        if (!NWGetIdScanRunning || !NWGetIdClasses) return;
        if (!NWGetIdOrigMap) NWGetIdOrigMap = [NSMutableDictionary dictionary];
        if (!NWGetIdSeen) NWGetIdSeen = [NSMutableArray array];
        SEL sel = sel_getUid("getDeviceId");
        unsigned int end = NWGetIdScanIndex + 100;
        if (end > NWGetIdClassCount) end = NWGetIdClassCount;
        for (unsigned int i = NWGetIdScanIndex; i < end; i++) {
            Class c = NWGetIdClasses[i];
            @try {
                unsigned int mc = 0;
                Method *ml = class_copyMethodList(c, &mc);   // pas de realisation
                if (!ml) continue;
                for (unsigned int j = 0; j < mc; j++) {
                    Method m = ml[j];
                    if (!sel_isEqual(method_getName(m), sel)) continue;
                    char *rt = method_copyReturnType(m);
                    BOOL isObj = (rt && rt[0] == '@');
                    free(rt);
                    if (!isObj) continue;
                    IMP imp = method_getImplementation(m);
                    NSValue *iv = [NSValue valueWithPointer:imp];
                    if ([NWGetIdSeen containsObject:iv]) continue;  // deja hookee
                    [NWGetIdSeen addObject:iv];
                    NSString *cn = NSStringFromClass(c);
                    if (!cn) cn = [NSString stringWithUTF8String:class_getName(c)];
                    if (cn) NWGetIdOrigMap[cn] = iv;
                    method_setImplementation(m, (IMP)NWHook_getDeviceId);
                    NWLog("device id : getDeviceId hook (%s)", class_getName(c));
                }
                free(ml);
            } @catch (NSException *e) {
                NWLog("scan getDeviceId: %@", e.reason);
            }
        }
        NWGetIdScanIndex = end;
        if (NWGetIdScanIndex < NWGetIdClassCount) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{ NWScanGetDeviceIdStep(); });
        } else {
            NWGetIdScanRunning = NO;
            // Scan termine sans crash : on efface le temoin de debut.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:NWScanStartKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            if (NWGetIdClasses) free(NWGetIdClasses);
            NWGetIdClasses = NULL;
            NWLog("device id : scan termine (%u classes)", NWGetIdClassCount);
        }
    }
}

static void NWInstall_getDeviceId(void) {
    // Vague 10 : audit des binaires de l'IPA (Instagram 454, FBSharedFramework,
    // extensions) -> AUCUNE methode ObjC "getDeviceId" n'existe dans l'app.
    // Le scan ne hookait donc rien, mais objc_copyClassList realisait ~31 000
    // classes (dont Swift) sur le main thread : c'etait la cause du plantage
    // ~5 s pendant la creation de compte. Le code reste present (aucun warning
    // supplementaire) mais n'est plus JAMAIS execute : aucun appel ne pose ce
    // flag. Pour reactiver un jour : [[NSUserDefaults standardUserDefaults]
    // setBool:YES forKey:@"nw9.dev.scan.enabled"].
    if (!NWDevBool(@"nw9.dev.scan.enabled")) {
        static BOOL once = NO;
        if (!once) { once = YES; NWLog("device id : scan neutralise (aucune cible getDeviceId dans l'app)"); }
        return;
    }
    if (NWGetIdScanRunning) return;
    if (NWGetIdSeen.count > 0) return;   // deja scanne : ne jamais re-hooker
    if (NWGetIdClasses) { free(NWGetIdClasses); NWGetIdClasses = NULL; }
    NWGetIdClassCount = 0;
    NWGetIdClasses = objc_copyClassList(&NWGetIdClassCount);
    if (!NWGetIdClasses || !NWGetIdClassCount) {
        if (NWGetIdClasses) free(NWGetIdClasses);
        NWGetIdClasses = NULL;
        return;
    }
    NWGetIdScanIndex = 0;
    NWGetIdScanRunning = YES;
    // Temoin de debut : si l'app meurt pendant les lots, le prochain lancement
    // le voit (via le rapporteur de crash) et neutralise l'etape 9.
    NSUserDefaults *scanU = [NSUserDefaults standardUserDefaults];
    [scanU setDouble:[NSDate date].timeIntervalSince1970 forKey:NWScanStartKey];
    [scanU synchronize];
    // On ne scanne jamais dans le chemin d'appel : premier lot au prochain run.
    dispatch_async(dispatch_get_main_queue(), ^{ NWScanGetDeviceIdStep(); });
}

// — FBFamilyDeviceID : familyDeviceIDWith...SourceFile/SourceLine (local).
// Methodes de classe (FB style) OU d'instance, selon le charge reel.
static IMP NWOrig_fdid = NULL;
static IMP NWOrig_fdidCached = NULL;

static id NWHook_fdid(id self, SEL _cmd, id cfg, id file, int line) {
    @try {
        NSString *p = NWDevFDIDCurrent();   // pin du conteneur > empreinte
        if (p) return p;
        if (NWOrig_fdid) return ((id (*)(id, SEL, id, id, int))NWOrig_fdid)(self, _cmd, cfg, file, line);
        return nil;
    } @catch (NSException *e) { NWLog("fdid: %@", e.reason); return nil; }
}

static id NWHook_fdidCached(id self, SEL _cmd, id cfg, id file, int line) {
    @try {
        NSString *p = NWDevFDIDCurrent();   // pin du conteneur > empreinte
        if (p) return p;
        if (NWOrig_fdidCached) return ((id (*)(id, SEL, id, id, int))NWOrig_fdidCached)(self, _cmd, cfg, file, line);
        return nil;
    } @catch (NSException *e) { NWLog("fdidCached: %@", e.reason); return nil; }
}

static void NWInstall_FBFamilyDeviceID(void) {
    Class c = NSClassFromString(@"FBFamilyDeviceID");
    if (!c) { NWLog("device id : FBFamilyDeviceID absent"); return; }
    SEL s1 = sel_getUid("familyDeviceIDWithConfiguration:SourceFile:SourceLine:");
    SEL s2 = sel_getUid("cachedFamilyDeviceIDWithConfiguration:SourceFile:SourceLine:");
    Method m1 = class_getClassMethod(c, s1);
    Method i1 = class_getInstanceMethod(c, s1);
    Method m2 = class_getClassMethod(c, s2);
    Method i2 = class_getInstanceMethod(c, s2);
    if (m1)      { NWOrig_fdid = method_getImplementation(m1); method_setImplementation(m1, (IMP)NWHook_fdid); }
    else if (i1) { NWOrig_fdid = method_getImplementation(i1); method_setImplementation(i1, (IMP)NWHook_fdid); }
    if (m2)      { NWOrig_fdidCached = method_getImplementation(m2); method_setImplementation(m2, (IMP)NWHook_fdidCached); }
    else if (i2) { NWOrig_fdidCached = method_getImplementation(i2); method_setImplementation(i2, (IMP)NWHook_fdidCached); }
    if (NWOrig_fdid || NWOrig_fdidCached) NWLog("device id : FBFamilyDeviceID hook pose");
}

// — machine ID (mid) : les 2 cles prefrees d'Instagram
//   instagram.mid / com.instagram.device.midheader. Lecture TOMBEE sur la
//   valeur epinglee quand le mask est pose ; écriture serveur bloque tant
//   que le pin existe (motif "pinned machine ID").
static void (*NWOrig_udsSet)(id, SEL, id, id);
static void (*NWOrig_udsRemove)(id, SEL, id);

// Garde de reentrance (TLS) : nos propres lectures (NWDevMaskOn ->
// objectForKey:) repassent par ce hook. Sans garde = recursion infinie.
static __thread BOOL NWUdsInHook = NO;

static BOOL NWDevIsMidKey(id key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return ([key isEqualToString:@"instagram.mid"] ||
            [key isEqualToString:@"com.instagram.device.midheader"]);
}

// Vague 10-2 : suites NSUserDefaults des groupes d'app. En sideloading,
// [[NSUserDefaults alloc] initWithSuiteName:@"group..."] peut renvoyer nil
// (pas d'entitlement) : le SDK Facebook croit alors que son magasin partage
// n'existe pas. On redirige chaque suite de groupe vers une suite SANDBOX
// stable, propre au conteneur -> les lectures/ecritures fonctionnent et les
// conteneurs ne partagent pas leurs donnees.
static NSString *NWSandboxSuiteName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return name;
    if (![name hasPrefix:@"group."]) return name;
    return [NSString stringWithFormat:@"nw9.%@.%@", NWActiveID ?: @"shared", name];
}

static id (*NWOrig_udsInitSuite)(id, SEL, NSString *);
static id NWHook_udsInitSuite(id self, SEL _cmd, NSString *name) {
    NSString *n = NWSandboxSuiteName(name);
    if (![n isEqualToString:name]) NWLog("uds suite redirect %@ -> %@", name, n);
    return NWOrig_udsInitSuite ? NWOrig_udsInitSuite(self, _cmd, n) : nil;
}

static id (*NWOrig_udsInitSuiteC)(id, SEL, NSString *, id);
static id NWHook_udsInitSuiteC(id self, SEL _cmd, NSString *name, id container) {
    NSString *n = NWSandboxSuiteName(name);
    if (![n isEqualToString:name]) NWLog("uds suite redirect %@ -> %@", name, n);
    return NWOrig_udsInitSuiteC ? NWOrig_udsInitSuiteC(self, _cmd, n, container) : nil;
}

static id (*NWOrig_udsObject)(id, SEL, id);
static id NWHook_udsObject(id self, SEL _cmd, id key) {
    if (NWUdsInHook) {
        return NWOrig_udsObject ? NWOrig_udsObject(self, _cmd, key) : nil;
    }
    NWUdsInHook = YES;
    id result = nil;
    @try {
        if (NWDevPinActive() && NWDevIsMidKey(key)) {
            // mid et midheader ont chacun leur valeur epinglee (repli : mid).
            NSString *p = [key isEqualToString:@"com.instagram.device.midheader"]
                ? NWDevMidHdrCurrent() : NWDevMidCurrent();
            if (p) { result = p; NWUdsInHook = NO; return result; }
        }
        result = NWOrig_udsObject ? NWOrig_udsObject(self, _cmd, key) : nil;
    } @catch (NSException *e) {
        result = NWOrig_udsObject ? NWOrig_udsObject(self, _cmd, key) : nil;
    }
    NWUdsInHook = NO;
    return result;
}

static void NWHook_udsSet(id self, SEL _cmd, id value, id key) {
    if (NWUdsInHook) {
        if (NWOrig_udsSet) NWOrig_udsSet(self, _cmd, value, key);
        return;
    }
    NWUdsInHook = YES;
    @try {
        if (NWDevPinActive() && NWDevIsMidKey(key)) {
            NWLog("mid : ecriture serveur bloquee (machine id epingle)");
            NWUdsInHook = NO;
            return;
        }
    } @catch (NSException *e) { NWLog("udsSet: %@", e.reason); }
    NWUdsInHook = NO;
    if (NWOrig_udsSet) NWOrig_udsSet(self, _cmd, value, key);
}

static void NWHook_udsRemove(id self, SEL _cmd, id key) {
    if (NWUdsInHook) {
        if (NWOrig_udsRemove) NWOrig_udsRemove(self, _cmd, key);
        return;
    }
    NWUdsInHook = YES;
    @try {
        if (NWDevPinActive() && NWDevIsMidKey(key)) {
            NWLog("mid : suppression serveur bloquee (machine id epingle)");
            NWUdsInHook = NO;
            return;
        }
    } @catch (NSException *e) { NWLog("udsRemove: %@", e.reason); }
    NWUdsInHook = NO;
    if (NWOrig_udsRemove) NWOrig_udsRemove(self, _cmd, key);
}

static void NWInstall_UdsHooks(void) {
    NWSwizzle([NSUserDefaults class], @selector(initWithSuiteName:),
              (IMP)NWHook_udsInitSuite, &NWOrig_udsInitSuite);
    // Variante privee utilisee par les appex de Meta (si elle existe).
    NWSwizzle([NSUserDefaults class], @selector(initWithSuiteName:container:),
              (IMP)NWHook_udsInitSuiteC, &NWOrig_udsInitSuiteC);
    NWSwizzle([NSUserDefaults class], @selector(objectForKey:),
              (IMP)NWHook_udsObject, &NWOrig_udsObject);
    NWSwizzle([NSUserDefaults class], @selector(setObject:forKey:),
              (IMP)NWHook_udsSet, &NWOrig_udsSet);
    NWSwizzle([NSUserDefaults class], @selector(removeObjectForKey:),
              (IMP)NWHook_udsRemove, &NWOrig_udsRemove);
    NWLog("device id : hooks NSUserDefaults (mid) poses");
}

// — atestation Apple : DCDevice (DeviceCheck) + DCAppAttestService.
// Bloquee PAR DEFAUT (vague 10-2) : isSupported -> NO, et les generateurs
// repondent handler(nil, error). Ainsi Instagram emprunte ses chemins
// "appAttestationNotSupported" au lieu d'un keystore vide qui plante.
static BOOL (*NWOrig_dcSupported)(id, SEL);
static BOOL NWHook_dcSupported(id self, SEL _cmd) {
    if (NWBlockAttest()) return NO;
    return NWOrig_dcSupported ? NWOrig_dcSupported(self, _cmd) : NO;
}

static BOOL (*NWOrig_aaSupported)(id, SEL);
static BOOL NWHook_aaSupported(id self, SEL _cmd) {
    if (NWBlockAttest()) return NO;
    return NWOrig_aaSupported ? NWOrig_aaSupported(self, _cmd) : NO;
}

static void (*NWOrig_dcToken)(id, SEL, void (^)(NSData *, NSError *));
static void NWHook_dcToken(id self, SEL _cmd, void (^h)(NSData *, NSError *)) {
    @try {
        if (NWBlockAttest()) {
            NWLog("attestation (DeviceCheck) bloquee");
            if (h) {
                NSError *err = [NSError errorWithDomain:@"nine9wham.device" code:9001
                                                userInfo:@{ NSLocalizedDescriptionKey:
                        NWL(@"att_block", @"Apple attestation blocked by user",
                            @"Attestation Apple bloquee par l'utilisateur",
                            @"Atestacion Apple bloqueada por el usuario") }];
                h(nil, err);
            }
            return;
        }
    } @catch (NSException *e) { NWLog("dcToken: %@", e.reason); }
    if (NWOrig_dcToken) NWOrig_dcToken(self, _cmd, h);
}

static void (*NWOrig_attest)(id, SEL, NSString *, NSData *, void (^)(id, NSError *));
static void NWHook_attest(id self, SEL _cmd, NSString *keyID, NSData *dataHash,
                          void (^h)(id, NSError *)) {    @try {
        if (NWBlockAttest()) {
            NWLog("attestation (AppAttest) bloquee");
            if (h) {
                NSError *err = [NSError errorWithDomain:@"nine9wham.device" code:9001
                                                userInfo:@{ NSLocalizedDescriptionKey:
                        NWL(@"att_block", @"Apple attestation blocked by user",
                            @"Attestation Apple bloquee par l'utilisateur",
                            @"Atestacion Apple bloqueada por el usuario") }];
                h(nil, err);
            }
            return;
        }
    } @catch (NSException *e) { NWLog("attest: %@", e.reason); }
    if (NWOrig_attest) NWOrig_attest(self, _cmd, keyID, dataHash, h);
}

// App Attest : generation de cle. Meme reponse quand le blocage est actif
// (RyukGram hooke aussi cette methode : sans elle le keystore reste vide).
static void (*NWOrig_attestKeyGen)(id, SEL, void (^)(NSString *, NSError *));
static void NWHook_attestKeyGen(id self, SEL _cmd, void (^h)(NSString *, NSError *)) {
    @try {
        if (NWBlockAttest()) {
            NWLog("attestation (AppAttest generateKey) bloquee");
            if (h) {
                NSError *err = [NSError errorWithDomain:@"nine9wham.device" code:9001
                                                userInfo:@{ NSLocalizedDescriptionKey:
                        NWL(@"att_block", @"Apple attestation blocked by user",
                            @"Attestation Apple bloquee par l'utilisateur",
                            @"Atestacion Apple bloqueada por el usuario") }];
                h(nil, err);
            }
            return;
        }
    } @catch (NSException *e) { NWLog("attestKeyGen: %@", e.reason); }
    if (NWOrig_attestKeyGen) NWOrig_attestKeyGen(self, _cmd, h);
}

static void NWInstallAttestation(void) {
    Class dc = NSClassFromString(@"DCDevice");
    if (dc) {
        NWSwizzle(object_getClass(dc), @selector(isSupported),
                  (IMP)NWHook_dcSupported, &NWOrig_dcSupported);
        NWSwizzle(dc, @selector(generateTokenWithCompletionHandler:),
                  (IMP)NWHook_dcToken, &NWOrig_dcToken);
        NWLog("attestation : DCDevice hook pose (isSupported + token)");
    } else {
        NWLog("attestation : DCDevice absent");
    }
    Class aa = NSClassFromString(@"DCAppAttestService");
    if (aa) {
        NWSwizzle(object_getClass(aa), @selector(isSupported),
                  (IMP)NWHook_aaSupported, &NWOrig_aaSupported);
        NWSwizzle(aa, @selector(attestKey:clientDataHash:completionHandler:),
                  (IMP)NWHook_attest, &NWOrig_attest);
        NWSwizzle(aa, @selector(generateKeyWithCompletionHandler:),
                  (IMP)NWHook_attestKeyGen, &NWOrig_attestKeyGen);
        NWLog("attestation : DCAppAttestService hook pose (isSupported + attestKey + generateKey)");
    } else {
        NWLog("attestation : DCAppAttestService absent");
    }
}

// Installation centrale + truncature du flag one-shot du bouton flottant.
static void NWInstallDeviceIdentity(void) {
    @try {
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        NWDevPillHiddenNow = ([u objectForKey:NWDevKeyHidePill] != nil);
        if (NWDevPillHiddenNow) [u removeObjectForKey:NWDevKeyHidePill];

        // getDeviceId (scan global des classes) est appele 6 s plus tard,
        // hors du chemin critique : voir etape 9 dans NWStartTweaks.
        NWInstall_FBFamilyDeviceID();
        NWInstall_UdsHooks();
        NWInstallAttestation();
    } @catch (NSException *e) {
        NWLog("device identity install: %@", e.reason);
    }
}

// Interface Safe mode : une UIAlertAction + presentation depuis le top VC.
static void NWPresentSafeModeUI(void) {
    UIViewController *top = NWTopVC();
    if (!top) return;
    if (top.presentedViewController) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:NWL(@"safe_t", @"Safe mode", @"Mode securise", @"Modo seguro")
                         message:NWL(@"safe_m",
                             @"All nine9wham tweaks are OFF. If animations/clicks look odd, tap re-enable to turn everything back on.",
                             @"Tous les tweaks nine9wham sont OFF. Si l'appli est etrange, appuyez sur re-activer pour tout remettre.",
                             @"Todos los cambios de nine9wham estan desactivados. Si la app es extrana, toca reactivar.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:
        NWL(@"safe_re", @"Re-enable & relaunch", @"Re-activer & relancer", @"Reactivar y reiniciar")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:NWSafeModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NWAskRelaunchLater(@"Instagram");
        }]];
    [a addAction:[UIAlertAction actionWithTitle:
        NWL(@"safe_keep", @"Keep safe mode", @"Rester en mode securise", @"Mantener modo seguro")
        style:UIAlertActionStyleCancel handler:nil]];
    @try {
        [top presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) { NWLog("safe mode UI: %@", e.reason); }
}

// ---------------------------------------------------------------------------
// GARDE ANTI-BOUCLE DE CRASH (vague 8).
//
// Chaque etape du demarrage est marquee sur disque (NSUserDefaults) AVANT et
// APRES son execution. Si un lancement meurt sans atteindre la fin, le
// lancement suivant demarre en mode recuperation : il s'arrete AVANT l'etape
// qui a tue, affiche un diagnostic lisible et laisse l'app utilisable.
//
// Resultat : plus jamais de boucle de crash, et l'etape fautive est connue
// sans aucun log systeme (un simple coup d'oeil a l'alerte suffit).
// ---------------------------------------------------------------------------
#define NW_BOOT_KEY_T0    @"nw9.boot.t0"
#define NW_BOOT_KEY_STAGE @"nw9.boot.stage"
#define NW_BOOT_KEY_DONE  @"nw9.boot.done"
#define NW_BOOT_KEY_FAULT @"nw9.boot.fault"
#define NW_BOOT_KEY_BUILD @"nw9.boot.build"
#define NW_BOOT_KEY_ALERT @"nw9.boot.alert"

// Change a chaque build publie : un nouveau dylib re-tente TOUTES les etapes
// (sinon une etape neutralisee le resterait pour toujours).
#define NWBuildID @"w10-2"

static int NWBootStopAt = 0;      // etapes >= cette valeur : neutralisees
static int NWBootFaultStage = 0;  // etape responsable de l'echec precedent

static const char *NWBootStageName(int s) {
    switch (s) {
        case 1:  return "rapporteur de crash";
        case 2:  return "bouton flottant";
        case 3:  return "sideload fix";
        case 4:  return "device identity";
        case 5:  return "etat / empreinte";
        case 6:  return "hooks empreinte + GPS";
        case 7:  return "rebind GOT";
        case 8:  return "proxy reseau";
        case 9:  return "scan device id";
        case 10: return "termine";
        default: return "?";
    }
}

static void NWBootBegin(void) {
    @try {
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
        NSString *bid = [u stringForKey:NW_BOOT_KEY_BUILD];
        if (![bid isEqualToString:NWBuildID]) {
            // Nouveau build : on repart propre, toutes les etapes retentees.
            [u removeObjectForKey:NW_BOOT_KEY_FAULT];
            [u removeObjectForKey:NW_BOOT_KEY_ALERT];
            [u removeObjectForKey:NWScanStartKey];
            [u removeObjectForKey:NWScanFailsKey];
            [u removeObjectForKey:NWScanOffKey];
            [u setObject:NWBuildID forKey:NW_BOOT_KEY_BUILD];
        }
        int fault = (int)[u integerForKey:NW_BOOT_KEY_FAULT];
        BOOL done = [u boolForKey:NW_BOOT_KEY_DONE];
        double t0 = [u doubleForKey:NW_BOOT_KEY_T0];
        int last = (int)[u integerForKey:NW_BOOT_KEY_STAGE];
        double now = [NSDate date].timeIntervalSince1970;
        BOOL failed = (!done && t0 > 0 && (now - t0) < 180.0);
        // --- Vague 9 : le scan getDeviceId a-t-il tue le lancement precedent ?
        //     Le scan note son heure de debut ; un crash ecrit le rapport a cet
        //     instant. Si le rapport est plus recent que le debut du scan, la
        //     cause est le scan -> etape 9 neutralisee. Un arret manuel de
        //     l'app n'ecrit aucun rapport : aucune fausse detection.
        BOOL scanOff = [u boolForKey:NWScanOffKey];
        BOOL scanCrash = NO;
        double scanStart = [u doubleForKey:NWScanStartKey];
        if (scanStart > 0) {
            NSDictionary *at = [[NSFileManager defaultManager]
                attributesOfItemAtPath:NWCrashLogPath() error:nil];
            NSDate *mt = at[NSFileModificationDate];
            if (mt && mt.timeIntervalSince1970 >= scanStart) {
                NSInteger n = [u integerForKey:NWScanFailsKey] + 1;
                [u setInteger:n forKey:NWScanFailsKey];
                if (n >= 2) [u setBool:YES forKey:NWScanOffKey];
                scanCrash = YES;
                NWLog("boot: crash pendant le scan getDeviceId (n=%ld)", (long)n);
            }
            [u removeObjectForKey:NWScanStartKey];
        }
        if (failed) {
            if (fault > 0) {
                // La recuperation a elle-meme echoue : on descend d'une etape
                // de plus. On finit donc TOUJOURS par atteindre un demarrage
                // sain, meme si la premiere attribution etait approximative.
                fault = (fault > 1) ? fault - 1 : 1;
            } else {
                // Le lancement precedent n'a jamais atteint la fin : l'etape
                // qui suit la derniere marque est celle qui a tue l'app.
                fault = last + 1;
            }
            NWBootFaultStage = fault;
            [u setInteger:fault forKey:NW_BOOT_KEY_FAULT];
            NWLog("boot: echec precedent a l'etape %d (%s) -> neutralisee",
                  NWBootFaultStage, NWBootStageName(NWBootFaultStage));
        } else if (fault > 0) {
            NWBootFaultStage = fault;
        }
        // Scan neutralise (crash pendant les lots, ou 2 crashs constates) :
        // on saute l'etape 9 mais tout le reste demarre normalement.
        if ((scanCrash || scanOff) && NWBootFaultStage <= 0) {
            NWBootFaultStage = 9;
        }
        NWBootStopAt = NWBootFaultStage;
        [u setDouble:now forKey:NW_BOOT_KEY_T0];
        [u setInteger:0 forKey:NW_BOOT_KEY_STAGE];
        [u setBool:NO forKey:NW_BOOT_KEY_DONE];
        [u synchronize];
    } @catch (NSException *e) {
        NWLog("boot begin: %@", e.reason);
    }
}

static void NWBootMark(int stage) {
    @try {
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
        [u setInteger:stage forKey:NW_BOOT_KEY_STAGE];
        [u synchronize];
    } @catch (NSException *e) { (void)e; }
}

static void NWBootFinish(void) {
    @try {
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
        [u setInteger:10 forKey:NW_BOOT_KEY_STAGE];
        [u setBool:YES forKey:NW_BOOT_KEY_DONE];
        [u synchronize];
    } @catch (NSException *e) { (void)e; }
}

static BOOL NWBootSkip(int stage) {
    return NWBootStopAt > 0 && stage >= NWBootStopAt;
}

// Diagnostic visible (une seule fois par etape fautive) : dit exactement
// quelle etape a ete neutralisee, pour pouvoir la corriger.
static void NWPresentBootRecoveryUI(void) {
    @try {
        if (NWBootFaultStage <= 0) return;
        NSUserDefaults *u = NSUserDefaults.standardUserDefaults;
        if ((int)[u integerForKey:NW_BOOT_KEY_ALERT] == NWBootFaultStage) return;
        [u setInteger:NWBootFaultStage forKey:NW_BOOT_KEY_ALERT];
        [u synchronize];
        UIViewController *top = NWTopVC();
        if (!top || top.presentedViewController) return;
        NSString *stageName = [NSString stringWithUTF8String:NWBootStageName(NWBootFaultStage)];
        NSString *fmt = NWL(@"boot_rec",
            @"Startup step %d (%@) failed last time. It is disabled for this session so the app stays usable.",
            @"L'etape de demarrage %d (%@) a echoue la derniere fois. Elle est desactivee pour cette session afin que l'appli reste utilisable.",
            @"El paso de inicio %d (%@) fallo la ultima vez. Esta desactivado en esta sesion para que la app siga funcionando.");
        NSString *msg = [NSString stringWithFormat:fmt, NWBootFaultStage, stageName];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:NWL(@"boot_rec_t", @"Recovery mode", @"Mode recuperation", @"Modo recuperacion")
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:NWL(@"ok", @"OK", @"OK", @"OK")
                                              style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) {
        NWLog("boot recovery UI: %@", e.reason);
    }
}

static void NWStartTweaks(void) {
    @autoreleasepool {
        NWBootBegin();

        // --- Etape 1. Rapporteur de crash : installe AVANT tout hook, pour
        //     capturer le plantage a la creation de compte (nom + raison + pile).
        if (!NWBootSkip(1)) NWInstallCrashReporter();
        NWBootMark(1);

        // --- Etape 2. UI D'ABORD (vague 8) : bouton flottant + pill poses
        //     avant les hooks. Si une etape ulterieure tue l'app, la garde la
        //     neutralise au lancement suivant et l'app reste utilisable.
        //     C'est aussi la preuve visible que le dylib est bien charge.
        if (!NWBootSkip(2)) {
            @try { NWInstallFloatingButton(); }
            @catch (NSException *e) { NWLog("ui: %@", e.reason); }
        }
        NWBootMark(2);

        // --- Etape 3. Sideload fix : conteneur de groupe + accessGroup keychain.
        //     Sans cela Instagram plante a l'inscription en sideloading
        //     (certificat personnel sans entitlement de groupe).
        if (!NWBootSkip(3)) NWInstallSideloadFix();
        NWBootMark(3);

        // --- SAFE MODE (vague 7) : si l'utilisateur a demande la coupe
        //     totale (Support -> "Disable all tweaks & relaunch"), on
        //     n'installe AUCUN hook empreinte/GPS/rebind/proxy/UI et on
        //     propose la reactivation. Le fix sideload + le rapporteur de
        //     crash restent actifs : sans eux l'app ne peut pas demarrer.
        if (NWSafeModeOn()) {
            NWLog("SAFE MODE : hooks empreinte/GPS/rebind/UI non installes");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { NWPresentSafeModeUI(); } @catch (NSException *e) { NWLog("safe: %@", e.reason); }
            });
            NWBootFinish();
            return;
        }

        // --- Etape 4. Device identity (vague 7) : FBFamilyDeviceID, machine
        //     ID (mid via NSUserDefaults) et attestation Apple. Consomme aussi
        //     le flag one-shot « Hide button until relaunch » du pill.
        //     Le scan global des classes (getDeviceId) est DIFFERE de 6 s
        //     (etape 9) : c'est l'operation la plus lourde du tweak.
        if (!NWBootSkip(4)) NWInstallDeviceIdentity();
        NWBootMark(4);

        NWLog("demarrage - Instagram %@", UIDevice.currentDevice.systemVersion);

        // --- Etape 5. Etat (disque ou vault keychain si re-install)
        if (!NWBootSkip(5)) NWBootstrapState();
        NWBootMark(5);

        // --- Etape 6. Hooks d'empreinte + fake GPS
        if (!NWBootSkip(6)) {
            @try {
                NWInstallFingerprintHooks();
                NWInstallLocationHooks();
            } @catch (NSException *e) {
                NWLog("hooks empreinte: %@", e.reason);
            }
        }
        NWBootMark(6);

        // --- Etape 7. Rebind GOT (SecItem*/sysctl/uname, images de l'app)
        if (!NWBootSkip(7)) NWRebindGOT();
        NWBootMark(7);

        // --- Etape 8. Proxy NSURLSession
        if (!NWBootSkip(8)) {
            @try {
                NWSwizzle(object_getClass([NSURLSessionConfiguration class]),
                          @selector(defaultSessionConfiguration),
                          (IMP)NWHook_defaultSessionCfg, &NWOrig_defaultSessionCfg);
            } @catch (NSException *e) {
                NWLog("proxy: %@", e.reason);
            }
        }
        NWBootMark(8);

        // Repositionnement du bouton une fois l'etat charge.
        if (!NWBootSkip(2)) {
            @try { NWInstallFloatingButton(); } @catch (NSException *e) { (void)e; }
        }

        // Re-verification reguliere : si Instagram recree ses fenetres,
        // l'overlay et le bouton sont remis en place automatiquement.
        static dispatch_source_t overlayTimer;
        dispatch_source_t ot = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
        dispatch_source_set_timer(ot, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2ull * NSEC_PER_SEC, 500ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(ot, ^{
            @autoreleasepool {
                // Jamais d'exception non catchee depuis un timer : une
                // exception lancee ici tue l'app au moment ou elle se
                // produit (= pendant la creation de compte si ca arrive).
                @try {
                    // Instagram peut re-poser SON handler d'exception au fil du
                    // temps : on re-affirme le notre (chaine conservee).
                    if (!NWBootSkip(1)) NWMaintainCrashReporter();
                    NWEnsureOverlay();
                    if (!NWBootSkip(2)) NWInstallFloatingButton();
                } @catch (NSException *e) {
                    NWLog("timer overlay: %@", e.reason);
                }
            }
        });
        dispatch_resume(ot);
        overlayTimer = ot;

        // Flush regulier : chaque 15 s, l'etat est persiste + vault.
        static dispatch_source_t flushTimer;
        dispatch_queue_t q = dispatch_queue_create("com.nine9wham.flush", DISPATCH_QUEUE_SERIAL);
        flushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(flushTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                                  15ull * NSEC_PER_SEC, 3ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(flushTimer, ^{
            @autoreleasepool {
                @try {
                    if (NWActiveID) { NWSnapshotActive(); NWPersistState(); }
                } @catch (NSException *e) { NWLog("flush: %@", e.reason); }
            }
        });
        dispatch_resume(flushTimer);

        // Sauvegarde avant mise en arriere-plan / fermeture
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { NWFlushOnExit(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { NWFlushOnExit(); }];

        NWLog("initialisation terminee - conteneur actif: %@", NWActiveID ?: @"(aucun)");

        // --- Etape 9. Scan getDeviceId (toutes les classes) DIFFERE hors du
        //     chemin critique : il realise des milliers de classes Swift et
        //     n'a aucune raison de bloquer l'ouverture de l'app. La fin du
        //     demarrage n'est validee qu'apres, pour que la garde puisse
        //     attribuer un crash a cette etape.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                @try {
                    if (!NWBootSkip(9)) NWInstall_getDeviceId();
                } @catch (NSException *e) {
                    NWLog("getDeviceId differe: %@", e.reason);
                }
                NWBootMark(9);
                NWBootFinish();
            }
        });

        // Diagnostic de recuperation, une fois l'UI en place.
        if (NWBootFaultStage > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { NWPresentBootRecoveryUI(); } @catch (NSException *e) { (void)e; }
            });
        }
    }
}

// Constructeur dyld : ZERO travail ici (ni Foundation, ni I/O, ni UIKit, ni
// scan de classes pendant le verrou dyld). On ne fait que planifier le
// demarrage sur la queue principale ; c'est la seule operation qui ne peut
// pas echouer ni bloquer dyld.
__attribute__((constructor))
static void NWInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NWStartTweaks();
        } @catch (NSException *e) {
            NWLog("demarrage: %@", e.reason);
        }
    });
}
