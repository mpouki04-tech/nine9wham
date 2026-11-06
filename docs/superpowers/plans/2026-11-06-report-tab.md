# Onglet Rapport (journal persistant complet) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un onglet « Report » qui journalise chaque ligne (logs nine9wham + logs NSLog d'Instagram + crashs) sur disque en écriture immédiate, pour copier-coller l'intégralité du rapport même après un plantage.

**Architecture:** Un seul fichier `tweak/Peter.m`. Nouvelle section « rapport persistant » (fd `O_APPEND` ouvert en permanence, `write()` direct, rotation 2 Mo) insérée après `NWDocumentsDir` ; `NWLog` réécrit en fonction ; `NSLog`/`NSLogv` capturés via le fishhook maison existant (`NWRbTargets`, tableau 8 → 10) ; handlers de crash en append ; module UI `report` branché sur la navigation existante du dashboard.

**Tech Stack:** Objective-C (dylib iOS arm64, `-fobjc-arc`), UIKit, fishhook maison, aucun dépôt externe.

**Spec:** `docs/superpowers/specs/2026-11-06-report-tab-design.md` (design approuvé — le plan argue de ce document)

## Global Constraints

- UI en anglais ; toute chaîne visible via `NWL(key, en, fr, es)` (FR/ES fournis).
- Design Blaze : couleurs `NWBg/NWCardGlass/NWAccent/NWDim/NWLine`, helpers `addSection`/`addRowsCard`/`addRow`/`NWGridCell`/`NWBind`/`NWAlert`/`NWTopVC`.
- CI = **13 warnings identiques** (mêmes types, les numéros de ligne peuvent bouger) : unused `hash`, warn_unused_result ×2, unused `iv`, unused function `NWPill`, `contentEdgeInsets`, `keyWindow`, `windows`, `imageEdgeInsets`, unused `model`, unused `ios`, retain cycle, `overlayTimer` set-but-not-used. **Aucun nouveau** `keyWindow`/`windows`, aucune variable inutilisée.
- `Peter.m` : CRLF sans BOM, **jamais** réécrit via PowerShell `Get-Content -Raw` (mojibake) — uniquement `edit`/`write`.
- `NWBuildID` → `w10-6` (déplacé en tête de fichier, utilisable par le header du rapport).
- Chemins exacts : rapport `Documents/nine9wham_report.txt`, crash `Documents/nine9wham_crash.log` (`NWCrashLogPath()`).
- Aucun upload réseau du rapport ; pas de `os_log` (hors périmètre).
- Python : `"$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"` + `$env:PYTHONIOENCODING='utf-8'`.
- Push : `git -C "D:\OPENCODE\IPA INSTA WHAM\nine9wham" -c credential.helper= -c http.extraheader="AUTHORIZATION: basic <base64 du PAT de session>" push origin main` (stderr `NativeCommandError` = normal ; vérifier `… -> main`).
- CI : `$env:GH_TOKEN='<PAT session>'` puis `gh run watch <id> -R mpouki04-tech/nine9wham --exit-status --interval 30`.
- Invariants intacts : `exit(0)` (délai 1,5 s), crash reporter ré-affirmé toutes les 2 s, pas de FLEX/licence, langs ghost.

## Review Focus

1. **Les dernières lignes avant le crash doivent être sur disque** (le plantage arrive à l'entrée du nom) — pin : Task 1 n'utilise que `write()` (aucun `fwrite`/`freopen`/buffer stdio) ; vérification grep + lecture immédiate du fichier après écriture.
2. **Récursion du hook `NSLog`** (notre append déclenchant un log → boucle → crash au lancement) — pin : Task 2 exige la garde `__thread NWInReportHook` avec court-circuit vers l'original ; détection = CI verte + lancement utilisateur (un crash immédiat = régression).
3. **Nouveaux warnings CI** dus à `NS_FORMAT_FUNCTION` ou variables inutilisées — pin : la dernière étape de chaque task (1-4) extrait les `warning:` du log CI et compare les 13 types ; tout écart = régression avant de continuer.
4. **Share sur iPad** (`UIActivityViewController` sans `sourceView` = crash) — pin : Task 4 pose `popoverPresentationController.sourceView` **hors de tout bloc** (pattern existant ~l.6894).
5. **Aperçu UTF-8 tronqué** (seek au milieu d'un caractère → texte illisible) — pin : `NWReportPreview()` (Task 1) supprime la première ligne partielle après seek ; vérification : l'aperçu commence par un timestamp complet `HH:MM:SS.mmm`.

---

### Task 1: Moteur de rapport persistant + `NWLog` réécrit

**Files:**
- Modify: `tweak/Peter.m:45` (macro `NWLog`), `tweak/Peter.m:1361-1366` (insertion après `NWDocumentsDir`), `tweak/Peter.m` (~zone flush timer 15 s), `tweak/Peter.m` (`#define NWBuildID` ~l.8558 → déplacé en tête)

**Interfaces:**
- Consumes: `NWDocumentsDir()` (l.1361), `NWBuildID` (déplacé), flush timer existant.
- Produits (utilisés par les tasks 2-4) :
  - `static NSString *NWReportPath(void)` → `Documents/nine9wham_report.txt`
  - `static int NWReportFD` (fd permanent, -1 = pas encore ouvert)
  - `static char NWReportPathC[1024]` (chemin C pour le handler signal)
  - `static void NWReportOpen(void)` (lazy, idempotent — append « session start »)
  - `static void NWReportAppendLine(const char *tag, NSString *msg)` (horodatage `HH:MM:SS.mmm [TAG] msg\n`, lock + `write()` direct)
  - `static void NWReportMaybeRotate(void)` (>2 Mo → garde le Mo final)
  - `static void NWLogImpl(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2)` (append `[NW]` puis `NSLog` console)
  - Ruling Task 1 : `NWReportAppendRaw` (→ Task 3), `NWReportClear`/`NWReportPreview`/`NWReportFullText` (→ Task 4) sont définies par LEUR task de consommation — définies en Task 1 elles produisaient 4 warnings `unused function` en CI intermédiaire (17 au lieu de 13 ; l'invariant exige 13 à chaque CI).

- [ ] **Step 1: Déplacer `NWBuildID` en tête de fichier et le passer à `w10-6`**

Couper la ligne `#define NWBuildID @"w10-5"` (avec son commentaire « Change a chaque build publie ») de sa position (~l.8558) et la replacer après le bloc `NWDevKey*` (~l.55), valeur `@"w10-6"`. Aucun usage avant l'ancien emplacement (sinon ça ne compilerait pas).

- [ ] **Step 2: Forward declaration + nouvelle macro `NWLog` (l.45)**

Remplacer la l.45 par :

```objc
static void NWLogImpl(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
#define NWLog(fmt, ...) NWLogImpl(@"[nine9wham] " fmt, ##__VA_ARGS__)
```

(Le concat littéral impose un format literal à chaque appel — déjà le cas aujourd'hui ; aucun warning ne peut apparaître ou disparaître ici.)

- [ ] **Step 3: Insérer la section « Rapport persistant » entre `NWDocumentsDir` (fin l.1366) et le commentaire `#pragma mark - Rapporteur de crash` (l.1371)**

Contenu (décisions fixées par le spec) :
- `NWReportPath()`, `NWReportFD = -1`, `NWReportPathC[1024]`, `NWInReportHook` (`static __thread BOOL`), `static pthread_mutex_t NWReportLock = PTHREAD_MUTEX_INITIALIZER`.
- `NWReportOpen()` : si `NWReportFD >= 0` return ; `open(path, O_WRONLY|O_APPEND|O_CREAT, 0644)` ; si OK → `strncpy(NWReportPathC, …)` puis append d'une ligne `=== session <date> (build <NWBuildID>) ===` (si `open` échoue, FD reste -1 : tout reste silencieux mais `NSLog` console continue).
- `NWReportAppendLine(tag, msg)` : si `NWReportFD < 0` → `NWReportOpen()` ; lock ; header `[localtime %H:%M:%S].%03u [tag] ` (3 `write()` : header, bytes UTF-8 du message, `\n`) ; unlock. **Jamais de `fwrite`/buffer stdio.**
- `NWReportAppendRaw(text)` : même protocole lock + 1 `write()` des bytes UTF-8.
- `NWReportMaybeRotate()` : taille > 2 000 000 → lire les 1 000 000 derniers octets (`open`/`lseek`/`read` C pur, pas de NSFileHandle), `ftruncate(NWReportFD,0)`, réécrire la queue (fd en `O_APPEND` repart à 0) précédée de `--- rotated ---\n`.
- Corps de `NWLogImpl(fmt, …)` : `va_list` → `initWithFormat:arguments:` → `NWReportAppendLine("NW", s)` → `NSLog(@"%@", s)` (console inchangée).
- (Les helpers `NWReportAppendRaw`/`Clear`/`Preview`/`FullText` sont ajoutées plus tard par les Tasks 3 et 4 — voir ruling en Interfaces.)

- [ ] **Step 4: Remplacer tout `NSLog(` direct restant dans `Peter.m` par `NWLog(`**

Run: `Select-String -Pattern 'NSLog\(' tweak/Peter.m`
Expected : seules les 2 lignes légitimes restent — la macro (l.45) et le corps de `NWLogImpl`. Tout autre occurrence → remplacer par `NWLog(...)` (le rebind d'Instagram ne capture pas notre image : nos logs doivent passer par `NWLogImpl`).

- [ ] **Step 5: Rotation dans le flush 15 s**

Dans le handler `dispatch_source_set_event_handler(flushTimer, …)` (~l.8775) : ajouter `@try { NWReportMaybeRotate(); } @catch (NSException *e) { (void)e; }` à côté de `NWSnapshotActive(); NWPersistState();`.

- [ ] **Step 6: Vérifications locales**

Run:
```powershell
$env:PYTHONIOENCODING='utf-8'; & "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" "C:\Users\ARMEL\AppData\Local\Temp\opencode\check_syntax.py" "D:\OPENCODE\IPA INSTA WHAM\nine9wham\tweak\Peter.m"
Select-String -Pattern 'fwrite|freopen|fputs' tweak/Peter.m
```
Expected : `remaining open: 0` ; **0 occurrence** de fwrite/freopen/fputs.
Puis contrôle CRLF/BOM (commande de la session : `ReadAllBytes` → BOM=False, LF-seul=0).

- [ ] **Step 7: Commit + push + CI (validation compile tôt)**

```powershell
git -C "D:\OPENCODE\IPA INSTA WHAM\nine9wham" add tweak/Peter.m
git -C "D:\OPENCODE\IPA INSTA WHAM\nine9wham" commit -m "w10-6: moteur de rapport persistant (fd O_APPEND, rotation 2 Mo) + NWLog ecrit sur disque"
# push (commande Global Constraints) puis :
$env:GH_TOKEN='ghp_…'; gh run watch <id> -R mpouki04-tech/nine9wham --exit-status --interval 30
```
Expected : CI SUCCESS ; extraction des `warning:` = **13 types identiques** (aucun nouveau).

---

### Task 2: Rebind `NSLog`/`NSLogv` (captures `[IG]`)

**Files:**
- Modify: `tweak/Peter.m:929-943` (prototypes), `tweak/Peter.m:945-972` (tableau), section Rapport (corps des hooks, après Task 1)

**Interfaces:**
- Consumes : `NWReportAppendLine(const char *tag, NSString *msg)` (Task 1), table `NWRbTargets`/`NWRbFillTargets`/`NWRbImage` (l.945-1023 — filtre images système déjà en place, l.994).
- Produits : `static void NWHook_NSLog(NSString *format, …)`, `static void NWHook_NSLogv(NSString *format, va_list args)`, `static void (*NWOrig_NSLog)(NSString *, …)`, `static void (*NWOrig_NSLogv)(NSString *, va_list)`.

- [ ] **Step 1: Prototypes + pointeurs d'origine (après la l.937)**

```objc
static void NWHook_NSLog(NSString *format, ...);
static void NWHook_NSLogv(NSString *format, va_list args);
static void (*NWOrig_NSLog)(NSString *format, ...);
static void (*NWOrig_NSLogv)(NSString *format, va_list args);
```

- [ ] **Step 2: Étendre la table 8 → 10 (l.947-971)**

- `static NWRebindTarget NWRbTargets[10];`
- `n8/r8/o8` → tableaux de **10**, avec en plus : `"NSLog"` → `NWHook_NSLog` → `&NWOrig_NSLog`, `"NSLogv"` → `NWHook_NSLogv` → `&NWOrig_NSLogv`.
- Les deux boucles `for (int i = 0; i < 8; …)` → `i < 10` ; `NWRbTargetsCount = 10`.
- `dlsym(RTLD_DEFAULT, …)` échouant = ligne `rebind: symbole absent` déjà gérée.

- [ ] **Step 3: Corps des hooks (fin de la section Rapport)**

- `NWHook_NSLogv(format, args)` : si `NWInReportHook` ou `!format` → appel direct de l'original ; sinon `NWInReportHook=YES` ; `va_copy` → `initWithFormat:arguments:` → `NWReportAppendLine("IG", s)` → `NWInReportHook=NO` → original avec le `va_list` d'origine (non consommé).
- `NWHook_NSLog(format, …)` : `va_start` ; formatage via `va_copy` (mêmes étapes) ; forwarding **par `NWOrig_NSLogv(format, ap)`** (un variadic ne se retransmet pas tel quel ; `NSLog(f, vl) ≡ NSLogv(f, vl)`) ; si `NWOrig_NSLogv == NULL` → pas de forwarding (la ligne est déjà dans le rapport). `va_end` dans tous les cas.
- Garde `__thread NWInReportHook` partagée avec `NWLogImpl` si ré-entrée (Review Focus 2).

- [ ] **Step 4: Vérifications locales + commit + push + CI**

Run : `check_syntax.py` (Expected `remaining open: 0`) ; `Select-String -Pattern 'NWRbTargets\[|NWRbTargetsCount =' tweak/Peter.m` → 1× `[10]`, 1× `= 10`.
Commit `w10-6: rebind NSLog/NSLogv -> rapport [IG] (table 10, garde anti-recursion)` ; push ; CI SUCCESS, **13 warnings identiques**.

---

### Task 3: Crashs appendés dans le rapport

**Files:**
- Modify: `tweak/Peter.m:1387-1429` (`NWCrashWStr`/`NWCrashSignal`), `tweak/Peter.m:1432-1450` (`NWCrashExceptionHandler`)

**Interfaces:**
- Consumes : `NWReportFD` (Task 1), `NWReportPath()`/`NWReportOpen()`/`NWReportLock` (Task 1), `NWCrashLogPath()` (l.1377).
- Produits : rapport contenant le bloc crash complet (attendu par `NWReportFullText`/`NWReportPreview` — ces deux helpers sont **créés en Task 4**, voir ruling Task 1) ; `static void NWReportAppendRaw(NSString *text)` (append UTF-8 brut sous `NWReportLock` — **créée ici**, Task 1 l'avait retirée pour garder les CI intermédiaires à 13 warnings).

- [ ] **Step 1: Miroir signal → rapport**

Ajouter `static void NWCrashWBoth(int fd, const char *s)` : écrit sur `fd` **et** sur `NWReportFD` (si `>= 0`) — paires `write()` pures (async-signal-safe). Remplacer les appels `NWCrashWStr(fd, …)` dans `NWCrashSignal` par `NWCrashWBoth(fd, …)` ; pour `backtrace_symbols_fd(frames, n, fd)` : appeler une 2ᵉ fois avec `NWReportFD` si `>= 0`. **Aucun lock dans ce chemin** (le handler signal ne doit jamais prendre `NWReportLock` — Review Focus 2/1).

- [ ] **Step 2: Exception ObjC en append (plus d'écrasure)**

Créer d'abord `static void NWReportAppendRaw(NSString *text)` (ruling Task 1 : définie ici, pas en Task 1) : `if (!text.length) return;` + open lazy (`NWReportFD < 0` → `NWReportOpen()`) + `dataUsingEncoding:NSUTF8StringEncoding` **avant** le lock, puis lock + 1 `write()` + unlock (même protocole que `NWReportAppendLine`).

Dans `NWCrashExceptionHandler` : remplacer `[s writeToFile:NWCrashLogPath() …]` par (a) `NWReportAppendRaw(s)` et (b) append sur `nine9wham_crash.log` via `open(NWCrashLogPath().fileSystemRepresentation, O_WRONLY|O_APPEND|O_CREAT, 0644)` + `write` des bytes UTF-8 + `close`. L'alerte « Last crash report » (mtime, l.8559) reste fonctionnelle : le fichier est toujours réécrit à chaque crash.

- [ ] **Step 3: Vérifications locales + commit + push + CI**

Run : `check_syntax.py` (0) ; `Select-String -Pattern 'writeToFile:NWCrashLogPath' tweak/Peter.m` → **0 occurrence**.
Commit `w10-6: crashs appendes au rapport (signal en miroir, exception sans ecrasure)` ; push ; CI SUCCESS, 13 warnings.

---

### Task 4: Onglet Report (UI)

**Files:**
- Modify: `tweak/Peter.m:4693-4712` (`rebuild`), `tweak/Peter.m:4715-4723` (`moduleTitle`), `tweak/Peter.m:5267-5274` (grille `mods`), méthode `buildReport` (à ajouter près de `buildReset`, ~l.6902)

**Interfaces:**
- Consumes : `NWReportPath()`/`NWReportReadTail()`/`NWReportFD`/`NWReportLock`/`NWReportOpen()` (Task 1), `NWCrashLogPath()` (Task 3), helpers UI existants (`addSection`, `addRowsCard`, `addRow`, `NWLabelMake`, `NWAlert`, `NWL`).
- Produits : module `report` accessible par `openModule:@"report"` ; **ruling Task 1** : `NWReportClear()`, `NWReportPreview()`, `NWReportFullText()` sont **créées dans cette task** (définies en Task 1 elles produisaient 3 warnings `unused function` en CI intermédiaire).

- [ ] **Step 0: Créer les 3 helpers de lecture (ruling Task 1 — définis ici, pas en Task 1)**

Dans la section « Rapport persistant » (après `NWReportMaybeRotate`, à l'emplacement du commentaire placeholder) :

- `static void NWReportClear(void)` : si `NWReportFD >= 0` → lock + `ftruncate(NWReportFD, 0)` + unlock.
- `static NSString *NWReportPreview(void)` : aperçu 60 000 derniers octets (`NWReportReadTail(60000ULL)`) ; fichier vide → `@"(empty)"` ; `initWithData:UTF8` ; si lecture partielle (`sz > 60000`) écarte tout avant le premier `\n` (caractère UTF-8 potentiellement coupé — Review Focus 5) ; `@try/@catch` → `(read error: …)`.
- `static NSString *NWReportFullText(void)` : rapport complet (`dataWithContentsOfFile:NWReportPath()`) + `\n\n=== nine9wham_crash.log ===\n` + contenu de `NWCrashLogPath()` s'il existe ; vide → `@"(empty)"` ; `@try/@catch`.

- [ ] **Step 1: Brancher le module**

- `rebuild` : ajouter `else if ([self.module isEqualToString:@"report"]) { [self buildReport]; }`
- `moduleTitle` : `@"report": @"Report"` (dictionnaire l.4716).
- Grille dashboard `mods` (l.5267) : insérer après « Changelog » : `@[@"Report", @"doc.text", @"report", NWAccent()]` (la boucle gère déjà l'impair, l.5288).

- [ ] **Step 2: `buildReport` — aperçu**

`- (void)buildReport { … }` avec `__weak typeof(self) weakSelf = self;` en tête (pattern l.5253) :
- `[self addSection:@"Report"]` + label d'aide `NWL(@"rp_hint", @"Full log — copy it and send it as is.", @"Journal complet — copiez-le tel quel et envoyez-le.", @"Registro completo — cópialo tal cual y envíalo.")`.
- `UITextView` : `text = NWReportPreview()`, `editable = NO`, `font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]`, `textColor = NWDim()`, `backgroundColor = NWCardGlass()`, `layer.cornerRadius = 12`, `textContainerInset` 8 ; hauteur fixe 320 ; dans la stack `content`.
- Pas de `keyWindow`/`windows` : les alertes passent par `NWAlert`/`NWTopVC` existants.

- [ ] **Step 3: `buildReport` — actions (rows style Blaze)**

`UIStackView *card = [self addRowsCard];` puis, chacune avec `NWL` :
- **Copy all** (icône `doc.on.doc`, valeur `@"Report + crash log"`) : `NSString *t = NWReportFullText(); UIPasteboard.general.string = t;` puis `NWAlert(NWL(@"rp_cop_t", @"Copied", @"Copié", @"Copiado"), [NSString stringWithFormat:NWL(@"rp_cop", @"Copied — %ld characters.", @"Copié — %ld caractères.", @"Copiado — %ld caracteres."), (long)t.length])`.
- **Share** (icône `square.and.arrow.up`) : `UIActivityViewController(activityItems:@[NWReportFullText()], applicationActivities:nil)` ; **`activity.popoverPresentationController.sourceView = self.view;` posé HORS bloc** (méthode/`weakSelf` direct — Review Focus 4) ; présentation via `weakSelf`.
- **Clear** (icône `trash.fill`, valeur `@"Erase report"`) : `UIAlertController` de confirmation — actions `@"Clear report"` → `NWReportClear()` + `[weakSelf rebuild]` ; `@"Clear everything"` → `NWReportClear()` + `removeItemAtPath:NWCrashLogPath()` + rebuild ; `@"Cancel"` (cancel). Toutes via `NWL`.

- [ ] **Step 4: Vérifications locales + commit + push + CI**

Run : `check_syntax.py` (0) ; `Select-String -Pattern 'keyWindow|sharedApplication.windows' tweak/Peter.m` → **même nombre d'occurrences qu'avant la task** (aucune nouvelle, aujourd'hui 2 : l.3308 et 3310).
Commit `w10-6: onglet Report (apercu, copier tout, partager, effacer)` ; push ; CI SUCCESS, **13 warnings identiques**.

---

### Task 5: Release — IPA vérifiée + README + docs

**Files:**
- Create: `C:\Users\ARMEL\AppData\Local\Temp\opencode\verify_w10_6.py` (copie de `verify_w10_5.py`)
- Modify: `README.md` (section Vague 10-6 ; retirer « (build actuel) » de la 10-5)
- Commit: `docs/superpowers/specs/2026-11-06-report-tab-design.md`, `docs/superpowers/plans/2026-11-06-report-tab.md`

**Interfaces:**
- Consumes : CI verte des tasks 1-4, release `nine9wham`.

- [ ] **Step 1: Copier et adapter le vérificateur IPA**

Copier `verify_w10_5.py` → `verify_w10_6.py` : chemin IPA → `w10_6.ipa` ; `b"w10-5"` → `b"w10-6"` ; ajouter `b"nine9wham_report.txt"` attendu à 1 dans `Peter.dylib` ; REF sha binaire inchangée `fdf2faf8faf6291dee9031f94efd427b6f02513a0091764d3a81b079881fefd2`.

- [ ] **Step 2: Télécharger l'IPA de la dernière CI**

```powershell
$env:GH_TOKEN='ghp_…'
$rel = gh api repos/mpouki04-tech/nine9wham/releases/tags/nine9wham | ConvertFrom-Json
$a = $rel.assets | Where-Object { $_.name -eq 'nine9wham_instagram_454.ipa' }
curl.exe -sL -C - -H "Accept: application/octet-stream" -H "Authorization: token $env:GH_TOKEN" -o "C:\Users\ARMEL\AppData\Local\Temp\opencode\w10_6.ipa" "$($a.url)"
```
Expected : taille fichier = `$a.size`.

- [ ] **Step 3: Vérifier l'IPA + sha256**

Run : `python verify_w10_6.py` → `RESULT: OK` (0 résidu RyukGram, `cryptid=0`, 154 dylibs, binaire byte-identique, `w10-6` + `nine9wham_report.txt` dans Peter.dylib) ; calculer sha256 + taille de l'IPA.

- [ ] **Step 4: README + commit docs + push final**

Section `### Vague 10-6 (build actuel) — onglet Report : journal persistant complet` : symptôme (crash à l'entrée du nom, besoin de copier-coller), causes/raisons (NWLog=NSLog non persistant, exception qui écrasait le crash), mécanique (fd O_APPEND, rebind NSLog 8→10, append crash, rotation 2 Mo), limites (`os_log` invisible), IPA (taille + sha256) + CI (runs, 13 warnings). Retirer « (build actuel) » du titre 10-5. Commiter design + plan avec le README ; push (commande Global Constraints).

- [ ] **Step 5: Rapport final FR**

Résumer : ce qui a été construit, validations (CI 13 warnings, IPA OK), et instructions de test utilisateur : installer → reproduire le crash à l'entrée du nom → relancer → menu → **Report → Copy all** → coller le texte ici.
