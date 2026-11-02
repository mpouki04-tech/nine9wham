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

#pragma mark - Empreinte device (fingerprint)

// Vrai modele reelle (utsname.machine ex: "iPhone14,2")
static NSString *NWRealMachine(void) {
    struct utsname u;
    if (uname(&u) != 0) return @"iPhone";
    return [NSString stringWithUTF8String:u.machine];
}

// Familles de modeles coherents avec la puce reelle.
// Chaque entree : machine prefix -> liste de modeles fictifs possibles.
// iPhone 11 (A13) -> iPhone 11 / 11 Pro / 11 Pro Max ; iPhone 12 (A14) -> 12 / 12 mini / 12 Pro...
static NSArray<NSString *> *NWCohortForMachine(NSString *machine) {
    NSDictionary *map = @{
        // A13
        @"iPhone12,1": @[@"iPhone12,1", @"iPhone12,3", @"iPhone12,5"],   // iPhone 11
        @"iPhone12,3": @[@"iPhone12,1", @"iPhone12,3", @"iPhone12,5"],
        @"iPhone12,5": @[@"iPhone12,1", @"iPhone12,3", @"iPhone12,5"],
        @"iPhone12,8": @[@"iPhone12,8"],                                  // SE 2e gen (seul A13 compact)
        // A14
        @"iPhone13,1": @[@"iPhone13,1", @"iPhone13,2", @"iPhone13,3", @"iPhone13,4"],
        @"iPhone13,2": @[@"iPhone13,1", @"iPhone13,2", @"iPhone13,3", @"iPhone13,4"],
        @"iPhone13,3": @[@"iPhone13,1", @"iPhone13,2", @"iPhone13,3", @"iPhone13,4"],
        @"iPhone13,4": @[@"iPhone13,1", @"iPhone13,2", @"iPhone13,3", @"iPhone13,4"],
        // A15
        @"iPhone14,2": @[@"iPhone14,2", @"iPhone14,3", @"iPhone14,4", @"iPhone14,5"],
        @"iPhone14,3": @[@"iPhone14,2", @"iPhone14,3", @"iPhone14,4", @"iPhone14,5"],
        @"iPhone14,4": @[@"iPhone14,2", @"iPhone14,3", @"iPhone14,4", @"iPhone14,5"],
        @"iPhone14,5": @[@"iPhone14,2", @"iPhone14,3", @"iPhone14,4", @"iPhone14,5"],
        @"iPhone14,6": @[@"iPhone14,6"],                                  // SE 3e gen
        // A15 (iPhone 14) / A16 (14 Pro)
        @"iPhone14,7": @[@"iPhone14,7", @"iPhone14,8", @"iPhone15,2", @"iPhone15,3"],
        @"iPhone14,8": @[@"iPhone14,7", @"iPhone14,8", @"iPhone15,2", @"iPhone15,3"],
        @"iPhone15,2": @[@"iPhone14,7", @"iPhone14,8", @"iPhone15,2", @"iPhone15,3"],
        @"iPhone15,3": @[@"iPhone14,7", @"iPhone14,8", @"iPhone15,2", @"iPhone15,3"],
        // A16
        @"iPhone15,4": @[@"iPhone15,4", @"iPhone15,5"],
        @"iPhone15,5": @[@"iPhone15,4", @"iPhone15,5"],
        // A17 Pro
        @"iPhone16,1": @[@"iPhone16,1", @"iPhone16,2"],
        @"iPhone16,2": @[@"iPhone16,1", @"iPhone16,2"],
        // A18
        @"iPhone17,3": @[@"iPhone17,3", @"iPhone17,4", @"iPhone17,1", @"iPhone17,2", @"iPhone17,5"],
        @"iPhone17,4": @[@"iPhone17,3", @"iPhone17,4", @"iPhone17,1", @"iPhone17,2", @"iPhone17,5"],
        @"iPhone17,1": @[@"iPhone17,3", @"iPhone17,4", @"iPhone17,1", @"iPhone17,2", @"iPhone17,5"],
        @"iPhone17,2": @[@"iPhone17,3", @"iPhone17,4", @"iPhone17,1", @"iPhone17,2", @"iPhone17,5"],
        @"iPhone17,5": @[@"iPhone17,3", @"iPhone17,4", @"iPhone17,1", @"iPhone17,2", @"iPhone17,5"],
    };
    NSArray *c = map[machine];
    if (c) return c;
    // Modèle inconnu (iPhone plus récent) -> cohorte par défaut : même série
    return @[machine];
}

// Memoire (GB) et cœurs coherents avec un modele
static NSUInteger NWMemGBForMachine(NSString *m) {
    if ([m hasPrefix:@"iPhone12"]) return 4;              // iPhone 11 / SE2
    if ([m hasPrefix:@"iPhone13"]) return 4;              // iPhone 12
    if ([m hasPrefix:@"iPhone14,2"] || [m hasPrefix:@"iPhone14,3"] ||
        [m hasPrefix:@"iPhone14,4"] || [m hasPrefix:@"iPhone14,5"] ||
        [m hasPrefix:@"iPhone14,6"]) return 4;            // iPhone 13 / SE3
    if ([m hasPrefix:@"iPhone14"]) return 6;              // iPhone 14
    if ([m hasPrefix:@"iPhone15"]) return 6;              // iPhone 14 Pro / 15
    if ([m hasPrefix:@"iPhone16"]) return 8;              // iPhone 15 Pro
    return 6;                                             // iPhone 16+
}

static NSUInteger NWCpuCountForMachine(NSString *m) {
    // Tous les SoC Apple modernes : 6 cœurs (2P+4E), sauf A17/A18 Pro = 6 aussi.
    // On reste volontairement simple et stable : 6.
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

    // Version iOS reelle conservee (coherence systeme) ; kernel reel conserve aussi.
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
    NSNumber *gb = NWActiveFP[@"memGB"];
    if ([gb isKindOfClass:[NSNumber class]] && gb.unsignedLongLongValue > 0) {
        return gb.unsignedLongLongValue * 1024ULL * 1024ULL * 1024ULL;
    }
    return NWOrig_physMem(self, _cmd);
}

static NSUInteger (*NWOrig_cpuCount)(id, SEL);
static NSUInteger NWHook_cpuCount(id self, SEL _cmd) {
    NSNumber *c = NWActiveFP[@"cpu"];
    if ([c isKindOfClass:[NSNumber class]] && c.unsignedIntegerValue > 0) {
        return c.unsignedIntegerValue;
    }
    return NWOrig_cpuCount ? NWOrig_cpuCount(self, _cmd) : 6;
}

static NSUInteger (*NWOrig_activeCpuCount)(id, SEL);
static NSUInteger NWHook_activeCpuCount(id self, SEL _cmd) {
    NSNumber *c = NWActiveFP[@"cpu"];
    if ([c isKindOfClass:[NSNumber class]] && c.unsignedIntegerValue > 0) {
        return c.unsignedIntegerValue;
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
                // ecriture : la section peut etre en lecture seule -> vm_protect
                mach_vm_address_t page = (mach_vm_address_t)((uintptr_t)&slots[i] & ~(uintptr_t)0xFFF);
                vm_protect(mach_task_self(), page, 0x1000, false,
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

static void (*NWOrig_startUpdating)(id, SEL);
static void NWHook_startUpdating(id self, SEL _cmd) {
    NWOrig_startUpdating(self, _cmd);
    if (NWFakeLocation()) {
        // Delegation asynchrone : le delegate attend la premiere position.
        CLLocationManager *mgr = (CLLocationManager *)self;
        dispatch_async(dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
    }
}

static void (*NWOrig_requestLocation)(id, SEL);
static void NWHook_requestLocation(id self, SEL _cmd) {
    NWOrig_requestLocation(self, _cmd);
    if (NWFakeLocation()) {
        CLLocationManager *mgr = (CLLocationManager *)self;
        dispatch_async(dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
    }
}

static void (*NWOrig_startSignificant)(id, SEL);
static void NWHook_startSignificant(id self, SEL _cmd) {
    NWOrig_startSignificant(self, _cmd);
    if (NWFakeLocation()) {
        CLLocationManager *mgr = (CLLocationManager *)self;
        dispatch_async(dispatch_get_main_queue(), ^{ NWDeliverFake(mgr); });
    }
}

// Les erreurs "localisation indisponible" sont ignorees quand le fake est actif :
// on empeche Instagram de croire que le GPS est en panne.
// Le delegate est connu seulement a setDelegate: -> on swizzle sa classe la.
static NSMutableDictionary *NWFailMap(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

static void NWHook_fail(id self, SEL _cmd, id mgr, id error) {
    if (NWFakeLocation()) return;
    id v = [NWFailMap() objectForKey:NSStringFromClass(object_getClass(self))];
    IMP orig = ([v isKindOfClass:[NSValue class]]) ? [v pointerValue] : NULL;
    if (orig && orig != (IMP)NWHook_fail) ((void (*)(id, SEL, id, id))orig)(self, _cmd, mgr, error);
}

static void NWHookDelegateClass(Class cls) {
    if (!cls || cls == [NSObject class]) return;
    NSString *key = NSStringFromClass(cls);
    @synchronized (NWFailMap()) {
        if ([NWFailMap() objectForKey:key]) return;
        SEL sel = @selector(locationManager:didFailWithError:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { [NWFailMap() setObject:[NSNull null] forKey:key]; return; }
        IMP cur = class_getMethodImplementation(cls, sel);
        if (cur == (IMP)NWHook_fail) {   // deja hooke (super) : pas de recursion
            [NWFailMap() setObject:[NSNull null] forKey:key];
            return;
        }
        const char *types = method_getTypeEncoding(m);
        IMP old = class_replaceMethod(cls, sel, (IMP)NWHook_fail, types);
        if (!old) old = cur;   // venait du super -> l'IMP super reste l'original
        [NWFailMap() setObject:[NSValue valueWithPointer:old] forKey:key];
        NWLog("delegate hook: %@", key);
    }
}

static void (*NWOrig_setDelegate)(id, SEL, id);
static void NWHook_setDelegate(id self, SEL _cmd, id delegate) {
    NWOrig_setDelegate(self, _cmd, delegate);
    if (delegate) NWHookDelegateClass(object_getClass(delegate));
}

static void NWInstallLocationHooks(void) {
    Class mgrCls = [CLLocationManager class];
    NWSwizzle(mgrCls, @selector(location), (IMP)NWHook_location, &NWOrig_location);
    NWSwizzle(mgrCls, @selector(startUpdatingLocation), (IMP)NWHook_startUpdating, &NWOrig_startUpdating);
    NWSwizzle(mgrCls, @selector(requestLocation), (IMP)NWHook_requestLocation, &NWOrig_requestLocation);
    NWSwizzle(mgrCls, @selector(startMonitoringSignificantLocationChanges), (IMP)NWHook_startSignificant, &NWOrig_startSignificant);
    // Le delegate n'est connu qu'a setDelegate: -> on swizzle sa classe a ce moment-la
    // (plutot que NSObject qui n'implante pas la methode).
    NWSwizzle(mgrCls, @selector(setDelegate:), (IMP)NWHook_setDelegate, &NWOrig_setDelegate);
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
static NSString *NWCreateContainer(NSString *name) {
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

    containers[cid] = @{
        @"name": name.length ? name : [NSString stringWithFormat:@"Télo %lu", (unsigned long)containers.count + 1],
        @"createdAt": @([[NSDate date] timeIntervalSince1970]),
        @"fp": fp,
        @"loc": @{@"on": @NO, @"lat": @0, @"lon": @0, @"label": @""},
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
        NSString *cid = NWCreateContainer(@"Mon iPhone");
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

#pragma mark - Menu flottant @nine9wham

static UIButton *NWMenuButton = nil;
static UIView   *NWPanel = nil;
static BOOL      NWPanelOpen = NO;

// Met a jour l'etat d'un conteneur (champ loc notamment) et persiste.
static void NWUpdateContainerField(NSString *cid, NSString *key, id value) {
    NSDictionary *st = NWState ?: @{};
    NSMutableDictionary *containers = [st[@"containers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *c = [containers[cid] mutableCopy];
    if (!c) return;
    c[key] = value;
    containers[cid] = c;
    NSMutableDictionary *newSt = [st mutableCopy];
    newSt[@"containers"] = containers;
    NWSaveState(newSt);
    NWPersistState();
}

static void NWReloadAfterStateChange(void) {
    // Recharge l'etat et re-applique hooks variables (empreinte / localisation).
    NSDictionary *st = NWLoadState();
    if (st[@"containers"]) NWSaveState(st);
}

// --- Alertes utilitaires -------------------------------------------------

static UIViewController *NWTopVC(void);   // declaration anticipee

static void NWAlert(NSString *title, NSString *msg) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [NWTopVC() presentViewController:a animated:YES completion:nil];
}

// Vue controller racine (presente les alertes / sheets).
static UIViewController *NWTopVC(void) {
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
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Relance requise pour que Instagram recharge prefs/cookies/empreinte.
static void NWAskRelaunch(NSString *raison) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Relance nécessaire"
        message:[NSString stringWithFormat:@"%@ Instagram pour appliquer ce changement.", raison]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Relancer" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        exit(0);   // iOS redemarre l'app ; les prefs/cookies/empreinte sont deja restaures
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Plus tard" style:UIAlertActionStyleCancel handler:nil]];
    [NWTopVC() presentViewController:a animated:YES completion:nil];
}

// --- Panneau ---------------------------------------------------------------

static void NWRebuildPanel(void);

// Cle associee aux boutons (porteur du cid)
static char NWCIDKey;

// Receveur des actions du panneau (ObjC requis pour addTarget:)
@interface NWMenuActions : NSObject
+ (instancetype)shared;
- (void)close;
- (void)add;
- (void)use:(UIButton *)sender;
- (void)gps:(UIButton *)sender;
- (void)del:(UIButton *)sender;
- (void)gpsPickLocation:(NSString *)cid;
- (void)gpsManual:(NSString *)cid;
@end

static void NWTogglePanel(void) {
    NWPanelOpen = !NWPanelOpen;
    if (NWPanelOpen) {
        if (!NWPanel) {
            NWPanel = [[UIView alloc] initWithFrame:CGRectMake(12, 90, 300, 420)];
            NWPanel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
            NWPanel.layer.cornerRadius = 16;
            NWPanel.layer.borderWidth = 1;
            NWPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
            NWPanel.clipsToBounds = YES;
        }
        NWRebuildPanel();
        if (!NWPanel.superview) [NWTopVC().view addSubview:NWPanel];
        NWPanel.hidden = NO;
        NWPanel.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ NWPanel.alpha = 1; }];
    } else {
        [UIView animateWithDuration:0.15 animations:^{ NWPanel.alpha = 0; }
                         completion:^(BOOL fin){ NWPanel.hidden = YES; }];
    }
}

static UILabel *NWLabel(NSString *text, CGFloat size, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text; l.font = [UIFont boldSystemFontOfSize:size]; l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

// Construit (ou reconstruit) le contenu du panneau.
static void NWRebuildPanel(void) {
    for (UIView *v in [NWPanel.subviews copy]) [v removeFromSuperview];

    NSDictionary *st = NWLoadState();
    if (st[@"containers"]) NWSaveState(st);
    NSDictionary *containers = NWState[@"containers"] ?: @{};

    CGFloat y = 10;
    UILabel *title = NWLabel(@"@nine9wham", 17, [UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:1]);
    title.frame = CGRectMake(14, y, 200, 24);
    [NWPanel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(258, y - 2, 34, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.tintColor = [UIColor whiteColor];
    [close addTarget:[NWMenuActions shared] action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [NWPanel addSubview:close];
    y += 30;

    UILabel *sub = NWLabel(@"Conteneurs = téléphones virtuels isolés", 11, [UIColor colorWithWhite:0.7 alpha:1]);
    sub.frame = CGRectMake(14, y, 276, 16);
    [NWPanel addSubview:sub];
    y += 22;

    // Liste des conteneurs
    NSArray *ids = [containers.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *cid in ids) {
        NSDictionary *c = containers[cid];
        BOOL active = [cid isEqualToString:NWActiveID];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, y, 280, 44)];
        row.backgroundColor = active ? [UIColor colorWithWhite:1 alpha:0.12] : [UIColor colorWithWhite:1 alpha:0.05];
        row.layer.cornerRadius = 10;
        [NWPanel addSubview:row];

        NSString *model = c[@"fp"][@"model"] ?: @"?";
        UILabel *n = NWLabel([NSString stringWithFormat:@"%@  ·  %@", c[@"name"] ?: cid, model], 13,
                             active ? [UIColor colorWithRed:0.55 green:0.85 blue:0.6 alpha:1] : UIColor.whiteColor);
        n.frame = CGRectMake(10, 4, 200, 18);
        [row addSubview:n];

        NSString *locTxt = @"GPS off";
        NSDictionary *loc = c[@"loc"];
        if ([loc[@"on"] boolValue]) {
            locTxt = [NSString stringWithFormat:@"GPS %.3f, %.3f", [loc[@"lat"] doubleValue], [loc[@"lon"] doubleValue]];
        }
        UILabel *d = NWLabel([NSString stringWithFormat:@"%@%@", active ? @"● actif · " : @"", locTxt], 10,
                             [UIColor colorWithWhite:0.65 alpha:1]);
        d.frame = CGRectMake(10, 23, 200, 14);
        [row addSubview:d];

        // Bouton "utiliser"
        if (!active) {
            UIButton *use = [UIButton buttonWithType:UIButtonTypeSystem];
            use.frame = CGRectMake(210, 8, 62, 28);
            [use setTitle:@"Utiliser" forState:UIControlStateNormal];
            use.titleLabel.font = [UIFont boldSystemFontOfSize:12];
            use.tintColor = [UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:1];
            [use addTarget:[NWMenuActions shared] action:@selector(use:) forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(use, &NWCIDKey, cid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [row addSubview:use];
        }

        // Bouton localisation
        UIButton *gps = [UIButton buttonWithType:UIButtonTypeSystem];
        gps.frame = CGRectMake(active ? 210 : 148, 8, active ? 62 : 58, 28);
        [gps setTitle:@"📍" forState:UIControlStateNormal];
        gps.titleLabel.font = [UIFont systemFontOfSize:15];
        objc_setAssociatedObject(gps, &NWCIDKey, cid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gps addTarget:[NWMenuActions shared] action:@selector(gps:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:gps];

        // Bouton supprimer
        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.frame = CGRectMake(active ? 148 : 210, 8, 58, 28);
        [del setTitle:@"🗑" forState:UIControlStateNormal];
        del.tintColor = [UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1];
        objc_setAssociatedObject(del, &NWCIDKey, cid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [del addTarget:[NWMenuActions shared] action:@selector(del:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:del];

        y += 50;
    }

    y += 4;
    // Nouveau conteneur
    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(10, y, 280, 36);
    add.backgroundColor = [UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:0.18];
    add.layer.cornerRadius = 10;
    [add setTitle:@"＋ Nouveau conteneur" forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    add.tintColor = [UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:1];
    [add addTarget:[NWMenuActions shared] action:@selector(add) forControlEvents:UIControlEventTouchUpInside];
    [NWPanel addSubview:add];
    y += 42;

    // Bascule fake GPS du conteneur actif
    NSDictionary *actLoc = NWActiveLoc;
    UIButton *gpsToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    gpsToggle.frame = CGRectMake(10, y, 280, 34);
    gpsToggle.backgroundColor = [actLoc[@"on"] boolValue] ? [UIColor colorWithRed:0.3 green:0.75 blue:0.4 alpha:0.25]
                                                          : [UIColor colorWithWhite:1 alpha:0.07];
    gpsToggle.layer.cornerRadius = 10;
    [gpsToggle setTitle:[actLoc[@"on"] boolValue] ? @"📍 Fake GPS : ON (conteneur actif)" : @"📍 Fake GPS : OFF"
               forState:UIControlStateNormal];
    gpsToggle.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    gpsToggle.tintColor = UIColor.whiteColor;
    objc_setAssociatedObject(gpsToggle, &NWCIDKey, NWActiveID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gpsToggle addTarget:[NWMenuActions shared] action:@selector(gps:) forControlEvents:UIControlEventTouchUpInside];
    [NWPanel addSubview:gpsToggle];
    y += 40;

    NWPanel.frame = CGRectMake(NWPanel.frame.origin.x, NWPanel.frame.origin.y, 300, y + 10);
}

#pragma mark - Actions du menu

@implementation NWMenuActions

+ (instancetype)shared {
    static NWMenuActions *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NWMenuActions new]; });
    return s;
}

- (void)close { NWTogglePanel(); }

- (void)add {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nouveau conteneur"
                                                              message:@"Chaque conteneur = un téléphone virtuel isolé (compte, empreinte, localisation)."
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Nom (ex: Télo 2)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Créer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *name = a.textFields.firstObject.text;
        NSString *cid = NWCreateContainer(name);
        NWRebuildPanel();
        NWAskRelaunch(@"Instagram va redémarrer pour activer le nouveau");
        (void)cid;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [NWTopVC() presentViewController:a animated:YES completion:nil];
}

- (void)use:(UIButton *)sender {
    NSString *cid = objc_getAssociatedObject(sender, &NWCIDKey);
    if (!cid) return;
    NWSwitchContainer(cid);
    NWRebuildPanel();
    NWAskRelaunch(@"Le conteneur sélectionné");
}

- (void)del:(UIButton *)sender {
    NSString *cid = objc_getAssociatedObject(sender, &NWCIDKey);
    if (!cid) return;
    NSDictionary *c = (NWState[@"containers"])[cid];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Supprimer « %@ » ?", c[@"name"] ?: cid]
        message:@"Compte, cookies et empreinte de ce conteneur seront effacés."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Supprimer" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        NWDeleteContainer(cid);
        NWRebuildPanel();
        if ([cid isEqualToString:NWActiveID]) NWAskRelaunch(@"Instagram va redémarrer");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [NWTopVC() presentViewController:a animated:YES completion:nil];
}

// Localisation : presets + coordonnees manuelles, pour le conteneur cid.
- (void)gps:(UIButton *)sender {
    NSString *cid = objc_getAssociatedObject(sender, &NWCIDKey) ?: NWActiveID;
    if (!cid) return;
    NSDictionary *c = (NWState[@"containers"])[cid];
    NSDictionary *loc = c[@"loc"] ?: @{@"on": @NO};

    if ([loc[@"on"] boolValue]) {
        // deja actif -> proposer d'eteindre
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"Fake GPS"
            message:[NSString stringWithFormat:@"Actif : %.4f, %.4f", [loc[@"lat"] doubleValue], [loc[@"lon"] doubleValue]]
            preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"Désactiver le fake GPS" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
            NWUpdateContainerField(cid, @"loc", @{@"on": @NO, @"lat": loc[@"lat"] ?: @0, @"lon": loc[@"lon"] ?: @0, @"label": loc[@"label"] ?: @""});
            NWReloadAfterStateChange();
            NWRebuildPanel();
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Choisir un autre endroit" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            [self gpsPickLocation:cid];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
        [NWTopVC() presentViewController:a animated:YES completion:nil];
        return;
    }
    [self gpsPickLocation:cid];
}

- (void)gpsPickLocation:(NSString *)cid {
    NSArray *cities = @[
        @[@"Paris, France", @48.8566, @2.3522],
        @[@"Londres, Royaume-Uni", @51.5074, @-0.1278],
        @[@"New York, USA", @40.7128, @-74.0060],
        @[@"Tokyo, Japon", @35.6762, @139.6503],
        @[@"Dubaï, EAU", @25.2048, @55.2708],
        @[@"Abidjan, Côte d'Ivoire", @5.3600, @-4.0083],
        @[@"Kinshasa, RDC", @-4.4419, @15.2663],
        @[@"Dakar, Sénégal", @14.7167, @-17.4677],
        @[@"Casablanca, Maroc", @33.5731, @-7.5898],
        @[@"Montréal, Canada", @45.5019, @-73.5674],
        @[@"Brésil, São Paulo", @-23.5505, @-46.6333],
        @[@"Berlin, Allemagne", @52.5200, @13.4050],
    ];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Localisation du conteneur"
                                                                  message:@"Choisissez un endroit dans le monde entier"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *city in cities) {
        [sheet addAction:[UIAlertAction actionWithTitle:city[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            NWUpdateContainerField(cid, @"loc", @{@"on": @YES, @"lat": city[1], @"lon": city[2], @"label": city[0]});
            NWReloadAfterStateChange();
            NWRebuildPanel();
            NWAskRelaunch(@"Instagram doit redémarrer pour appliquer");
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Coordonnées manuelles…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        [self gpsManual:cid];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *vc = NWTopVC();
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) { pop.sourceView = vc.view; pop.sourceRect = CGRectMake(vc.view.bounds.size.width/2, vc.view.bounds.size.height/2, 1, 1); }
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)gpsManual:(NSString *)cid {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Coordonnées GPS"
                                                              message:@"Latitude / longitude au format décimal (ex: 48.8566 / 2.3522)"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Latitude"; tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Longitude"; tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Appliquer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        double lat = a.textFields[0].text.doubleValue;
        double lon = a.textFields[1].text.doubleValue;
        if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
            NWAlert(@"Coordonnées invalides", @"Latitude entre -90 et 90, longitude entre -180 et 180.");
            return;
        }
        NWUpdateContainerField(cid, @"loc", @{@"on": @YES, @"lat": @(lat), @"lon": @(lon),
                                              @"label": [NSString stringWithFormat:@"%.4f, %.4f", lat, lon]});
        NWReloadAfterStateChange();
        NWRebuildPanel();
        NWAskRelaunch(@"Instagram doit redémarrer pour appliquer");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [NWTopVC() presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - Bouton flottant (draggable, style Blaze)

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
        NWTogglePanel();   // simple tap = ouvrir/fermer le menu
    } else {
        // aimantation aux bords + sauvegarde de la position
        UIView *v = self.superview;
        CGRect f = self.frame;
        CGFloat mid = v.bounds.size.width / 2;
        f.origin.x = (self.center.x < mid) ? 8 : v.bounds.size.width - f.size.width - 8;
        f.origin.y = MIN(MAX(f.origin.y, 60), v.bounds.size.height - f.size.height - 30);
        [UIView animateWithDuration:0.15 animations:^{ self.frame = f; }];
        NSDictionary *st = NWState ?: @{};
        NSMutableDictionary *ui = [st[@"ui"] mutableCopy] ?: [NSMutableDictionary dictionary];
        ui[@"x"] = @(f.origin.x); ui[@"y"] = @(f.origin.y);
        NSMutableDictionary *newSt = [st mutableCopy] ?: [NSMutableDictionary dictionary];
        newSt[@"ui"] = ui;
        NWSaveState(newSt);
        NWPersistState();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.dragging = NO;
}

@end

static void NWInstallFloatingButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // On attend d'avoir une fenetre racine.
        UIWindow *key = NWTopVC().view.window;
        if (!key) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ NWInstallFloatingButton(); });
            return;
        }
        if (NWMenuButton && NWMenuButton.superview) return;

        CGPoint pos = CGPointMake(key.bounds.size.width - 56, key.bounds.size.height * 0.42);
        NSDictionary *ui = (NWState ?: @{})[@"ui"];
        if ([ui[@"x"] isKindOfClass:[NSNumber class]]) {
            pos = CGPointMake(ui[@"x"].doubleValue, ui[@"y"].doubleValue);
        }

        NWMenuButton = [NWFloatingButton buttonWithType:UIButtonTypeCustom];
        NWMenuButton.frame = CGRectMake(pos.x, pos.y, 46, 46);
        NWMenuButton.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.92];
        NWMenuButton.layer.cornerRadius = 23;
        NWMenuButton.layer.borderWidth = 1.5;
        NWMenuButton.layer.borderColor = [UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:0.9].CGColor;
        NWMenuButton.layer.shadowColor = UIColor.blackColor.CGColor;
        NWMenuButton.layer.shadowOpacity = 0.4;
        NWMenuButton.layer.shadowRadius = 4;
        NWMenuButton.layer.shadowOffset = CGSizeMake(0, 2);
        NWMenuButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [NWMenuButton setTitle:@"9⃣9⃣" forState:UIControlStateNormal];
        NWMenuButton.tintColor = [UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:1];
        [NWMenuButton setTitleColor:[UIColor colorWithRed:0.55 green:0.75 blue:1 alpha:1] forState:UIControlStateNormal];
        NWMenuButton.accessibilityLabel = @"Menu nine9wham";
        [key addSubview:NWMenuButton];
        NWLog("bouton flottant installe");
    });
}

#pragma mark - Bootstrap

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

        // 2. Hooks d'empreinte + fake GPS + GOT (toujours installes : ils
        //    suivent l'etat du conteneur actif, actif ou non).
        NWInstallFingerprintHooks();
        NWInstallLocationHooks();
        NWRebindGOT();

        // 3. Bouton flottant (une fois la fenetre prete)
        NWInstallFloatingButton();

        // 4. Flush regulier : chaque 15 s, l'etat est persiste + vault.
        static dispatch_source_t flushTimer;   // retenu par la duree de vie du process
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

        // 5. Notification de fin de session (sauvegarde avant exit)
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { NWFlushOnExit(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { NWFlushOnExit(); }];

        NWLog("initialisation terminee — conteneur actif: %@", NWActiveID ?: @"(aucun)");
    }
}
