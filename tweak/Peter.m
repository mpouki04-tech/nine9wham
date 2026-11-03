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

#define NWLog(fmt, ...) NSLog(@"[nine9wham] " fmt, ##__VA_ARGS__)

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
    NSDictionary *c = (NWActiveID && cs[NWActiveID]) ? cs[NWActiveID] : nil;
    if (c) {
        NWActiveFP = c[@"fp"];
        NWActiveLoc = c[@"loc"];
    }
    [st writeToFile:NWStatePath() atomically:YES];
}

static NSDictionary *NWActiveContainer(NSDictionary *st) {
    NSString *aid = st[@"activeContainer"];
    NSDictionary *cs = st[@"containers"];
    return (aid && cs[aid]) ? cs[aid] : nil;
}

// Ghost actif ou non (copy Blaze : "Enable · Ghost for %@ container").
// Cle par conteneur "ghostOn" ; absente = actif (retrocompatible).
static BOOL NWGhostEnabled(void) {
    NSDictionary *c = NWActiveContainer(NWState ?: @{});
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

// Genere une empreinte aleatoire coherente avec la puce reelle du telephone.
static NSDictionary *NWGenerateFingerprint(void) {
    NSString *real = NWRealMachine();
    NSArray *cohort = NWCohortForMachine(real);
    NSString *fake = cohort[arc4random_uniform((uint32_t)cohort.count)];

    // IDFV / IDFA aleatoires (UUID)
    NSString *idfv = [[NSUUID UUID] UUIDString];
    NSString *idfa = [[NSUUID UUID] UUIDString];

    // Nom de l'appareil aleatoire
    NSArray *names = @[@"iPhone de Peter", @"Armel's iPhone", @"nine9 iPhone", @"Peter iPhone",
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

    // Version iOS reelle conservee par defaut (coherence systeme).
    // Elle reste modifiable dans Ghost : 26.0 -> 27.0.1.
    NSString *sysVer = UIDevice.currentDevice.systemVersion;

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
    };
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
    return v ?: NWOrig_deviceName(self, _cmd);
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
    return NWOrig_systemVersion(self, _cmd);
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
    return NWOrig_osVersion(self, _cmd);
}

static NSOperatingSystemVersion (*NWOrig_procOSVersion)(id, SEL);
static NSOperatingSystemVersion NWHook_procOSVersion(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"sysVer");
    if (v.length) return NWParseOSVersion(v);
    return NWOrig_procOSVersion(self, _cmd);
}

static NSString *(*NWOrig_osVersionString)(id, SEL);
static NSString *NWHook_osVersionString(id self, SEL _cmd) {
    NSString *v = NWFPStr(@"sysVer");
    if (v.length) return [NSString stringWithFormat:@"Version %@ (Build 99A000)", v];
    return NWOrig_osVersionString(self, _cmd);
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
    NSString *s = NWFPStr(@"idfv");
    if (s) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:s];
        if (u) return u;
    }
    return NWOrig_idfv(self, _cmd);
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
    return NWOrig_physMem(self, _cmd);
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

// NSLocale ----------------------------------------------------------------
static id (*NWOrig_currentLocale)(id, SEL);
static id NWHook_currentLocale(id self, SEL _cmd) {
    NSString *loc = NWFPStr(@"locale");
    if (loc) {
        NSLocale *l = [[NSLocale alloc] initWithLocaleIdentifier:loc];
        if (l) return l;
    }
    return NWOrig_currentLocale(self, _cmd);
}

// NSTimeZone --------------------------------------------------------------
static id (*NWOrig_localTZ)(id, SEL);
static id NWHook_localTZ(id self, SEL _cmd) {
    NSString *tz = NWFPStr(@"tz");
    if (tz) {
        NSTimeZone *z = [NSTimeZone timeZoneWithName:tz];
        if (z) return z;
    }
    return NWOrig_localTZ(self, _cmd);
}

static id (*NWOrig_sysTZ)(id, SEL);
static id NWHook_sysTZ(id self, SEL _cmd) {
    NSString *tz = NWFPStr(@"tz");
    if (tz) {
        NSTimeZone *z = [NSTimeZone timeZoneWithName:tz];
        if (z) return z;
    }
    return NWOrig_sysTZ(self, _cmd);
}

// IDFA (AdSupport charge a la demande) ------------------------------------
static NSUUID *(*NWOrig_idfa)(id, SEL);
static NSUUID *NWHook_idfa(id self, SEL _cmd) {
    NSString *s = NWFPStr(@"idfa");
    if (s) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:s];
        if (u) return u;
    }
    return NWOrig_idfa(self, _cmd);
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
    NWSwizzle(object_getClass([NSTimeZone class]), @selector(localTimeZone), (IMP)NWHook_localTZ, &NWOrig_localTZ);
    NWSwizzle(object_getClass([NSTimeZone class]), @selector(systemTimeZone), (IMP)NWHook_sysTZ, &NWOrig_sysTZ);

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
    if (r == 0) {
        NSString *m = NWFPStr(@"model");
        if (m) {
            strncpy(u->machine, m.UTF8String, sizeof(u->machine) - 1);
            u->machine[sizeof(u->machine) - 1] = '\0';
        }
    }
    return r;
}

static int (*NWOrig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int NWHook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = NWOrig_sysctlbyname ? NWOrig_sysctlbyname(name, oldp, oldlenp, newp, newlen)
                                : sysctlbyname(name, oldp, oldlenp, newp, newlen);
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
    return r;
}

static int (*NWOrig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int NWHook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = NWOrig_sysctl ? NWOrig_sysctl(name, namelen, oldp, oldlenp, newp, newlen)
                          : sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    // CTL_HW = 6, HW_MACHINE = 1, HW_MODEL = 6
    if (r == 0 && oldp && namelen >= 2 && name[0] == 6 && (name[1] == 1 || name[1] == 6)) {
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
    return r;
}

// Scanne le __got du binaire principal et remplace les pointeurs cibles.
static void NWRebindGOT(void) {
    const struct mach_header *mh = _dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) { NWLog("header principal invalide"); return; }
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysym = NULL;
    const struct segment_command_64 *gotSeg = NULL;
    const struct section_64 *gotSec = NULL;

    const uint8_t *cmd = (const uint8_t *)(mh64 + 1);
    for (uint32_t i = 0; i < mh64->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysym = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            const struct section_64 *sec = (const struct section_64 *)(sg + 1);
            for (uint32_t s = 0; s < sg->nsects; s++) {
                if (strncmp(sec[s].sectname, "__got", 5) == 0 ||
                    strncmp(sec[s].sectname, "__auth_got", 10) == 0) {
                    gotSeg = sg; gotSec = &sec[s];
                }
            }
        }
        cmd += lc->cmdsize;
    }
    if (!symtab || !dysym || !gotSec) { NWLog("got/symtab introuvable"); return; }
    (void)symtab; (void)dysym;   // requis pour la localisation du got
    // Les offsets du symtab sont des offsets fichier -> on rebind par VA :
    // on resout les symboles via dlsym et on compare les valeurs dans le got.
    void *targets[3];
    const char *names[3] = { "uname", "sysctlbyname", "sysctl" };
    void *repls[3];
    void **origs[3];
    for (int t = 0; t < 3; t++) {
        targets[t] = dlsym(RTLD_DEFAULT, names[t]);
        repls[t] = (t == 0) ? (void *)NWHook_uname : (t == 1 ? (void *)NWHook_sysctlbyname : (void *)NWHook_sysctl);
        origs[t] = (t == 0) ? (void **)&NWOrig_uname : (t == 1 ? (void **)&NWOrig_sysctlbyname : (void **)&NWOrig_sysctl);
    }

    uint64_t va = gotSec->addr;
    uint64_t size = gotSec->size;
    uint64_t count = size / 8;
    // Adresse reelle = slide + vmaddr (l'entete est deja slide+0 pour l'image 0,
    // mais on passe par la VA section pour rester generique).
    void **slots = (void **)(slide + va);
    int patched = 0;
    for (uint64_t i = 0; i < count; i++) {
        for (int t = 0; t < 3; t++) {
            if (!targets[t]) continue;
            if (slots[i] == targets[t]) {
                // ecriture : __DATA_CONST,__got est passe en lecture seule apres
                // binding. Pages iOS = 16 Ko -> alignement sur 0x4000.
                vm_address_t page = (vm_address_t)((uintptr_t)&slots[i] & ~(uintptr_t)0x3FFF);
                vm_protect(mach_task_self(), page, (vm_size_t)0x4000, 0,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                *(origs[t]) = targets[t];
                slots[i] = repls[t];
                patched++;
                NWLog("GOT rebinding: %s", names[t]);
            }
        }
    }
    NWLog("GOT: %d pointeur(s) remplace(s) dans %s,%s", patched, gotSeg->segname, gotSec->sectname);
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
        ((Fn)objc_msgSend)(delegate, sel, mgr, @[fake]);
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
    if (delegate) NWHookDelegateClass(object_getClass(delegate));
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

#pragma mark - Moteur conteneurs

static NSString *NWBundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"com.burbn.instagram";
}

// Sauvegarde l'etat courant (prefs + cookies) DANS le conteneur actif.
static void NWSnapshotActive(void) {
    if (!NWActiveID) return;
    NSString *dir = NWContainerDir(NWActiveID);

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
    NSDictionary *fp = NWGenerateFingerprint();

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
    newSt[@"activeContainer"] = cid;
    NWSaveState(newSt);
    NWPersistState();

    NWActiveID = cid;
    NWActiveFP = fp;
    NWActiveLoc = containers[cid][@"loc"];
    NWRestoreContainer(cid);   // applique le dossier vierge (prefs = rien)

    NWLog("conteneur cree: %@ (modele fictif=%@)", cid, fp[@"model"]);
    return cid;
}

// Variante sans localisation (conteneur standard).
static NSString *NWCreateContainerWithLoc(NSString *name, NSDictionary *locOpt) {
    return NWCreateContainerWithLocGhost(name, locOpt, YES);
}

static NSString *NWCreateContainer(NSString *name) {
    return NWCreateContainerWithLoc(name, nil);
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
        NSString *cid = NWCreateContainer(@"Peter");
        NWLog("premier lancement, conteneur par defaut: %@", cid);
        return;
    }
    NWSaveState(st);
    NSString *aid = st[@"activeContainer"];
    if ([aid isKindOfClass:[NSString class]] && st[@"containers"][aid]) {
        NWRestoreContainer(aid);
        NWLog("conteneur actif: %@ (modele=%@)", aid, NWActiveFP[@"model"]);
    }
}

#pragma mark - Menu flottant @nine9wham (design Blaze)

// ---------------------------------------------------------------------------
// Theme (sombre, accent violet/bleu, cartes arrondies)
// ---------------------------------------------------------------------------
static UIColor *NWBg(void)        { return [UIColor colorWithRed:0.043 green:0.043 blue:0.058 alpha:1.0]; }
static UIColor *NWCardColor(void) { return [UIColor colorWithRed:0.078 green:0.078 blue:0.102 alpha:1.0]; }
static UIColor *NWAccent(void)    { return [UIColor colorWithRed:0.49 green:0.36 blue:1.00 alpha:1.0]; }
static UIColor *NWBlue(void)      { return [UIColor colorWithRed:0.30 green:0.64 blue:1.00 alpha:1.0]; }
static UIColor *NWGreen(void)     { return [UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:1.0]; }
static UIColor *NWRed(void)       { return [UIColor colorWithRed:1.00 green:0.36 blue:0.42 alpha:1.0]; }
static UIColor *NWDim(void)       { return [UIColor colorWithWhite:1.0 alpha:0.55]; }
static UIColor *NWLine(void)      { return [UIColor colorWithWhite:1.0 alpha:0.08]; }

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

// Emoji drapeau depuis un code ISO a 2 lettres ("FR" -> 🇫🇷).
static NSString *NWFlagEmoji(NSString *iso) {
    NSString *u = [iso uppercaseString];
    if (u.length != 2) return @"🌍";
    unichar a = [u characterAtIndex:0], b = [u characterAtIndex:1];
    if (a < 'A' || a > 'Z' || b < 'A' || b > 'Z') return @"🌍";
    return [NSString stringWithFormat:@"%C%C\uFE0F",
            (unichar)(0x1F1E6 + (a - 'A')), (unichar)(0x1F1E6 + (b - 'A'))];
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
    p[key] = value ?: [NSNull null];
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

static void NWApplyLocation(NSString *cid, double lat, double lon, NSString *label) {
    if (!cid) return;
    NWUpdateContainerField(cid, @"loc", @{@"on": @YES, @"lat": @(lat), @"lon": @(lon),
                                          @"label": label ?: @""});
    NWReloadAfterStateChange();
}

#pragma mark - Carte du monde (sélecteur de localisation)

// Carte plein écran façon Blaze : pin fixe au centre, la carte bouge dessous,
// recherche par barre (Nominatim), reverse geocoding, types de carte
// Standard / Hybrid / Satellite et bouton "Set Location".
@interface NWMapPicker : UIViewController <MKMapViewDelegate, UISearchBarDelegate,
                                           UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^onPick)(double lat, double lon, NSString *label);
@property (nonatomic, assign) CLLocationCoordinate2D initial;
+ (void)presentFrom:(UIViewController *)host
           initial:(CLLocationCoordinate2D)coord
             onPick:(void (^)(double lat, double lon, NSString *label))onPick;
@end

@implementation NWMapPicker {
    MKMapView *_map;
    UISearchBar *_search;
    UITableView *_results;
    UILabel *_addr;
    NSArray<NSDictionary *> *_hits;
    CLGeocoder *_geo;
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
                                        target:self action:@selector(cancelPick)];
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

    // Pin fixe : son extrémité pointe vers le centre exact de la carte.
    UIImageView *pin = [[UIImageView alloc] initWithImage:NWSymbol(@"mappin.fill", 34)];
    pin.tintColor = NWRed();
    pin.translatesAutoresizingMaskIntoConstraints = NO;
    pin.userInteractionEnabled = NO;
    [self.view addSubview:pin];

    // Barre de recherche (design Blaze : champ arrondi sombre, texte blanc)
    _search = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.delegate = self;
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.backgroundColor = UIColor.clearColor;
    _search.tintColor = NWAccent();
    if (@available(iOS 13.0, *)) {
        UITextField *tf = _search.searchTextField;
        tf.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        tf.textColor = UIColor.whiteColor;
        tf.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        tf.layer.cornerRadius = 14;
        tf.layer.masksToBounds = YES;
        tf.attributedPlaceholder = [[NSAttributedString alloc]
            initWithString:@"Search a place..."
                attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    } else {
        _search.placeholder = @"Search a place...";
    }
    [self.view addSubview:_search];

    // Résultats de recherche
    _results = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _results.translatesAutoresizingMaskIntoConstraints = NO;
    _results.dataSource = self;
    _results.delegate = self;
    _results.backgroundColor = NWCardColor();
    _results.layer.cornerRadius = 12;
    _results.clipsToBounds = YES;
    _results.rowHeight = 52;
    _results.hidden = YES;
    _results.separatorColor = NWLine();
    [self.view addSubview:_results];

    // Carte du bas : adresse + type de carte
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [NWCardColor() colorWithAlphaComponent:0.94];
    card.layer.cornerRadius = 16;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NWLine().CGColor;
    [self.view addSubview:card];

    _addr = NWLabelMake(@"Move the map to choose a location", 13,
                        UIColor.whiteColor, UIFontWeightMedium);
    _addr.numberOfLines = 2;
    _addr.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_addr];

    UISegmentedControl *seg =
        [[UISegmentedControl alloc] initWithItems:@[@"Standard", @"Hybrid", @"Satellite"]];
    seg.selectedSegmentIndex = 0;
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    seg.tintColor = NWAccent();
    [seg addTarget:self action:@selector(mapTypeChanged:)
 forControlEvents:UIControlEventValueChanged];
    [card addSubview:seg];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_map.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_map.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [pin.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [pin.bottomAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_search.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_search.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_search.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_search.heightAnchor constraintEqualToConstant:44],

        [_results.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:6],
        [_results.leadingAnchor constraintEqualToAnchor:_search.leadingAnchor],
        [_results.trailingAnchor constraintEqualToAnchor:_search.trailingAnchor],
        [_results.heightAnchor constraintEqualToConstant:210],

        [card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],

        [_addr.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [_addr.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [_addr.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [seg.topAnchor constraintEqualToAnchor:_addr.bottomAnchor constant:10],
        [seg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [seg.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [seg.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];

    CLLocationCoordinate2D c = self.initial;
    if (!CLLocationCoordinate2DIsValid(c) || (c.latitude == 0 && c.longitude == 0))
        c = CLLocationCoordinate2DMake(48.8566, 2.3522);   // Paris
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 3000, 3000);
    [_map setRegion:region animated:NO];
    [self reverseGeocode:c];
}

- (void)cancelPick { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)confirmPick {
    CLLocationCoordinate2D c = _map.centerCoordinate;
    NSString *label = _addr.text.length ? _addr.text : @"Current Location";
    void (^cb)(double, double, NSString *) = self.onPick;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(c.latitude, c.longitude, label);
    }];
}

- (void)mapTypeChanged:(UISegmentedControl *)seg {
    switch (seg.selectedSegmentIndex) {
        case 1: _map.mapType = MKMapTypeHybrid; break;
        case 2: _map.mapType = MKMapTypeSatellite; break;
        default: _map.mapType = MKMapTypeStandard; break;
    }
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    [self reverseGeocode:mapView.centerCoordinate];
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

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
    NSString *q = [sb.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
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

- (void)searchBarTextDidBeginEditing:(UISearchBar *)sb {
    sb.showsCancelButton = YES;
}
- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.showsCancelButton = NO;
    [sb resignFirstResponder];
    _results.hidden = YES;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)n { return _hits.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"nw.hit";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
        cell.backgroundColor = NWCardColor();
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
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 2500, 2500);
    [_map setRegion:region animated:YES];
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
    return vc;
}

// Relance requise pour qu'Instagram recharge prefs / cookies / empreinte.
static void NWAskRelaunch(NSString *raison) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Restart required"
        message:[NSString stringWithFormat:@"%@ needs to restart to apply this change.", raison]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        exit(0);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = NWTopVC();
    if (top.presentedViewController) return;
    [top presentViewController:a animated:YES completion:nil];
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
@end

@implementation NWFloatingButton

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.touchStart = [touches.anyObject locationInView:self.superview];
    self.dragging = NO;
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInView:self.superview];
    CGFloat dx = p.x - self.touchStart.x, dy = p.y - self.touchStart.y;
    if (!self.dragging && (fabs(dx) > 4 || fabs(dy) > 4)) self.dragging = YES;
    if (self.dragging) {
        CGPoint c = self.center;
        c.x += dx; c.y += dy;
        self.center = c;
        self.touchStart = p;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (!self.dragging) {
        NWTogglePanel();
        return;
    }
    UIView *v = self.superview;
    CGRect f = self.frame;
    CGFloat mid = v.bounds.size.width / 2;
    f.origin.x = (self.center.x < mid) ? 8 : v.bounds.size.width - f.size.width - 8;
    f.origin.y = MIN(MAX(f.origin.y, 60), v.bounds.size.height - f.size.height - 34);
    [UIView animateWithDuration:0.15 animations:^{ self.frame = f; }];
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *ui = [st[@"ui"] mutableCopy] ?: [NSMutableDictionary dictionary];
    ui[@"x"] = @(f.origin.x);
    ui[@"y"] = @(f.origin.y);
    NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
    newSt[@"ui"] = ui;
    NWSaveState(newSt);
    NWPersistState();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.dragging = NO;
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
        NWFloatingButton *b = [NWFloatingButton buttonWithType:UIButtonTypeCustom];
        b.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.96];
        b.layer.cornerRadius = 27;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [NWAccent() colorWithAlphaComponent:0.9].CGColor;
        b.layer.shadowColor = UIColor.blackColor.CGColor;
        b.layer.shadowOpacity = 0.55;
        b.layer.shadowRadius = 10;
        b.layer.shadowOffset = CGSizeMake(0, 4);
        [b setTitle:@"99" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightHeavy];
        b.accessibilityLabel = @"Menu nine9wham";
        NWMenuButton = b;
    }

    NSDictionary *ui = (NWState ?: @{})[@"ui"];
    NSNumber *ux = [ui[@"x"] isKindOfClass:[NSNumber class]] ? ui[@"x"] : nil;
    NSNumber *uy = [ui[@"y"] isKindOfClass:[NSNumber class]] ? ui[@"y"] : nil;
    CGSize s = root.bounds.size;
    CGFloat x = ux ? ux.doubleValue : (s.width - 54 - 12);
    CGFloat y = uy ? uy.doubleValue : (s.height * 0.45);
    x = MAX(6, MIN(x, s.width - 54 - 6));
    y = MAX(60, MIN(y, s.height - 54 - 34));
    NWMenuButton.frame = CGRectMake(x, y, 54, 54);
    if (NWMenuButton.superview != root) [root addSubview:NWMenuButton];
    NWLog("bouton flottant installe (%.0f, %.0f)", x, y);
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
    self.backgroundColor = NWCardColor();
    self.layer.cornerRadius = 16;
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
    self.backgroundColor = NWCardColor();
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.backgroundColor = NWCardColor();
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

    _iconView = [[UIImageView alloc] initWithImage:NWSymbol(icon, 15)];
    _iconView.tintColor = NWAccent();
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_iconView];

    _titleLabel = NWLabelMake(title, 14.5, UIColor.whiteColor, UIFontWeightMedium);
    _titleLabel.numberOfLines = 1;
    [self addSubview:_titleLabel];

    if (subtitle.length) {
        _subLabel = NWLabelMake(subtitle, 11, NWDim(), UIFontWeightRegular);
        _subLabel.numberOfLines = 1;
        [self addSubview:_subLabel];
    }

    _toggle = [[UISwitch alloc] init];
    _toggle.onTintColor = NWAccent();
    _toggle.on = on;
    [self addSubview:_toggle];

    __weak typeof(self) weakSelf = self;
    NWBind(_toggle, ^(id sender) {
        if (weakSelf.onChange) weakSelf.onChange(((UISwitch *)sender).isOn);
    });
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat textW = w - 48 - 14 - 62;
    _iconView.frame = CGRectMake(14, (h - 20) / 2.0, 20, 20);
    _toggle.frame = CGRectMake(w - 14 - 51, (h - 31) / 2.0, 51, 31);
    if (_subLabel) {
        // SwitchListCell Blaze : titre + sous-titre empiles.
        _titleLabel.frame = CGRectMake(48, (h - 36) / 2.0, textW, 19);
        _subLabel.frame = CGRectMake(48, _titleLabel.frame.origin.y + 20, textW, 15);
    } else {
        _titleLabel.frame = CGRectMake(48, 0, textW, h);
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
        cell.tintColor = NWAccent();
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
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
    ghostRow.layer.cornerRadius = 14;
    ghostRow.translatesAutoresizingMaskIntoConstraints = NO;
    [ghostRow.heightAnchor constraintEqualToConstant:60].active = YES;
    [stack addArrangedSubview:ghostRow];
    _ghostSwitch = ghostRow.toggle;

    // --- Spoof Location (carte du monde) ---
    UIControl *locRow = [[UIControl alloc] init];
    locRow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    locRow.layer.cornerRadius = 14;
    locRow.translatesAutoresizingMaskIntoConstraints = NO;
    [locRow.heightAnchor constraintEqualToConstant:52].active = YES;

    UIImageView *pin = [[UIImageView alloc] initWithImage:NWSymbol(@"location.fill", 16)];
    pin.tintColor = NWBlue();
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
    create.alpha = 0.45;
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
    _create.alpha = ok ? 1.0 : 0.45;
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
    self.backgroundColor = NWCardColor();
    self.layer.cornerRadius = 16;
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
    self.view.backgroundColor = NWBg();

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
    for (UIView *v in [self.bar.arrangedSubviews copy]) {
        [self.bar removeArrangedSubview:v];
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

    if (!self.module) {
        [self buildHome];
    } else if ([self.module isEqualToString:@"device"] ||
               [self.module isEqualToString:@"about"]) {
        [self buildDevice];
    } else if ([self.module isEqualToString:@"location"]) {
        [self buildLocation];
    } else if ([self.module isEqualToString:@"ghost"]) {
        [self buildGhost];
    } else if ([self.module isEqualToString:@"containers"]) {
        [self buildContainers];
    } else if ([self.module isEqualToString:@"proxy"]) {
        [self buildProxy];
    } else if ([self.module isEqualToString:@"changelog"]) {
        [self buildChangelog];
    } else if ([self.module isEqualToString:@"support"]) {
        [self buildSupport];
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
    };
    return titles[self.module] ?: @"nine9wham";
}

- (void)buildTopBar {
    if (!self.module) {
        UIView *logo = [[UIView alloc] init];
        logo.backgroundColor = [NWAccent() colorWithAlphaComponent:0.18];
        logo.layer.cornerRadius = 9;
        logo.translatesAutoresizingMaskIntoConstraints = NO;
        [logo.widthAnchor constraintEqualToConstant:34].active = YES;
        [logo.heightAnchor constraintEqualToConstant:34].active = YES;
        UILabel *nine = NWLabelMake(@"9", 17, UIColor.whiteColor, UIFontWeightHeavy);
        nine.textAlignment = NSTextAlignmentCenter;
        nine.translatesAutoresizingMaskIntoConstraints = NO;
        [logo addSubview:nine];
        [NSLayoutConstraint activateConstraints:@[
            [nine.centerXAnchor constraintEqualToAnchor:logo.centerXAnchor],
            [nine.centerYAnchor constraintEqualToAnchor:logo.centerYAnchor],
        ]];
        [self.bar addArrangedSubview:logo];

        UIStackView *titles = [[UIStackView alloc] init];
        titles.axis = UILayoutConstraintAxisVertical;
        titles.spacing = 1;
        UILabel *t = NWLabelMake(@"nine9wham", 17, UIColor.whiteColor, UIFontWeightBold);
        UILabel *s = NWLabelMake(@"@nine9wham · Instagram", 10, NWDim(), UIFontWeightRegular);
        [titles addArrangedSubview:t];
        [titles addArrangedSubview:s];
        [self.bar addArrangedSubview:titles];
    } else {
        [self.bar addArrangedSubview:NWIconButton(@"chevron.left", ^(id s){
            self.module = nil;
            [self rebuild];
        })];
        UIStackView *titles = [[UIStackView alloc] init];
        titles.axis = UILayoutConstraintAxisVertical;
        titles.spacing = 1;
        UILabel *t = NWLabelMake([self moduleTitle], 17, UIColor.whiteColor, UIFontWeightBold);
        UILabel *s = NWLabelMake(@"nine9wham", 10, NWDim(), UIFontWeightRegular);
        [titles addArrangedSubview:t];
        [titles addArrangedSubview:s];
        [self.bar addArrangedSubview:titles];

        // Copy Blaze : bouton "ellipsis" = menu "Sort by" sur l'ecran Containers.
        if ([self.module isEqualToString:@"containers"]) {
            UIButton *sortBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            [sortBtn setImage:NWSymbol(@"ellipsis", 20) forState:UIControlStateNormal];
            sortBtn.tintColor = UIColor.whiteColor;
            sortBtn.showsMenuAsPrimaryAction = YES;
            sortBtn.menu = [self sortMenu];
            sortBtn.translatesAutoresizingMaskIntoConstraints = NO;
            [sortBtn.widthAnchor constraintEqualToConstant:38].active = YES;
            [sortBtn.heightAnchor constraintEqualToConstant:38].active = YES;
            [self.bar addArrangedSubview:sortBtn];
        }
    }

    [self.bar addArrangedSubview:NWSpacer()];
    [self.bar addArrangedSubview:NWIconButton(@"xmark", ^(id s){
        [self dismissViewControllerAnimated:YES completion:nil];
    })];
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

// --- Pied de page "New Container" (copy Blaze) ----------------------------
- (void)buildContainersFooter {
    __weak typeof(self) weakSelf = self;

    UIButton *label = [UIButton buttonWithType:UIButtonTypeCustom];
    [label setTitle:@"New Container" forState:UIControlStateNormal];
    [label setTitleColor:NWDim() forState:UIControlStateNormal];
    label.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NWBind(label, ^(id s){
        __strong typeof(weakSelf) self2 = weakSelf;
        if (self2) [self2 presentNewContainerSheet:nil];
    });
    [self.footer addSubview:label];

    UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
    [plus setImage:NWSymbol(@"plus", 24) forState:UIControlStateNormal];
    plus.tintColor = UIColor.whiteColor;
    plus.backgroundColor = NWAccent();
    plus.layer.cornerRadius = 27.5;
    plus.layer.shadowColor = UIColor.blackColor.CGColor;
    plus.layer.shadowOpacity = 0.45;
    plus.layer.shadowRadius = 8;
    plus.layer.shadowOffset = CGSizeMake(0, 3);
    if (@available(iOS 13.0, *)) plus.layer.cornerCurve = kCACornerCurveContinuous;
    plus.translatesAutoresizingMaskIntoConstraints = NO;
    plus.accessibilityLabel = @"New Container";
    NWBind(plus, ^(id s){
        __strong typeof(weakSelf) self2 = weakSelf;
        if (self2) [self2 presentNewContainerSheet:nil];
    });
    [self.footer addSubview:plus];

    [NSLayoutConstraint activateConstraints:@[
        [plus.centerXAnchor constraintEqualToAnchor:self.footer.centerXAnchor],
        [plus.bottomAnchor constraintEqualToAnchor:self.footer.bottomAnchor constant:-30],
        [plus.widthAnchor constraintEqualToConstant:55],
        [plus.heightAnchor constraintEqualToConstant:55],
        [label.centerXAnchor constraintEqualToAnchor:self.footer.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:plus.topAnchor constant:-4],
        [label.heightAnchor constraintEqualToConstant:22],
    ]];
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
    card.backgroundColor = NWCardColor();
    card.layer.cornerRadius = 16;
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
    card.backgroundColor = NWCardColor();
    card.layer.cornerRadius = 16;
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

- (void)buildHome {
    NSDictionary *c = NWActiveContainerDict();
    NSDictionary *fp = c[@"fp"] ?: @{};
    NSDictionary *loc = c[@"loc"] ?: @{};
    NSString *name = c[@"name"] ?: @"No active container";
    NSString *model = NWModelName(fp[@"model"]);
    NSString *ios = fp[@"sysVer"] ?: UIDevice.currentDevice.systemVersion;
    BOOL gpsOn = [loc[@"on"] boolValue];
    __weak typeof(self) weakSelf = self;

    // --- HeaderView (copy Blaze : titre + sous-titre) ---
    UIView *header = [[UIView alloc] init];
    header.backgroundColor = NWCardColor();
    header.layer.cornerRadius = 18;
    header.layer.borderWidth = 1;
    header.layer.borderColor = [NWAccent() colorWithAlphaComponent:0.35].CGColor;

    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 8;
    v.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    v.layoutMarginsRelativeArrangement = YES;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:header.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [v.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];

    UILabel *kicker = NWLabelMake(@"Dashboard", 11, NWAccent(), UIFontWeightBold);
    UILabel *title = NWLabelMake(name, 22, UIColor.whiteColor, UIFontWeightBold);
    UILabel *sub = NWLabelMake(@"nine9wham Your Way", 12.5, NWDim(), UIFontWeightRegular);
    [v addArrangedSubview:kicker];
    [v addArrangedSubview:title];
    [v addArrangedSubview:sub];

    UIStackView *badges = [[UIStackView alloc] init];
    badges.axis = UILayoutConstraintAxisHorizontal;
    badges.spacing = 6;
    [badges addArrangedSubview:NWBadge(model, NWBlue())];
    [badges addArrangedSubview:NWBadge([NSString stringWithFormat:@"iOS %@", ios], NWAccent())];
    [badges addArrangedSubview:NWBadge(gpsOn ? @"GPS ON" : @"GPS OFF", gpsOn ? NWGreen() : NWDim())];
    [badges addArrangedSubview:NWBadge(name, NWDim())];
    [v addArrangedSubview:badges];

    [self.content addArrangedSubview:header];

    // --- Grille de modules (GridCell Blaze : 2 colonnes, icone + titre) ---
    NSArray *mods = @[
        @[@"Ghost", @"private:emoji.ghost", @"ghost"],
        @[@"Orbit", @"location.fill", @"location"],
        @[@"Proxy", @"shield.lefthalf.filled", @"proxy"],
        @[@"Containers", @"square.stack.3d.up.fill", @"containers"],
        @[@"App & Device", @"iphone", @"device"],
        @[@"Changelog", @"note.text", @"changelog"],
    ];

    for (NSUInteger i = 0; i < mods.count; i += 2) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger k = i; k < MIN(i + 2, mods.count); k++) {
            NSArray *m = mods[k];
            NWGridCell *cell = [[NWGridCell alloc] initWithIcon:m[1] title:m[0] subtitle:nil tint:NWAccent()];
            NWBind(cell, ^(id s){ [weakSelf openModule:m[2]]; });
            [row addArrangedSubview:cell];
        }
        if ((mods.count - i) == 1) [row addArrangedSubview:[[UIView alloc] init]];
        [row.heightAnchor constraintEqualToConstant:110].active = YES;
        [self.content addArrangedSubview:row];
    }

    // --- Section "App & Device" (ListCell Blaze : About + Device) ---
    [self addSection:@"App & Device"];
    UIStackView *ad = [self addRowsCard];
    [self addRow:ad icon:@"info" title:@"About"
           value:[NSString stringWithFormat:@"General info about %@", @"@nine9wham"] action:^{
        [weakSelf openModule:@"about"];
    }];
    [self addRow:ad icon:@"iphone" title:@"Device"
           value:@"View your device's info" action:^{
        [weakSelf openModule:@"device"];
    }];

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
    [self addRow:sup icon:@"paperplane.fill" title:@"Contact us on Telegram"
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
    [self addRow:rst icon:@"trash.fill" title:@"Erase nine9wham's"
           value:@"Containers & settings to default" action:^{
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

    // --- Hero (copy Blaze : "App & Device" / "General info about ...") -----
    UIView *hero = [[UIView alloc] init];
    hero.backgroundColor = NWCardColor();
    hero.layer.cornerRadius = 18;
    hero.layer.borderWidth = 1;
    hero.layer.borderColor = [NWBlue() colorWithAlphaComponent:0.35].CGColor;

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
    UILabel *kicker = NWLabelMake(@"About", 11, NWBlue(), UIFontWeightBold);
    UILabel *title = NWLabelMake(@"App & Device", 21, UIColor.whiteColor, UIFontWeightBold);
    UILabel *sub = NWLabelMake(@"General info about @nine9wham", 12.5, NWDim(), UIFontWeightRegular);
    [v addArrangedSubview:kicker];
    [v addArrangedSubview:title];
    [v addArrangedSubview:sub];
    UIStackView *badges = [[UIStackView alloc] init];
    badges.axis = UILayoutConstraintAxisHorizontal;
    badges.spacing = 6;
    [badges addArrangedSubview:NWBadge(c[@"name"] ?: @"default", NWAccent())];
    [badges addArrangedSubview:NWBadge(NWGhostEnabled() ? @"Ghost ON" : @"Ghost OFF",
                                       NWGhostEnabled() ? NWGreen() : NWDim())];
    [v addArrangedSubview:badges];
    [self.content addArrangedSubview:hero];

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

    // --- Section "Orbit" (copy Blaze) -------------------------------------
    NSString *cname = c[@"name"] ?: @"default";
    [self addSection:@"Orbit"];
    NWSwitchRow *sw = [[NWSwitchRow alloc] initWithIcon:@"location.fill"
                                                   title:@"Enable"
                                               subtitle:[NSString stringWithFormat:@"Orbit for %@ container", cname]
                                                     on:on];
    [sw.heightAnchor constraintEqualToConstant:60].active = YES;
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
        if (![p[@"on"] boolValue] || ![p[@"host"] length]) {
            NWAlert(@"Load", @"Unable to load coordinates from the proxy");
            return;
        }
        [weakSelf lookupProxyIP:p[@"host"]];
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

    // --- Hero (copy Blaze : emoji.ghost + "Ghost" + "Device Fingerprint Spoofer") ---
    UIView *hero = [[UIView alloc] init];
    hero.backgroundColor = NWCardColor();
    hero.layer.cornerRadius = 18;
    hero.layer.borderWidth = 1;
    hero.layer.borderColor = [NWGreen() colorWithAlphaComponent:0.35].CGColor;

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
    tile.backgroundColor = [NWGreen() colorWithAlphaComponent:0.16];
    tile.layer.cornerRadius = 14;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile.widthAnchor constraintEqualToConstant:48].active = YES;
    [tile.heightAnchor constraintEqualToConstant:48].active = YES;
    UIImageView *icon = [[UIImageView alloc] initWithImage:NWSymbol(@"private:emoji.ghost", 22)];
    if (!icon.image) icon.image = NWSymbol(@"shield.lefthalf.filled", 22);
    icon.tintColor = NWGreen();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];
    UIStackView *tv = [[UIStackView alloc] init];
    tv.axis = UILayoutConstraintAxisVertical;
    tv.spacing = 2;
    UILabel *h1 = NWLabelMake(@"Ghost", 20, UIColor.whiteColor, UIFontWeightBold);
    UILabel *h2 = NWLabelMake(@"Device Fingerprint Spoofer", 12, [UIColor colorWithWhite:1 alpha:0.6], UIFontWeightRegular);
    [tv addArrangedSubview:h1];
    [tv addArrangedSubview:h2];
    [head addArrangedSubview:tile];
    [head addArrangedSubview:tv];
    [v addArrangedSubview:head];

    UIStackView *badges = [[UIStackView alloc] init];
    badges.axis = UILayoutConstraintAxisHorizontal;
    badges.spacing = 6;
    [badges addArrangedSubview:NWBadge(NWModelName(model), NWBlue())];
    [badges addArrangedSubview:NWBadge([NSString stringWithFormat:@"iOS %@", fp[@"sysVer"] ?: @"—"], NWAccent())];
    [badges addArrangedSubview:NWBadge(ghostOn ? @"Spoof ON" : @"Spoof OFF", ghostOn ? NWGreen() : NWDim())];
    [v addArrangedSubview:badges];
    [self.content addArrangedSubview:hero];

    // --- Section "Ghost" (copy Blaze : Enable · Ghost for %@ container) -----
    [self addSection:@"Ghost"];
    NWSwitchRow *sw = [[NWSwitchRow alloc] initWithIcon:@"globe"
                                                   title:@"Enable"
                                               subtitle:[NSString stringWithFormat:@"Ghost for %@ container", cname]
                                                     on:ghostOn];
    [sw.heightAnchor constraintEqualToConstant:60].active = YES;
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
           value:[NSString stringWithFormat:@"%@ %@", NWFlagEmoji(iso), iso] action:^{
        [weakSelf pickPreferredCountry];
    }];

    // --- Section "Generate" (copy Blaze : Formulate) -----------------------
    [self addSection:@"Generate"];
    UIStackView *gen = [self addRowsCard];
    [self addRow:gen icon:@"plus.forwardslash.minus" title:@"Formulate"
           value:@"Random data for all modules" action:^{
        NSMutableDictionary *nfp = [NWGenerateFingerprint() mutableCopy];
        if (fp[@"sysVer"]) nfp[@"sysVer"] = fp[@"sysVer"];
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
        NSMutableDictionary *nfp = [NWGenerateFingerprint() mutableCopy];
        if (fp[@"sysVer"]) nfp[@"sysVer"] = fp[@"sysVer"];
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

    // --- Section "Device" (copy Blaze : Enable Spoof / Choose an iPhone) ----
    [self addSection:@"Device"];
    UIStackView *dev = [self addRowsCard];
    [self addRow:dev icon:@"apps.iphone.badge.plus" title:@"Choose an iPhone"
           value:NWModelName(model) action:^{
        [weakSelf pickModel];
    }];
    [self addRow:dev icon:@"ios-version" title:@"Choose Version"
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

    UILabel *note = NWLabelMake(@"Spoofed values are applied per container through the hooks. Restart Instagram so the app reads the new fingerprint.",
                                11, NWDim(), UIFontWeightRegular);
    [self.content addArrangedSubview:note];
}

// Pays preferentiel global (copy Blaze) : ouvre la liste des locales/pays.
- (void)pickPreferredCountry {
    NSArray *pairs = @[
        @[@"fr_FR", @"Europe/Paris"], @[@"en_US", @"America/New_York"],
        @[@"en_GB", @"Europe/London"], @[@"es_ES", @"Europe/Madrid"],
        @[@"de_DE", @"Europe/Berlin"], @[@"it_IT", @"Europe/Rome"],
        @[@"ar_SA", @"Asia/Riyadh"], @[@"pt_BR", @"America/Sao_Paulo"],
        @[@"ja_JP", @"Asia/Tokyo"], @[@"nl_NL", @"Europe/Amsterdam"],
        @[@"fr_CA", @"America/Montreal"], @[@"en_AU", @"Australia/Sydney"],
    ];
    NSMutableArray *opts = [NSMutableArray array];
    for (NSArray *p in pairs) {
        NSString *locale = p[0];
        NSString *iso = [locale substringFromIndex:locale.length - 2];
        [opts addObject:@{@"title": [NSString stringWithFormat:@"%@ %@", NWFlagEmoji(iso), iso],
                          @"subtitle": [NSString stringWithFormat:@"%@ · %@", p[0], p[1]],
                          @"value": p[0], @"tz": p[1]}];
    }
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:(NWActiveFP[@"locale"] ?: @"")
                 heading:@"Preferred Country (global)"
                    pick:^(NSDictionary *opt) {
        NWUpdateActiveFPKey(@"locale", opt[@"value"]);
        if (opt[@"tz"]) NWUpdateActiveFPKey(@"tz", opt[@"tz"]);
        NWReloadAfterStateChange();
        [weakSelf rebuild];
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
    NSArray *pairs = @[
        @[@"fr_FR", @"Europe/Paris"], @[@"en_US", @"America/New_York"],
        @[@"en_GB", @"Europe/London"], @[@"es_ES", @"Europe/Madrid"],
        @[@"de_DE", @"Europe/Berlin"], @[@"it_IT", @"Europe/Rome"],
        @[@"ar_SA", @"Asia/Riyadh"], @[@"pt_BR", @"America/Sao_Paulo"],
        @[@"ja_JP", @"Asia/Tokyo"], @[@"nl_NL", @"Europe/Amsterdam"],
        @[@"fr_CA", @"America/Montreal"], @[@"en_AU", @"Australia/Sydney"],
    ];
    NSMutableArray *opts = [NSMutableArray array];
    for (NSArray *p in pairs) {
        [opts addObject:@{@"title": p[0], @"subtitle": p[1], @"value": p[0], @"tz": p[1]}];
    }
    __weak typeof(self) weakSelf = self;
    [self presentOptions:opts selected:(NWActiveFP[@"locale"] ?: @"") heading:@"Choose Locale & Language" pick:^(NSDictionary *opt) {
        NWUpdateActiveFPKey(@"locale", opt[@"value"]);
        if (opt[@"tz"]) NWUpdateActiveFPKey(@"tz", opt[@"tz"]);
        [weakSelf rebuild];
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
    NSArray *ids = containers.allKeys;
    ids = [ids sortedArrayUsingComparator:^NSComparisonResult(id objA, id objB) {
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
        cell.ghostBtn.tintColor = ghostOn ? [UIColor colorWithWhite:1 alpha:0.9]
                                          : [UIColor colorWithWhite:1 alpha:0.25];
        cell.locBtn.tintColor = gpsOn ? NWBlue() : [UIColor colorWithWhite:1 alpha:0.25];
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
}

// Feuille "New Container" (copy Blaze). locOpt : position choisie sur la carte.
- (void)presentNewContainerSheet:(NSDictionary *)locOpt {
    NWNewContainerSheet *sheet = [[NWNewContainerSheet alloc] init];
    sheet.initialLoc = locOpt;
    __weak typeof(self) weakSelf = self;
    sheet.onCreate = ^(NSString *name, NSDictionary *loc, BOOL ghostOn) {
        NSString *cid = NWCreateContainerWithLocGhost(name, loc ? loc : locOpt, ghostOn);
        [weakSelf rebuild];
        NWAskRelaunch([NSString stringWithFormat:@"The container %@", name.length ? name : cid]);
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
    BOOL on = [p[@"on"] boolValue];
    NSString *cname = NWActiveContainerDict()[@"name"] ?: @"default";
    NSString *host = [p[@"host"] isKindOfClass:[NSString class]] ? p[@"host"] : @"";
    NSString *port = [p[@"port"] isKindOfClass:[NSString class]] ? p[@"port"] : @"";
    NSString *user = [p[@"user"] isKindOfClass:[NSString class]] ? p[@"user"] : @"";
    NSString *pass = [p[@"pass"] isKindOfClass:[NSString class]] ? p[@"pass"] : @"";
    __weak typeof(self) weakSelf = self;

    // --- Hero (copy Blaze : "Stay Invisible") ------------------------------
    UIView *hero = [[UIView alloc] init];
    hero.backgroundColor = NWCardColor();
    hero.layer.cornerRadius = 18;
    hero.layer.borderWidth = 1;
    hero.layer.borderColor = [NWAccent() colorWithAlphaComponent:0.35].CGColor;

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
    UILabel *ptitle = NWLabelMake(@"Stay Invisible", 19, UIColor.whiteColor, UIFontWeightBold);
    UILabel *psub = NWLabelMake(@"Only compatible with HTTPS proxy, not SOCKS5 proxy! Currently under BETA, you might not receive any SMS code.",
                                11.5, NWDim(), UIFontWeightRegular);
    [v addArrangedSubview:ptitle];
    [v addArrangedSubview:psub];
    [self.content addArrangedSubview:hero];

    // --- Section "Proxy (BETA)" (switch copy Blaze) ------------------------
    [self addSection:@"Proxy (BETA)"];
    NWSwitchRow *sw = [[NWSwitchRow alloc] initWithIcon:@"shield.lefthalf.filled"
                                                   title:@"Enable"
                                               subtitle:[NSString stringWithFormat:@"Proxy for %@ container", cname]
                                                     on:on];
    [sw.heightAnchor constraintEqualToConstant:60].active = YES;
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
        NWUpdateProxyKey(@"auth", @(![p[@"auth"] boolValue]));
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
         "• Instagram 453.0 base cleaned (no RyukGram / FLEX)",
        12.5, [UIColor colorWithWhite:0.85 alpha:1], UIFontWeightRegular);
    [card addArrangedSubview:body];

    [self addSection:@"Version 1.0.0"];
    UIStackView *old = [self addPaddedCard];
    UILabel *o = NWLabelMake(@"• First release: containers, fingerprint, fake GPS, keychain vault.",
                             12.5, NWDim(), UIFontWeightRegular);
    [old addArrangedSubview:o];
}

- (void)buildSupport {
    __weak typeof(self) weakSelf = self;

    // --- Section "Support" (copy Blaze) ------------------------------------
    [self addSection:@"Support"];
    UIStackView *rows = [self addRowsCard];
    [self addRow:rows icon:@"paperplane.fill" title:@"Contact us on Telegram"
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

    UILabel *foot = NWLabelMake(@"Instagram modified · isolated containers · fake GPS · ghost fingerprint",
                                11, NWDim(), UIFontWeightRegular);
    foot.textAlignment = NSTextAlignmentCenter;
    [self.content addArrangedSubview:foot];
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

static void NWOpenMenu(void) {
    if (NWDashInstance) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NWInstallFloatingButton();
    NWDashboardViewController *d = [[NWDashboardViewController alloc] init];
    // Copy Blaze : le bouton flottant ouvre directement la liste Containers
    // (grille Dashboard accessible via le chevron en haut a gauche).
    d.module = @"containers";
    d.modalPresentationStyle = UIModalPresentationOverFullScreen;
    d.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    NWDashInstance = d;
    UIViewController *top = NWTopVC();
    if (top.presentedViewController) {
        NWDashInstance = nil;
        return;
    }
    [top presentViewController:d animated:YES completion:nil];
    NWLog("dashboard ouvert");
}

static void NWCloseMenu(void) {
    UIViewController *d = NWDashInstance;
    NWDashInstance = nil;
    [d dismissViewControllerAnimated:YES completion:nil];
}

static void NWTogglePanel(void) {
    if (NWDashInstance) NWCloseMenu();
    else NWOpenMenu();
}

// ---------------------------------------------------------------------------
// Hook proxy NSURLSession (best effort, Instagram utilise son propre reseau)
// ---------------------------------------------------------------------------

static id (*NWOrig_defaultSessionCfg)(id, SEL);
static id NWHook_defaultSessionCfg(id self, SEL _cmd) {
    id cfg = NWOrig_defaultSessionCfg(self, _cmd);
    NSDictionary *p = NWActiveProxy();
    if ([p[@"on"] boolValue] && [p[@"host"] length] && [p[@"port"] length]) {
        NSMutableDictionary *proxy = [NSMutableDictionary dictionary];
        proxy[@"HTTPSEnable"] = @YES;
        proxy[@"HTTPSProxy"] = p[@"host"];
        proxy[@"HTTPSPort"] = @([p[@"port"] integerValue]);
        proxy[@"HTTPEnable"] = @YES;
        proxy[@"HTTPProxy"] = p[@"host"];
        proxy[@"HTTPPort"] = @([p[@"port"] integerValue]);
        [cfg setConnectionProxyDictionary:proxy];
    }
    return cfg;
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

__attribute__((constructor))
static void NWInit(void) {
    @autoreleasepool {
        NWLog("demarrage — Instagram %@", UIDevice.currentDevice.systemVersion);

        // 1. Etat (disque ou vault keychain si re-install)
        NWBootstrapState();

        // 2. Hooks d'empreinte + fake GPS + GOT + proxy NSURLSession
        NWInstallFingerprintHooks();
        NWInstallLocationHooks();
        NWRebindGOT();
        NWSwizzle(object_getClass([NSURLSessionConfiguration class]),
                  @selector(defaultSessionConfiguration),
                  (IMP)NWHook_defaultSessionCfg, &NWOrig_defaultSessionCfg);

        // 3. Fenetre overlay + bouton flottant (persistant)
        NWInstallFloatingButton();

        // 4. Re-verification reguliere : si Instagram recree ses fenetres,
        //    l'overlay et le bouton sont remis en place automatiquement.
        static dispatch_source_t overlayTimer;
        dispatch_source_t ot = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
        dispatch_source_set_timer(ot, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2ull * NSEC_PER_SEC, 500ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(ot, ^{
            @autoreleasepool {
                NWEnsureOverlay();
                NWInstallFloatingButton();
            }
        });
        dispatch_resume(ot);
        overlayTimer = ot;

        // 5. Flush regulier : chaque 15 s, l'etat est persiste + vault.
        static dispatch_source_t flushTimer;
        dispatch_queue_t q = dispatch_queue_create("com.nine9wham.flush", DISPATCH_QUEUE_SERIAL);
        flushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(flushTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                                  15ull * NSEC_PER_SEC, 3ull * NSEC_PER_SEC);
        dispatch_source_set_event_handler(flushTimer, ^{
            @autoreleasepool {
                if (NWActiveID) { NWSnapshotActive(); NWPersistState(); }
            }
        });
        dispatch_resume(flushTimer);

        // 6. Sauvegarde avant mise en arriere-plan / fermeture
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { NWFlushOnExit(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { NWFlushOnExit(); }];

        NWLog("initialisation terminee — conteneur actif: %@", NWActiveID ?: @"(aucun)");
    }
}
