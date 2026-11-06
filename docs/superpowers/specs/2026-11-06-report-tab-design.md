# Onglet Rapport — journal persistant complet (w10-6)

Date : 2026-11-06
Statut : en attente d'approbation

## Pourquoi

L'utilisateur veut un onglet « Rapport » qui enregistre **tout** le
déroulé de l'application pour pouvoir tout copier-coller et le remettre
à l'analyse — y compris quand l'app plante **à l'entrée du nom lors de la
création de compte**. Le rapport doit donc survivre au crash.

État actuel du code :
- `NWLog` = simple `#define … NSLog(…)` (Peter.m:45) → **rien n'est écrit
  sur disque**, tout le journal disparaît au crash.
- Le rapporteur de crash existe déjà (`Documents/nine9wham_crash.log`,
  signal async-signal-safe + exception ObjC) mais ne contient **que** la
  pile du plantage, pas le déroulé. L'exception actuellement **écrase**
  le fichier (`writeToFile`) au lieu d'append.
- Navigation : modules du dashboard (`self.module` + `openModule:` +
  grille `mods` Peter.m:5267) — un module « Report » s'y intègre
  naturellement.

## Objectifs

1. Journal persistant : **chaque ligne écrite sur disque
   immédiatement** (append direct, sans buffer) → surviv à SIGSEGV /
   SIGABRT / kill.
2. Capturer aussi les **logs `NSLog` d'Instagram** (tag `[IG]`) — le
   crash vient de leur code, le contexte « juste avant » est décisif.
3. Les **crashs** (signal + exception) atterrissent dans le même
   rapport, appendés (jamais d'écrasure).
4. Onglet **Report** : aperçu + bouton **Copier tout** (presse-papier) +
   Effacer + Partager.
5. Invariants respectés : UI EN + `NWL(key,en,fr,es)`, design Blaze
   (`NWBg/NWCardGlass/NWAccent/NWDim/NWLine`), CI = **13 warnings
   identiques** (aucun nouveau `keyWindow`/`windows`), fichier CRLF sans
   BOM.

## Non-objectifs

- `os_log` interne d'iOS : buffer système, inaccessible depuis l'app.
- Tout upload réseau du rapport (données potentiellement sensibles →
  Clear disponible, partage manuel uniquement).
- Capturer stderr / redirections système (non fiable sur iOS moderne).

## Approches considérées

1. **Retenue — rapport complet (Instagram inclus)** : `NWLog` réécrit
   pour écrire sur disque + `NSLog`/`NSLogv` rebindés via le fishhook
   maison existant (tableau `NWRbTargets` 8 → 10) → un seul fichier
   reçoit `[NW]` et `[IG]`.
2. Écartée — journal nine9wham + crash seulement : zéro rebind de plus,
   mais si le plantage vient d'Instagram on ne voit que la pile, sans le
   contexte juste avant (c'est précisément le besoin).
3. Écartée — redirection stderr / capture os_log : non fiable ou
   inaccessible sur iOS moderne.

## Comment (décisions)

### Fichier et écriture
- `Documents/nine9wham_report.txt`, fd ouvert en permanence
  `O_WRONLY|O_APPEND|O_CREAT` → `write()` direct à chaque ligne, aucun
  buffer stdio : la ligne est sur disque avant le crash suivant.
- Format de ligne : `HH:MM:SS.mmm [NW|IG] message`.
- `O_APPEND` rend les écritures multi-threads atomiques.

### Nos logs
- `NWLog` devient une fonction `NWLogImpl(fmt, …)` (format ObjC) :
  append dans le rapport **puis** `NSLog` pour le système (comportement
  console inchangé). Macro `NWLog` conservée, aucun appel existant ne
  change.

### Logs Instagram
- Rebind `NSLog` + `NSLogv` : ajouter 2 cibles à `NWRbTargets` (8 → 10,
  boucles et `NWRbTargetsCount` incluses).
- Hook : `va_copy` → formatage ObjC → append tag `[IG]` → appel de
  l'original (pointeur sauvé par le rebind).
- Garde `__thread` anti-récursion ; images système déjà filtrées
  (`/System`, `/usr/lib` — Peter.m:994) ; `Peter.dylib` exclu (dladdr) →
  notre `NWLog` ne repasse pas par le hook.
- Limite connue : seuls les passages par `NSLog`/`NSLogv` sont captés
  (pas `os_log`) — documenté, la pile de crash couvre le reste.

### Crashs
- Handler signal (C, async-signal-safe) : écrit déjà dans
  `nine9wham_crash.log` ; on **ajoute** le même bloc dans le rapport via
  le fd déjà ouvert (`write()` pur, autorisé en signal handler).
- Handler exception : passage de `writeToFile` (écrasure) à **append**
  dans les deux fichiers (historique des crashs conservé).
- L'alerte « Last crash report » existante (mtime vs
  `NW_BOOT_KEY_CRLAST`) continue de lire `nine9wham_crash.log` →
  comportement inchangé.

### Rotation
- Si taille > 2 Mo : garder la moitié finale (vérifié à l'ouverture du
  fd au boot + dans le flush 15 s déjà existant).

### Onglet Report
- Module `report` : case dans la grille du dashboard (après
  « Changelog »), branche dans `rebuild` + `moduleTitle`.
- Écran : aperçu `UITextView` monospace (font 11, `NWDim` sur
  `NWCardGlass`), non éditable, **1500 dernières lignes** (ne pas figer
  l'UI) + sections/rows style Blaze pour les actions :
  - **Copy all** → `UIPasteboard` = rapport complet + bloc
    `nine9wham_crash.log` (alerte « Copied — N characters »).
  - **Share** → `UIActivityViewController`.
  - **Clear** → tronque le rapport (et propose de supprimer le crash).
- Aucun `keyWindow`/`windows` nouveau (utiliser les helpers existants).

### Version
- `NWBuildID` → `w10-6` (relance toutes les étapes de boot).

## Reste au builder

Implémenter dans `tweak/Peter.m` (+ `README.md`), pousser, suivre la
CI (13 warnings identiques exigés), télécharger et vérifier l'IPA
(verify : 0 résidu, `cryptid=0`, 154 dylibs, binaire byte-identique,
`w10-6` présent), documenter en README.
