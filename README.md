# @nine9wham

**Instagram modifié** — menu flottant, **conteneurs** (téléphones virtuels isolés) et **fake GPS** par conteneur.

> Base : Instagram **453.0.0** propre (`cryptid=0`, aucun dylib injecté) — voir [Choix de la base](#choix-de-la-base).

---

## Ce que ça fait

| Fonction | Détail |
|---|---|
| **Menu flottant `@nine9wham`** | Bouton « 99 » draggable (aimanté aux bords), **toujours visible**. Panneau `PanModal` sombre **copié du design Blaze** (cellules `HeaderView` / `GridCell` / `ListCell` / `SwitchListCell`, sections à en-tête 45 pt, grille 2 colonnes) — **sans** la licence Blaze/Bumble. |
| **Accueil** | Grille d'accueil (Ghost, Orbit, Proxy, Containers, App & Device, Changelog) + sections `App & Device`, `nine9wham` (Version / Changelog), `Support`, `Reset` — exactement comme Blaze. |
| **Ghost** | Switch « Enable » (« Ghost for *conteneur* ») + « Preferred Country » + « Formulate » (data aléatoire) + modules Device / Locale / TimeZone / Other, `Identifiers` (Vendor / Advertising / Generate New Identifier). Le switch **coupe réellement** les hooks d'empreinte : OFF = valeurs réelles du téléphone. |
| **Conteneurs** | Chaque conteneur = un **nouveau téléphone** aux yeux d'Instagram : prefs + cookies + keychain + empreinte isolés. Autant que voulu (illimité). Copy Blaze exacte des alertes (switch / rename / delete). |
| **Feuille « New Container »** | Nom + switch « Enable Spoof » (« Random data with Ghost? ») + ligne « Spoof Location » ouvrant la **carte du monde**, bouton `Create`. |
| **Empreinte unique** | IDFV/IDFA aléatoires, nom d'appareil, locale et fuseau cohérents, mémoire/CPU — et **modèle fictif cohérent avec la puce réelle** (iPhone 13 → 17, iOS 26.0 → 27.0.1 ; `iPhone18,1`→`iPhone18,4` pour l'iPhone 17). Le téléphone réel est détecté via `utsname`. |
| **Fake GPS (Orbit / Maps)** | **Carte du monde** (`MKMapView`) avec recherche (Nominatim) + sélection manuelle + « Current Location » + villes, **par conteneur**. Hooks `CLLocationManager` + injection des positions au delegate, plus d'appel réel quand le fake est actif. |
| **Proxy (BETA)** | `Stay Invisible` — HTTPS/SOCKS5 par conteneur : Host/I.P, Port, authentification, I.P Checker. |
| **Nouveau conteneur = nouvelles autorisations** | Prefs vierges → Instagram **redemande** ses autorisations internes (fichiers, contacts, etc.) à la création. |
| **Survie des comptes** | Snapshot **toutes les 15 s** + à l'entrée en arrière-plan, et **vault dans le keychain** : la réinstallation hebdomadaire (Sideloadly, cert 7 jours) et les mises à jour **ne perdent pas les conteneurs**. |

### Limitation connue (iOS)

Les autorisations **système** (Fichiers, Appareil photo…) ne peuvent pas être re-déclenchées depuis l'app : iOS ne le permet à aucune app. En revanche toutes les demandes **internes** d'Instagram se re-déclenchent avec des prefs vierges. La sauvegarde des comptes, elle, repose sur le keychain (survit à la ré-install).

---

## Installer

1. Télécharger l'IPA : **[Release `nine9wham`](https://github.com/mpouki04-tech/nine9wham/releases/download/nine9wham/nine9wham_instagram_453.ipa)**
   sha256 : `2f73b31371f2e0bb9da7c8002c8f119448ecec76646fa5ad5083c1666ce8eaac` (338 640 288 octets)
2. Ouvrir **Sideloadly** → sélectionner l'IPA → Install (certificat 7 jours, même Apple ID). Sideloadly est ici **uniquement** l'outil d'installation : aucune licence Blaze/Bumble n'est incluse.
3. Lancer Instagram → le bouton **99** apparaît à droite.

> Après 7 jours : relancer Sideloadly avec la **même Apple ID** → les conteneurs reviennent (vault keychain).

---

## Conteneurs : mode d'emploi

- **Containers → ＋** → feuille **New Container** : nom, switch *Enable Spoof*, ligne **Spoof Location** (carte du monde) → **Create** → l'app redémarre → Instagram redemande tout (compte neuf, empreinte neuve).
- **Switch de conteneur** (carte) → alerte *« Are you sure you want to switch to the %@ container? Restarting the app is required! »* → *Yes, I'm sure!* → relance.
- **Renommer** / **Supprimer** → alertes copy Blaze (suppression autorisée même pour le conteneur actif).
- **Raccourcis carte** : Ghost / Orbit / Proxy s'appliquent au conteneur actif.
- **Orbit / Maps** → carte du monde : recherche de lieu, sélection manuelle, *Current Location*, Standard/Hybrid/Satellite.
- **Ghost** → switch *Enable* (coupe les hooks d'empreinte → valeurs réelles), pays préféré, *Formulate*, choix iPhone / Version / Storage / Device Name / Identifiers / Locale / TimeZone.

---

## Architecture

```
nine9wham/
├── tweak/Peter.m                 # le dylib (menu + conteneurs + fingerprint + fake GPS)
├── scripts/
│   ├── inject_dylib.py           # ajoute LC_LOAD_WEAK_DYLIB @rpath/Peter.dylib
│   └── verify_ipa.py             # contrôle l'IPA produite
└── .github/workflows/build.yml   # CI macOS : compile → injecte → repack → release
```

**Méthode d'injection** (reprise de RyukGram) : `LC_LOAD_WEAK_DYLIB` `@rpath/Peter.dylib` + `LC_RPATH @executable_path/Frameworks` (déjà présent dans la base 453). Aucun `LC_LOAD_DYLIB` fort → l'app démarre même si le dylib manque.

**Hooks** :
- ObjC : `UIDevice` (name/model/idfv), `NSProcessInfo` (mémoire/CPU, **gated par le switch Ghost** — OFF = valeurs réelles), `NSLocale`, `NSTimeZone`, `ASIdentifierManager` (IDFA).
- GOT : `_uname`, `_sysctl`, `_sysctlbyname` rebinding par écriture directe (`vm_protect`) — binaire **arm64 sans PAC**.
- Localisation : `CLLocationManager` (`location`, `startUpdatingLocation`, `requestLocation`, `setDelegate:`) + **substitution des delegates** et ré-injection du timer toutes les 2 s ; **aucun appel réel** quand le fake est actif.
- Proxy (BETA) : swizzle de `NSURLSessionConfiguration.defaultSessionConfiguration`.

**UI** : fenêtre overlay `NWOverlayUIWindow` (bouton flottant + dashboard + alertes), `hitTest` limité au bouton flottant → **Instagram reste cliquable partout ailleurs** ; `canBecomeKeyWindow = NO` (clavier/first responder préservés).

**Carte** : `NWMapPicker` (`MKMapView`, Standard/Hybrid/Satellite, recherche Nominatim, géocodage inverse, *Current Location*) — accessible à la création de chaque conteneur et depuis Orbit/Maps.

**État** : `Library/Application Support/nine9wham/state.plist` + vault keychain (`com.nine9wham.vault`) ; snapshots par conteneur (`prefs.plist`, `cookies.plist`). Les champs `loc` (position) et `ghostOn` sont stockés **par conteneur**.

---

## Choix de la base

La consigne initiale visait la base **449** (celle de RyukGram). La base utilisée est **453.0.0 propre** :

- `cryptid=0` (déjà décryptée), 3 709 entrées, aucune modification,
- **aucun dylib injecté** (contrairement à RyukGram 449 qui en a 4 dans `Frameworks`),
- `LC_RPATH @executable_path/Frameworks` **déjà présent** → injection valide sans toucher aux rpaths,
- `CFBundleExecutable=Instagram`, `MinimumOSVersion=16.3`.

Résultat : une base saine, sans résidu d'un autre tweak, et la méthode d'injection de RyukGram conservée à l'identique.

---

## Build (CI)

Push sur `main` → GitHub Actions (`macos-14`) :

```
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.3 \
  -O2 -fobjc-arc -dynamiclib -install_name @rpath/Peter.dylib \
  -framework Foundation -framework UIKit -framework CoreLocation -framework Security \
  -framework MapKit -framework CoreGraphics -framework QuartzCore \
  -o Peter.dylib tweak/Peter.m
```

puis : téléchargement de la base (release `base`) → `inject_dylib.py` → copie dans `Frameworks/` → repack → `verify_ipa.py` → **upload en release `nine9wham`**.

---

## Sécurité / licences

- Aucune licence **Bumble** ni **Blaze** n'est incluse : seul le **design** du menu et l'**architecture** des conteneurs/localisation ont été analysés, puis réécrits.
- Tweak inclus : uniquement les parties utiles de l'analyse RyukGram (méthode d'injection). **RyukGram, FLEXing, libflex, NoPluginsPatch sont retirés** — base « Seulement Peter ».
