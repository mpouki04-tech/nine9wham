# Purge de l'héritage RyukGram + preuve du crash prénom (w10-7)

Date : 2026-11-06
Statut : en attente d'approbation

## Pourquoi

Forensique de session (w10-5) sur l'appareil de l'utilisateur :

- **keychain : 106 items**, dont 6 listés — **tous** suffixés `_ryg_` /
  `ryg_` : `instagram.activeaccount__ryg_-com_burbn_instagram_G6Y5X5Q5R7 /
  61516395224`, `wr.<UUID>.…activeaccount_ryg_…`,
  `…instagramtoken-share.service_ryg_…`,
  `instagram.inactiveloggedinaccounts__ryg_…`,
  `device_based_login.growth_ryg_…/accounts` ;
- cookies partagés 0, prefs bundle 30 clés **sans credential**, webview 0,
  fichiers session aucun.
→ VERDICT : **prefs bundle + keychain**. Le compte fantôme `61516395224`
ne vit QUE dans le keychain. `device_based_login.growth` est le relais de
reconnexion probable (login device-based au lancement).

Preuves d'origine du suffixe (fouille w10-7) :

- `check_markers.py` sur l'IPA shipée w10-6 : binaire Instagram **454** +
  `Peter.dylib` = **0 occurrence** de `_ryg_`, `ryg_`, `G6Y5X5Q5R7`,
  `activeaccount`, `61516395224`, `inactiveloggedinaccounts`. Notre build
  n'écrit **jamais** ces items — et ne peut donc pas les lire non plus
  (services suffixés ≠ services qu'il cherche).
- `NoPluginsPatch.dylib` (71 808 o, shim « SideloadPatch » de RyukGram)
  contient : `_rygFishhook`, hooks `SecItemAdd/CopyMatching/Update/Delete`,
  `__ryg_`, `RyukGramSideloadSentinel`, `group.ryukgram.default`,
  log `[RyukGram][SideloadPatch]` avec `keychainGroups=` → **le suffixe
  `_ryg_` est le leur** : leurs requêtes keychain écrivent/lisent des
  services ainsi suffixés.
- Le keychain **survit à la réinstallation** (même Apple ID/team) et notre
  Reset ne le touche pas (choix assumé : machine id / attestation) → le
  fantôme survit à tout, y compris au Reset.
- IPA RyukGram = Instagram **449** (sha256 `6419ff24…`) ≠ notre base
  **454** (`fdf2faf8…`) : deux bases distinctes ; la nôtre n'ajoute que
  `Peter.dylib` (154 dylibs, aucun RyukGram) → **conflit de tweaks écarté**,
  détection Instagram sans preuve.

Symptômes à traiter :

1. **Compte fantôme** `61516395224` qui se reconnecte tout le temps.
2. **Crash à la saisie du prénom** → retour page d'accueil. Cause racine
   connue et corrigée en w10-2 (keystore App Attest
   `group.com.facebook.family.appattestation`) ; l'héritage RyukGram peut
   inclure d'éventuels **receipts d'attestation** (`KeychainReceiptStorage`)
   écrits à l'époque 449 → candidat à une récidive. **Preuve manquante** :
   le bloc CRASH du Report (w10-6) — l'utilisateur n'a transmis que la
   forensique, qui ne contient pas la pile.

## Objectifs

1. Purger (automatique + répétable) les items keychain **hérités RyukGram**,
   dépendance certaine : marqueur `ryg` / `ryuk`.
2. Ne **jamais** toucher : notre vault, tout item sans marqueur, et rien
   d'autre (le keychain légitime reste intact).
3. Chaque suppression **loguée dans le Report** → preuve avant/après
   copiable (Report → Copy all).
4. Forensique enrichie : **inventaire keychain complet** (les 106 items)
   logué dans le Report (l'alerte garde les 6 pour rester lisible).
5. Vérification sur appareil : forensique post-purge = **0 item hérité** ;
   le compte fantôme ne revient pas ; si le crash prénom persiste, le
   bloc CRASH du Report est livré pour analyse.

## Non-objectifs

- Supprimer des items **sans** marqueur `ryg` (impossible à distinguer en
  toute sûreté → hors périmètre).
- Les items dans `group.ryukgram.default` : invisibles pour nous (groupe
  non entité) — on ne peut ni les voir ni les supprimer ; ils sont inertes.
- Modifier le comportement d'attestation (corrigé en w10-2, inchangé).
- Fixer le crash **sans** preuve : aucun fix spéculatif.

## Approches considérées

1. **Retenue — A + C (validée par l'utilisateur)** : purge ciblée des
   patterns prouvés **+** preuve Report (forensique complète, bloc CRASH).
2. Écartée — B, lecture seule : le keychain reste sale,
   `device_based_login` continue de servir de relais, et les receipts
   hérités survivent.
3. Écartée — C seule (diagnostic) : les patterns sont **déjà prouvés**
   (forensique + `check_markers` + strings `NoPluginsPatch`) ; attendre
   ne fait que laisser le fantôme vivre.

## Comment (décisions)

### Détection (pattern unique, prouvé)

- Enumération avec la **même requête que la forensique** (generic +
  internet passwords, `kSecMatchLimitAll`).
- Cible : `service` **ou** `account` contient `ryg` ou `ryuk`
  (insensible à la casse) → couvre les 6 items montrés (`_ryg_`,
  `…_ryg_`, `growth_ryg_`) et `group.ryukgram.default`.
- **Invariant prouvé** : notre IPA contient 0 `ryg` (check_markers) → la
  purge ne peut viser que ce que RyukGram a écrit. Protections
  additionnelles vérifiées en premier : service contenant `nine9wham`
  (notre vault) jamais supprimé.
- Requête de suppression : classe + service + account + accessGroup
  **tels qu'énumérés** ; nos hooks `SecItem*` font déjà le repli sans
  access group si besoin. Idempotent.

### Déclenchements

1. **Boot, une fois par build** : flag `Documents/nw9_kcpurge_done`
   (même motif que `nw9_forensics_done`), effacé par le Reset. File
   utilitaire, après le bootstrap state → le Report reçoit le log dès le
   premier lancement.
2. **Manuel** : Device identity → *Purge legacy RyukGram keychain* →
   alerte `N item(s) supprimé(s)` (+ « déjà propre » si 0).
3. **Reset** : appelle aussi la purge (le Reset ne touchera toujours que
   le marqué `ryg`, jamais le reste du keychain).

### Journalisation (Report)

- Par item : `[NW] kc-purge: <service> / <account> (status=…)` via NWLog.
- Synthèse : `keychain purge: N supprimés / M cibles`.
- Forensique : ligne 4 enrichie `… dont N hérités (ryg)` + **liste
  complète** (106) loguée dans le Report ; l'alerte reste à 6 lignes.

### Vérifications (fin de tâche)

1. Rejouer `check_markers.py` → 0 marqueur dans l'IPA.
2. CI : SUCCESS, **13 warnings identiques**.
3. IPA vérifiée : `cryptid=0`, binaire byte-identique REF, `Peter.dylib`
   contient `w10-7`.
4. Sur appareil (utilisateur) : installer → Session forensics →
   `0 hérité` → le fantôme ne revient pas → test création de compte
   (prénom) → si crash : Report → Copy all (bloc CRASH).

## Invariants

UI EN + `NWL(key,en,fr,es)` (nouvelles chaînes : bouton purge, alertes),
design Blaze (`NWBg/NWCardGlass/NWAccent/NWDim/NWLine`), CI = **13
warnings**, aucun nouveau `keyWindow`/`windows`, `Peter.m` CRLF sans BOM,
`NWBuildID` → `w10-7`, usage **Native/inline**, PAT jamais commité.

## Risques / ouverts

- **Le fantôme survit à la purge** → il vit alors hors keychain ; la
  forensique enrichie (liste complète + bloc CRASH) tranche à ce moment-là.
- **Crash prénom persiste** → pas de fix deviné : le bloc CRASH du Report
  est la pièce manquante, on analysera alors.
- Un item legacy portant une identité (mid) serait supprimé → identité
  régénérée ; le pin manuel (Device identity) gagne s'il est posé.
- Items `group.ryukgram.default` : documentés comme inertes et non
  supprimables.
