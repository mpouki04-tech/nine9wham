# @nine9wham

**Instagram modifié** — menu flottant, **conteneurs** (téléphones virtuels isolés) et **fake GPS** par conteneur.

> Base : Instagram **453.0.0** propre (`cryptid=0`, aucun dylib injecté) — voir [Choix de la base](#choix-de-la-base).

---

## Ce que ça fait

| Fonction | Détail |
|---|---|
| **Menu flottant `@nine9wham`** | Bouton **carré translucide** (flou `SystemMaterialDark`, bordure blanche douce) avec **4 petits carrés** au centre — l'icône du menu Blaze, **sans badge**. Draggable (aimanté aux bords, snap animé), feedback tactile 120–180 ms, **toujours visible**. L'app s'ouvre directement sur **Containers** (chevron → Dashboard). Panneau sombre **translucide** (flou derrière) **copié du design Blaze** (heroes unifiés tuile + kicker + titre + badges, cellules `GridCell` / `ListCell` / `SwitchListCell`, sections à en-tête 45 pt, grille 2 colonnes, cartes en verre `NWCardGlass`) — **sans** la licence Blaze/Bumble. |
| **Accueil** | Grille d'accueil (Ghost, Orbit, Proxy, Containers, App & Device, Changelog) avec **une couleur propre à chaque module** (Ghost vert, Orbit bleu, Proxy/Containers accent, Changelog discret) + sections `App & Device`, `nine9wham` (Version / Changelog), `Support`, `Reset` — exactement comme Blaze. |
| **Ghost** | Switch « Enable » (« Ghost for *conteneur* ») + « Preferred Country » + « Formulate » (data aléatoire) + modules Device / Locale / TimeZone / Other, `Identifiers` (Vendor / Advertising / Generate New Identifier). Le switch **coupe réellement** les hooks d'empreinte : OFF = valeurs réelles du téléphone. |
| **Conteneurs** (landing) | Chaque conteneur = un **nouveau téléphone** aux yeux d'Instagram : prefs + cookies + keychain + empreinte isolés. **Écran recopié de Blaze** : cellules 70 pt (dossier + nom + sous-titre + icônes *Ghost / Location / Proxy / …*), bordure accent si **ACTIVE**, tap = basculer, menu **… → Sort by** (Name A-Z / Z-A, Date Newest / Oldest), bouton **＋ New Container** flottant en bas. Copy Blaze exacte des alertes (switch / rename / delete). |
| **Feuille « New Container »** | Nom + switch « Enable Spoof » (« Random data with Ghost? ») + ligne « Spoof Location » ouvrant la **carte du monde**, bouton `Create` (inactif tant que le nom est vide) — **le clavier remonte la carte** (evitement clavier copy Blaze), 1er tap sur le fond ferme le clavier, 2e tap ferme la feuille. |
| **Empreinte unique** | IDFV/IDFA aléatoires, nom d'appareil, locale et fuseau cohérents, mémoire/CPU — et **modèle fictif cohérent avec la puce réelle** (iPhone 13 → 17, iOS 26.0 → 27.0.1 ; `iPhone18,1`→`iPhone18,4` pour l'iPhone 17). Le téléphone réel est détecté via `utsname`. |
| **Fake GPS (Orbit / Maps)** | **Carte du monde** (`MKMapView`) avec recherche (Nominatim) + sélection manuelle + « Current Location » + villes, **par conteneur**. Hooks `CLLocationManager` + injection des positions au delegate, plus d'appel réel quand le fake est actif. |
| **Proxy (BETA)** | `Stay Invisible` — HTTPS/SOCKS5 par conteneur : Host/I.P, Port, authentification, I.P Checker. |
| **Nouveau conteneur = nouvelles autorisations** | Prefs vierges → Instagram **redemande** ses autorisations internes (fichiers, contacts, etc.) à la création. |
| **Survie des comptes** | Snapshot **toutes les 15 s** + à l'entrée en arrière-plan, et **vault dans le keychain**. Pour une re-install Sideloadly (cert 7 jours), utilisez **Export backup** dans le menu Support pour sauvegarder tous vos comptes vers un fichier chiffre, puis **Import backup** apres re-install. |

### Limitation connue (iOS)

Les autorisations **système** (Fichiers, Appareil photo…) ne peuvent pas être re-déclenchées depuis l'app : iOS ne le permet à aucune app. En revanche toutes les demandes **internes** d'Instagram se re-déclenchent avec des prefs vierges. La sauvegarde des comptes, elle, repose sur le keychain (survit à la ré-install).

## Sauvegarde & restauration (re-install Sideloadly / mise a jour)

Avec Sideloadly gratuit (certificat 7 jours), le dossier interne de l'app est efface a chaque re-installation. Pour ne pas perdre vos 100 comptes :

**1. Exporter une sauvegarde** : Menu → Support → **Export backup** → saisissez un mot de passe. Un fichier `nine9wham_backup_<date>.nw9` est cree dans `Documents/nine9wham_backups/`. Recuperez-le via l'app **Fichiers** ou **iCloud Drive** et gardez-le sur votre ordinateur.

**2. Restaurer** : apres re-install de l'IPA, ouvrez le menu → Support → **Import backup** → choisissez le fichier `.nw9` dans la liste → saisissez le mot de passe. Tous les comptes, prefxs, cookies, empreintes et localisations sont restaures. L'app redemarre automatiquement.

Le fichier de backup est chiffre (mot de passe derive + chiffre symetrique). Sans le mot de passe, il est illisible.

---

## Dernier build (interface)

- **Langue** : **anglais par défaut** (plus de détection automatique), drapeau **américain 🇺🇸** pour l’anglais (🇫🇷 / 🇪🇸 restent). Choix FR / EN / ES / **Auto (Phone language)**.
- **Langue *vu par Instagram*** : la langue choisie **et** le pays choisi deviennent la **langue du téléphone** d’Instagram → `AppleLanguages` / `AppleLocale` écrits + hooks `NSLocale currentLocale` et `preferredLanguages` (+ fuseau). **États-Unis ⇒ Instagram en anglais** automatiquement.
- **@nine9wham** : **centré exactement** — slots gauche/droite de **largeur fixe égale (32 pt)** + groupe central ajouté comme `arrangedSubview` (h/compression 751) : aucune dérive possible, quel que soit l’écran. Le `rebuild` supprime **toutes** les sous-vues de la barre (plus aucune vue flottante ne s’accumule).
- **Logo Telegram** : **pastille bleue 30 pt** (rayon 15, coin continu) avec **avion blanc 16 pt qui tourne en continu**, titre **@nine9wham** en gras 16 pt (`numberOfLines = 1`, réduction automatique), sous-titre *Instagram · nine9wham*.
- **Années de naissance normales** : hooks `+[NSCalendar currentCalendar]` / `autoupdatingCurrentCalendar` / `-[NSLocale objectForKey:NSLocaleCalendar]` → **calendrier gregorien forcé** quand la région n’est pas gregorienne (1447 hijri / 2568 bouddhiste → **1990**). Garde anti-recursion, copie retournée (jamais l’objet partagé), `@try` partout.
- **Bouton flottant** : carrés **agrandis** (0,40 + icône 30 pt) ; on peut le placer **n’importe où** — la position est **sauvegardée pendant le glissement et à l’annulation du toucher** (c’était l’annulation par le système qui le faisait « rebondir » vers le milieu), plus de rabattement sur les bords, marges 6/18/8 pt.
- **New Container** : bouton **noir translucide** (214 × 52, fond noir 45 %, bordure blanche 16 %).
- **Carte** : **champ de recherche sobre façon Apple/Google Maps** — `UISearchBar` supprimé (croix *clear* géante + double fond) → un seul `UITextField` dans une boîte 12 pt, **loupe 14 pt grise**, placeholder *Search a place…* à 45 %, **petite croix système** visible pendant la frappe seulement ; tableau de résultats ancré sur la boîte (pas de conflit de contraintes). Le marqueur du maintien est un **vrai pin cartographique** (tête ronde + pointe sur le lieu), plus un triangle.
- **Ghost** : icône **verte dans les cellules** quand actif, héros **vert si actif / gris sinon**, switch vert.
- **Création de conteneur** : le conteneur créé **n’est plus sélectionné automatiquement** — il apparaît inactif, on le lance par **tap → « Yes, I'm sure! »**.
- **Conteneur par défaut** : renommé **« Default Container »** (migration de l’ancien « Peter ») et **toujours en haut de la liste**, quel que soit le tri.
- **Anti-crash création de compte** : hook proxy (`NSURLSessionConfiguration`) rendu inerte (`NSNull`/mauvais types = exception fatale au moment de la vérification du pseudo) et **repli `ephemeralSessionConfiguration` si l’original lève** (retourner `nil` planterait `sessionWithConfiguration:`) ; `@try` sur **tous** les hooks `NSLocale` / `NSCalendar` / `preferredLanguages` ; identifiants de locale **validés** (ISO2 + langue 2-3 lettres → repli `en_US` / `en`) ; tags `AppleLanguages` en **BCP-47 strict** (plus d’underscore) ; `setDelegate:` CLLocation **encapsulé** (anti-exception) ; `vm_protect` du rebinding GOT **vérifié** (échec = pas d’écriture → pas de SIGSEGV).
- **UI 100 % anglaise** : les dernières chaînes françaises (Backup & Restore : export/import, mot de passe, *Cancel*) passées par `NWL(...)` → EN / FR / ES à chaud.

---

## Installer

1. Télécharger l'IPA : **[Release `nine9wham`](https://github.com/mpouki04-tech/nine9wham/releases/download/nine9wham/nine9wham_instagram_453.ipa)**
   sha256 : `ad3fcef1d629344f72a0c47785b2efa528fb60ebeed2a5377a7ff1f14f89729e` (338 669 525 octets)
2. Ouvrir **Sideloadly** → sélectionner l'IPA → Install (certificat 7 jours, même Apple ID). Sideloadly est ici **uniquement** l'outil d'installation : aucune licence Blaze/Bumble n'est incluse.
3. Lancer Instagram → le bouton **carré translucide (4 carrés)** apparaît **centré en bas**.

> Après 7 jours : relancer Sideloadly avec la **même Apple ID** → les conteneurs reviennent (vault keychain).

---

## Conteneurs : mode d'emploi

- **Containers → bouton « ＋ New Container »** (rectangle **noir translucide** en bas de l’écran) → feuille **New Container** : nom (bouton *Create* inactif tant que vide), switch *Enable Spoof*, ligne *Spoof Location* (petite icône carte) → **Create** → le conteneur apparaît **inactif** dans la liste (**pas** de sélection automatique, **pas** de redémarrage).
- **Lancer un conteneur** : tap sur la cellule → alerte *« Are you sure you want to switch to the %@ container? Restarting the app is required! »* → *Yes, I'm sure!* → relance.
- **Conteneur par défaut** : nommé **« Default Container »** et **resté en haut** de la liste, quel que soit le tri choisi.
- **Icônes de cellule** : 🛡 Ghost **vert si actif** (menu Ghost complet) · 📍 Location (carte du monde directement) · 🌐 Proxy · **…** → *Rename / Delete Container*.
- **Tri** : **appui long sur `@nine9wham`** (haut du menu) → **Sort by** → Name (A-Z) / Name (Z-A) / Date Newest / Date Oldest.
- **Orbit / Maps** → carte du monde : recherche de lieu (**champ sobre** *Search a place…* : loupe discrète, petite croix seulement pendant la frappe), sélection manuelle, *Current Location*. **Maintien (long-press) sur la carte → pin cartographique posé à l’endroit exact** ; l’adresse s’affiche en bas dans la carte de verre. La barre Standard/Hybrid/Satellite a été retirée.
- **Ghost** → switch *Enable* (coupe les hooks d'empreinte → valeurs réelles), pays préféré, *Formulate*, choix iPhone / Version / Storage / Device Name / Identifiers / Locale / TimeZone, et **en fin de page : Mon Telegram + Version**.
- **Containers** → plus que *Reset everything* (Location Spoofer et Changelog retirés).

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

**Carte** : `NWMapPicker` (`MKMapView`, **flèche au long-press** sur le point exact, recherche Nominatim, géocodage inverse annulé au `dealloc`, nav bar opaque sombre pour des boutons toujours lisibles, carte du bas = adresse seule) — accessible à la création de chaque conteneur et depuis Orbit/Maps.

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
