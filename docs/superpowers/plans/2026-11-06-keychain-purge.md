# Purge du keychain hérité RyukGram (w10-7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supprimer les items keychain hérités de RyukGram (marqueur `_ryg_`) qui font revenir le compte fantôme `61516395224`, avec preuve dans le Report, sans jamais toucher au vault ni aux items sans marqueur.

**Architecture:** Un seul fichier `tweak/Peter.m`. Deux fonctions C insérées après `NWVaultRead` (l.1374) : `NWKeychainIsLegacyKC` (test de marqueur) + `NWKeychainPurgeLegacy` (énumération + suppression + log). Trois déclencheurs : boot 12 s (flag `nw9_kcpurge_done` contenant `NWBuildID`, purge **avant** la forensique), Reset (synchrone, avant `exit(0)`), bouton Device identity. La forensique est enrichie : inventaire complet logué dans le Report + compteur d'hérités dans la ligne 4.

**Tech Stack:** Objective-C (dylib iOS arm64, `-fobjc-arc`), Security framework (`SecItemCopyMatching`/`SecItemDelete`), UIKit, aucun dépôt externe.

**Spec:** `docs/superpowers/specs/2026-11-06-keychain-purge-design.md` (design approuvé — le plan argue de ce document)

## Global Constraints

- UI en anglais ; toute chaîne visible via `NWL(key, en, fr, es)` (FR/ES fournis, **sans accents** — convention du fichier).
- Design Blaze : couleurs `NWBg/NWCardGlass/NWAccent/NWDim/NWLine`, helpers `addSection`/`addRowsCard`/`addRow`/`NWAlert`/`NWTopVC`.
- CI = **13 warnings identiques** (mêmes types, numéros de ligne libres) : unused `hash`, warn_unused_result ×2, unused `iv`, unused function `NWPill`, `contentEdgeInsets`, `keyWindow`, `windows`, `imageEdgeInsets`, unused `model`, `unused ios`, retain cycle, `overlayTimer` set-but-not-used. **Aucun nouveau** `keyWindow`/`windows`, aucune variable inutilisée, aucun `unused function`.
- Aucun `keyWindow`/`windows` ajouté (forensique/bouton existants n'en ajoutent pas).
- `Peter.m` en **CRLF sans BOM** ; jamais réécrit via PowerShell `Get-Content -Raw`.
- Usage **Native/inline** : aucun nouveau fichier, aucun repo externe, `dlopen` seulement si déjà présent.
- Aucun marqueur RyukGram (`ryukgram`, `_ryg_`, `ryg_`, `G6Y5X5Q5R7`, `activeaccount`, `61516395224`, `inactiveloggedinaccounts`) ne doit apparaître en **clair** comme littéral : le test de marqueur est reconstruit par bytes (`'r','y','g','_'` / `'r','y','u','k'`) ou dérivé (`'r' 'y' 'g'` + séparateur), cf. Task 1. Un littéral clair créerait un faux positif dans `check_markers.py` et surtout **un faux hérité** dans notre propre forensique.
- Chaque task se termine par : `check_syntax.py` (0 erreur) + extraction des `warning:` de la CI + comparaison des 13 types.
- Le `NWBuildID` devient `w10-7` (Task 4) — dernière tâche avant le ship pour que chaque CI intermédiaire reste cohérente.

## Tasks

### Task 1 — Helpers de purge keychain (test de marqueur + purge)

**Files:**
- Modify: `tweak/Peter.m` (insertion après `NWVaultRead`, finie l.1374, avant `NWVaultWrite` l.1376)

**Interfaces:**
```c
// Vrai si (service|account|accessGroup) contient le marqueur legacy RyukGram.
static BOOL NWKeychainIsLegacyKC(NSString *service, NSString *account, NSString *ag);
// Supprime les items hérités ; loggue chaque item supprimé via NWLog.
static NSUInteger NWKeychainPurgeLegacy(NSString *trigger);
```

- [ ] **Step 1: Test de marqueur sans littéral interdit.** Construire le motif une fois (dispatch_once) :
  ```c
  // motif = "ryg_" (4 lettres séparées — pas de litteral complet dans le binaire)
  static NSString *marker = nil; static dispatch_once_t once;
  dispatch_once(&once, ^{ marker = [NSString stringWithFormat:@"%c%c%c%c",
      'r','y','g','_', 0][0] ? [NSString stringWithFormat:@"%c%c%c%c", 'r','y','g','_'] : nil; });
  ```
  (forme réelle : `[NSString stringWithFormat:@"%c%c%c%c", 'r','y','g','_']` ; un second motif `"ryuk"` construit de même avec `'r','y','u','k'`.) Test : `rangeOfString:options:NSCaseInsensitiveSearch` sur `service`, `account` puis `accessGroup`. Retourne YES si l'un contient un motif. **Ne jamais** tester `nw9.` ni `nine9wham` (toujours NO).
- [ ] **Step 2: Énumération.** `NSDictionary *q = @{ (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
  (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll,
  (__bridge id)kSecReturnAttributes : @YES };` → `SecItemCopyMatching` (ignorer `errSecSuccess`/`errSecItemNotFound` ; autre erreur → `NWLog(@"[NW] kc-purge: enum err %d", …)` et return 0). Itérer les dicts : lire `kSecAttrService`, `kSecAttrAccount`, `kSecAttrAccessGroup`.
- [ ] **Step 3: Filtres de sécurité (ordre exact).** (a) si `NWKeychainIsLegacyKC` NO → skip silencieux ; (b) si service OU account contient `nine9wham` (test littéral autorisé, c'est le nôtre) → skip + `NWLog(@"[NW] kc-purge: SKIP vault …")` ; (c) sinon construire la requête de suppression `kSecClass` + `kSecAttrService` + `kSecAttrAccount` (+ `kSecAttrAccessGroup` si présente) et `SecItemDelete`.
- [ ] **Step 4: Log par item supprimé (preuve).** Succès → `NWLog(@"[NW] kc-purge: [%@] deleted service=%@ account=%@", trigger, svc, acc)` ; `errSecItemNotFound` → idem avec `missing` ; autre → `NWLog(@"[NW] kc-purge: [%@] FAIL %d service=%@", trigger, (int)err, svc)`. Retourner le compteur de suppressions.
- [ ] **Step 5: Vérification.** `python check_syntax.py` → 0 erreur ; grep du fichier : aucun littéral `ryukgram`/`_ryg_`/`ryg_`/`G6Y5X5Q5R7`/`61516395224` ajouté (les 4 chars séparés `'r','y','g','_'` sont autorisés, `check_markers.py` ne cherche que la séquence contiguë).

**Tests:**
- `check_syntax.py` : 0 erreur.
- `grep -n "ryg_\|ryukgram\|G6Y5X5Q5R7\|61516395224" tweak/Peter.m` : aucune ligne **nouvelle** contenant ces séquences contiguës.
- (Passe/Fail explicite) Les deux helpers sont référencés : `NWKeychainPurgeLegacy` encore NON référencé → il produirait `unused function` en CI ; il est consommé dès Task 2. **Donc Task 1 seule n'est pas committée** : elle est exécutée avec Task 2 en un même commit CI (voir "Coupling" plus bas) OU Step 6 ci-dessous crée un usage d'attestation :
- [ ] **Step 6 (anti-warning):** si le commit est isolé, référencer temporairement impossible → **règle : Task 1 + Task 2 = un seul commit CI**. Ne jamais pousser Task 1 seule.

### Task 2 — Déclencheurs : boot 12 s + Reset + bouton Device identity

**Files:**
- Modify: `tweak/Peter.m`
  - Boot : bloc forensique existant l.9289-9300 (avant `NWSessionForensicsShow()` l.9295)
  - Reset : `confirmReset` (effacement du flag forensique l.7414)
  - UI : `buildDeviceIdentity` (l.6819 ; après la rangée « Copy machine ID » l.7014-7023)

**Interfaces:** consomme `NWKeychainPurgeLegacy(trigger)` de Task 1 ; drapeaux : `nw9_kcpurge_done` (Documents).

- [ ] **Step 1: Boot.** Dans le `dispatch_after` 12 s (même bloc que la forensique), **avant** le test `nw9_forensics_done` :
  ```c
  NSString *kcf = [NWDocumentsDir() stringByAppendingPathComponent:@"nw9_kcpurge_done"];
  NSString *kcv = [NSString stringWithContentsOfFile:kcf encoding:NSUTF8StringEncoding error:NULL];
  if (![kcv isEqualToString:@NWBuildID]) {
      NSUInteger n = NWKeychainPurgeLegacy(@"boot");
      NWLog(@"[NW] kc-purge: boot purged=%lu", (unsigned long)n);
      [@NWBuildID writeToFile:kcf atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  ```
  La purge est donc **avant** `NWSessionForensicsShow()` → la forensique affichée à 12 s compte 0 hérité.
- [ ] **Step 2: Reset.** Dans `confirmReset`, juste **avant** `removeItemAtPath:…nw9_forensics_done` (l.7414) : `NWKeychainPurgeLegacy(@"reset");` + `NWLog(@"[NW] kc-purge: reset purged=%lu", …)`. Ajouter aussi le `removeItemAtPath` de `nw9_kcpurge_done` (revivra au prochain boot → purge re-vérifiée).
- [ ] **Step 3: Bouton Device identity.** Après la rangée « Copy machine ID » (l.7023), rangée Blaze :
  ```c
  [self addRow:c icon:@"trash"
          title:NWL(@"dev_kcp", @"Purge legacy RyukGram keychain",
                    @"Purger le keychain legacy RyukGram", @"Purgar keychain legacy RyukGram")
          value:nil
         action:^{
      NSUInteger n = NWKeychainPurgeLegacy(@"manual");
      NWAlert(NWL(@"dev_kcp", …), [NSString stringWithFormat:
              NWL(@"dev_kcpd", @"%lu legacy item(s) removed.",
                  @"%lu item(s) legacy supprime(s).", @"%lu elemento(s) legacy eliminado(s)."),
              (unsigned long)n]);
      [weakSelf rebuild];
  }];
  ```
  (`weakSelf` existe déjà dans `buildDeviceIdentity` l.6820.)
- [ ] **Step 4: Vérification.** `check_syntax.py` 0 erreur ; CI : les 3 nouvelles fonctions/rangées sont consommées → **aucun** `unused function` ; 13 warnings exactement.

**Tests:**
- `check_syntax.py` : 0 erreur.
- CI intermédiaire : SUCCESS, extraction `warning:` → 13 types identiques (commande Task 5).
- (Passe/Fail) `grep -n "nw9_kcpurge_done" tweak/Peter.m` → au moins 3 occurrences (boot lecture/écriture, Reset effacement).

**Coupling:** committer Task 1+Task 2 ensemble (sinon `unused function NWKeychainPurgeLegacy` en CI).

### Task 3 — Forensique enrichie : inventaire complet + compteur d'hérités

**Files:**
- Modify: `tweak/Peter.m` — `NWSessionForensicsShow()` (l.8118-8247 ; boucle keychain l.8154-8186)

**Interfaces:** réutilise `NWKeychainIsLegacyKC` (Task 1) pour le compteur ; le rapport garde son format `[NW] …` → visible tel quel dans Report.

- [ ] **Step 1: Inventaire complet.** La boucle keychain actuelle tronque la liste à N entrées pour l'alerte. Ajouter, **avant** la troncature, un log par item dans le Report : `NWLog(@"[NW] forensics: kc[%lu] service=%@ account=%@", i, svc, acc);` pour **chacun** des items (106 lignes — c'est la preuve demandée, le Report a une rotation 2 Mo, négligeable).
- [ ] **Step 2: Compteur hérité.** Pendant la boucle : `if (NWKeychainIsLegacyKC(svc, acc, ag)) legacy++;` puis enrichir la ligne 4 du rapport (`keychain N items …`) en `keychain N items (M legacy)` ; si `M > 0` conserver/ajouter la mention ` [SESSION?]` existante et préfixer le bloc d'alerte par `LEGACY ITEMS PRESENT`.
- [ ] **Step 3: Vérification.** `check_syntax.py` 0 erreur ; grep : `forensics: kc[` présent ; CI 13 warnings.

**Tests:**
- `check_syntax.py` : 0 erreur.
- (Passe/Fail) `grep -c "forensics: kc\[" tweak/Peter.m` ≥ 1 ; CI = 13 warnings.

### Task 4 — `NWBuildID` → `w10-7`

**Files:**
- Modify: `tweak/Peter.m` l.65 (`static NSString *const NWBuildID = @"w10-6";` → `@"w10-7"`)

- [ ] **Step 1:** Remplacer la valeur. C'est **ce littéral** que le boot flag `nw9_kcpurge_done` conserve : un bump de build re-tente la purge (garde-fou contre un item legacy réapparaissant).
- [ ] **Step 2: Vérification.** `grep -n 'NWBuildID = ' tweak/Peter.m` → `w10-7` ; `check_syntax.py` 0 erreur.

**Tests:**
- (Passe/Fail) `grep -c 'w10-6' tweak/Peter.m` = 0 dans la définition (les anciens commentaires de vague restent libres, mais la constante = `w10-7`).

### Task 5 — Commit + CI (13 warnings) + push

**Files:**
- Modify: commit de `tweak/Peter.m` (+ README venu de Task 6 si regroupé)

- [ ] **Step 1:** Avant push : `python check_syntax.py` → 0 erreur ; `python check_markers.py`-style sur le **source** : aucun littéral interdit ajouté.
- [ ] **Step 2:** Commit `w10-7: purge keychain legacy RyukGram (boot+reset+manual), forensique enrichie` puis push (jamais de PAT dans un fichier) :
  ```
  git -C "D:\OPENCODE\IPA INSTA WHAM\nine9wham" -c credential.helper= -c http.extraheader="AUTHORIZATION: basic <b64 session>" push origin main
  ```
- [ ] **Step 3: CI.** `$env:GH_TOKEN='<PAT session>'` puis `gh run watch <id> -R mpouki04-tech/nine9wham --exit-status --interval 30`. Attendre SUCCESS, puis extraire et comparer :
  ```
  gh run view <id> -R mpouki04-tech/nine9wham --log | Select-String "warning:" | ForEach-Object { ($_ -split "warning: ")[1] -replace ", notes? .*","" } | Sort-Object -Unique
  ```
  Attendu : **13** entrées, mêmes types que la référence (unused `hash`, warn_unused_result ×2, unused `iv`, unused function `NWPill`, `contentEdgeInsets`, `keyWindow`, `windows`, `imageEdgeInsets`, unused `model`, unused `ios`, retain cycle, `overlayTimer` set-but-not-used). Écart = régression : corriger avant de continuer (typiquement un helper non consommé ou une variable morte).
- [ ] **Step 4:** `NWBuildID` = `w10-7` vérifié dans le log/dylib de la CI.

**Tests:**
- (Passe/Fail) CI SUCCESS **et** 13 warnings **et** 0 nouveau `keyWindow`/`windows` (le compteur `keyWindow`/`windows` reste à 1+1 comme avant).

### Task 6 — Ship : IPA w10-7 + vérifications forensiques + README

**Files:**
- Modify: `README.md` (section vague 10-7 après la 10-5/10-6)
- Create (session temp, non commité) : `verify_w10_7.py` (copie de `verify_w10_6.py`)

**Consumes:** CI verte des tasks 1-5, release `nine9wham`.

- [ ] **Step 1:** Copier `verify_w10_6.py` → `verify_w10_7.py` : chemin IPA → `w10_7.ipa` ; `b"w10-6"` → `b"w10-7"` ; ajouter `b"nw9_kcpurge_done"` et `b"kc-purge"` attendus à ≥1 dans `Peter.dylib` ; REF sha binaire inchangée `fdf2faf8faf6291dee9031f94efd427b6f02513a0091764d3a81b079881fefd2` ; `cryptid=0`.
- [ ] **Step 2:** Télécharger l'asset :
  ```
  $rel = gh api repos/mpouki04-tech/nine9wham/releases/tags/nine9wham | ConvertFrom-Json
  $a = $rel.assets | Where-Object name -eq "nine9wham_instagram_454.ipa"
  curl.exe -sL -C - -H "Accept: application/octet-stream" -H "Authorization: token $env:GH_TOKEN" -o "C:\Users\ARMEL\AppData\Local\Temp\opencode\w10_7.ipa" "$($a.url)"
  ```
- [ ] **Step 3:** `python verify_w10_7.py` → `RESULT: OK` ; puis `python check_markers.py` (adapté au chemin `w10_7.ipa`) → **0 marqueur** dans l'IPA finale (la purge ne doit pasnon plus écrire de littéral RyukGram).
- [ ] **Step 4:** README : vague **10-7 — purge du keychain hérité** : origine `NoPluginsPatch.dylib` RyukGram prouvée par `check_markers.py` (notre IPA = 0 marqueur), les 3 déclencheurs, le flag `nw9_kcpurge_done`, la preuve via Report/forensique, le risque (identité régénérée si un mid hérité portait notre identifiant → « Roll a new fingerprint »), et **le critère de récidive** : si le prénom plante encore → bloc `CRASH` du Report collé tél quel.
- [ ] **Step 5:** Rapport final FR à l'utilisateur avec instructions de test : (1) relancer l'app → à 12 s forensique = `0 legacy` ; (2) sinon bouton « Purge legacy RyukGram keychain » ; (3) forensique relue = preuve ; (4) test du prénom à la création de compte ; (5) si crash → Report → **Copy all** → coller.

**Tests:**
- `verify_w10_7.py` : `RESULT: OK` (size, sha256, `w10-7`, `nw9_kcpurge_done`, `kc-purge`, REF binaire identique, `cryptid=0`, 0 nom RyukGram).
- `check_markers.py` : 0 occurrence de contenu.
- README : mention `10-7` présente.

## Commit Strategy

- **Commit 1 (CI intermédiaire):** Tasks 1+2+3+4 en un seul commit (jamais Task 1 seule → `unused function`), push, CI verte = **13 warnings**. Si le rythme le permet, un commit Task 1+2 (CI 13) puis Task 3+4 (CI 13) — deux CI, toujours 13 chacune.
- **Commit 2:** README (Task 6) — pas de CI utile mais le workflow se déclenche sur `tweak/**` uniquement ; README seul ne déclenche rien (`paths` limité à `tweak/**`, `scripts/**`, `build.yml`).
- PAT : uniquement en variable d'env de la session, **jamais** écrit dans un fichier commité (push protection GH013).

## Risks & Mitigations (repris du design)

- Items hérités invisibles (`group.ryukgram.default`) : suppression best-effort, aucun risque d'échec bloquant.
- Suppression d'un item legacy portant un mid encore utilisé → régénération d'identité ; mitigation : message d'alerte si la purge manuelle supprime ≥1 item (affiché dans l'`NWAlert` de la Task 2).
- Crash prénom persistant : **non spéculatif** — la purge n'est qu'une élimination d'état hérité ; le bloc `CRASH` du Report (w10-6) est la pièce manquante, on attend le copier-coller.
- Aucun item sans marqueur, aucun item `nw9.`/`nine9wham` touché (filtres Task 1 Step 3).
