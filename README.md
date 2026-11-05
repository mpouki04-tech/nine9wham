# @nine9wham

**Instagram modifié** — menu flottant, **conteneurs** (téléphones virtuels isolés) et **fake GPS** par conteneur.

> Base : Instagram **454.0.0** propre (`cryptid=0`, aucun dylib injecté) — voir [Choix de la base](#choix-de-la-base).

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

### Vague 5

- **X et chevron réellement touchables** : les `leftSlot` / `rightSlot` de la barre étaient des `UIView` **sans hauteur intrinsèque** dans une stack centrée → hauteur 0 → les boutons 32 × 32 tombaient **hors des `bounds`** et `hitTest` renvoyait `nil` (visibles, mais intouchables). **Fix** : hauteur explicite **44 pt** sur les deux slots.
- **`@nine9wham` centré au point près** : padding de **26 pt** en tête du groupe central (`[pad, badge, titles, lang]`) + contrainte `spacerR.width == spacerL.width` → le couple pastille + titre tombe **exactement** au centre de la barre (sans ce padding, il restait ~17 pt sur la gauche).
- **Instagram se traduit vraiment** : `NWApplySystemLanguage` écrivait `AppleLanguages`/`AppleLocale` dans `NSUserDefaults` **sans redémarrage** → `NSBundle` gardait la localisation figée. **Fix** : écriture **double** (`NSUserDefaults` **+** `CFPreferencesSetAppValue`/`CFPreferencesAppSynchronize`) puis **relance proposée** (0,7 s, avec 6 nouvelles tentatives si une vue est encore présentée) après le choix d’une langue, d’un pays ou d’une locale. États-Unis → Instagram en anglais, et inversement.
- **Crash à la création de compte : preuves, pas de suppositions** — la cause exacte restant à prouver, le **rapporteur** (déjà actif) est désormais consultable : **Support → « Crash log »** (`Documents/nine9wham_crash.log`, nom + raison + pile, écrit en `write()` async-signal-safe, re-affirmé toutes les 2 s). Garde-fous ajoutés : `@try` autour du handler du timer 2 s et de l’ouverture du menu, **vérification de type** de l’état (`fp`/`loc`/`containers`/`ghostOn`), `NWDeliverFake` protégé, 3ᵉ repli réseau `backgroundSessionConfigurationWithIdentifier`, `NWTopVC` qui remonte les vues en cours de *dismissal*.

### Vague 6a — fix d'inscription + base 454

- **Cause du crash à la création de compte identifiée** : ce n'est **pas** le fichier de base — c'est le **sideloading lui-même**. Un IPA décrypté « pur » installé avec un certificat personnel **n'a pas l'entitlement** `com.apple.security.application-groups` → `-[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]` renvoie **nil**, et l'*access group* keychain réel n'est pas celui qu'Instagram demande (`errSecMissingEntitlement`). Instagram plante sur ce `nil` à l'inscription/connexion.
- **Preuve par deux projets indépendants qui fonctionnent** : `IGSideloadFix` (opa334) — *« Fix crash on login when Instagram is installed via sideloading »* — et une **IPA modifiée qui marche**, dont l'`__objc_methname` contient le **hook identique** de `containerURLForSecurityApplicationGroupIdentifier:`.
- **Correctif intégré au `Peter.dylib`** (option « compiler soi-même », sans Theos, fidèle à IGSideloadFix) :
  - **repli 1** — le hook de conteneur de groupe renvoie un **faux conteneur** `Documents/FakeGroupContainers/<gid>` (avec `Library` + `Library/Caches`) au lieu de `nil` ; l'original est conservé s'il répond ;
  - **repli 2** — `accessGroup` de `FBKeychainItemController` / `UICKeyChainStore` (et `FBSDKKeychainStore` si présent) renvoie le **vrai** groupe du certificat, obtenu avec un item bidon posé puis supprimé du keychain ;
  - classes absentes **ignorées** (`FBSDKKeychainStore` n'existe plus en 453/454), tout est sous `@try`, 3 tentatives maximum, `@try` sur chaque hook.
  - `InstagramAppCoreFramework` est **absent** des bases 453/454 (compilé en statique) → le `dlopen` d'IGSideloadFix est inutile ici (vérifié dans le binaire).
- **Base passée de 453.0.0 à 454.0.0** puis **nettoyée** : la base (`com.burbn.instagram_v454.0.0_sideload_clean.ipa`, `cryptid=0`, rpath présent, **aucun dylib**) est vérifiée en local puis téléversée dans la release `base` ; le CI publie désormais `nine9wham_instagram_454.ipa`.
- **Rapporteur de crash toujours actif** : si un plantage subsistait, **Support → « Crash log »** donne le nom, la raison et la pile — envoyez-la moi.

### Vague 6b — langue PAR CONTENEUR + pays → langue/fuseau

- **Langue du téléphone = celle du conteneur, pas du menu.** `NWEffectiveLocale()` est réécrit : il lit **d'abord** la locale du conteneur actif (`fp["locale"]`, ex. `es_ES`) et n'utilise la langue du menu que comme repli. Avant : conteneur Espagne + menu anglais donnait `en_ES` → Instagram ne détectait **jamais** la langue du conteneur. Maintenant chaque conteneur est vu comme un appareil séparé dont la langue est celle de sa locale.
- **Deux chemins de détection MANQUAIENT** et sont maintenant hookés (empreinte complète) : `+[NSLocale autoupdatingCurrentLocale]` (2ᵉ lecture de la « langue du téléphone » par les SDK Meta, avec cache) et `-[NSBundle preferredLocalizations]` (bundle principal uniquement — c'est par là que la langue de l'UI d'Instagram passe). Avant, `currentLocale` + `preferredLanguages` étaient couverts ; avec ces 2 nouveaux, les 4 chemins de détection de langue sont fermés.
- **Le pays choisi suit tout** : nouvelle table de 48 pays `[code, langue, fuseau]` (`NWCountryRows`). Quand un lieu est choisi (goulot `NWApplyLocation` = carte du monde, cellule conteneur, sheet « New Container »), le **nom du pays en fin de label** est reconnu (reverse geocoding Nominatim, ex. *"…, United States"*) → le conteneur adopte **langue + fuseau + locale** du pays (`NWSetContainerLocale` écrit `fp["locale"]` + `fp["tz"]`, persistés). Choisir États-Unis → l'anglais (`en_US`, `America/New_York`) est appliqué au conteneur, immédiat pour l'actif + écrit dans `AppleLanguages`/`AppleLocale` pour le restart.
- **Le menu ne pilote plus la langue du téléphone** : il ne change que l'UI du dashboard (traduits à chaud FR/EN/ES via `NWL`). La langue du téléphone est dérivée du conteneur actif uniquement (règle inchangée : pas d'écriture iOS quand le Ghost est OFF).

### Vague 7 — architecture anti-détection + Device identity

- **Base propre** : `com.burbn.instagram_v454.0.0_sideload_clean.ipa` — les résiduels d'un autre tweak (bundle, dylib, dylib d'injection, framework) ont été retirés de l'archive et les 2 `LC_LOAD_WEAK_DYLIB` réécrits vers `@rpath/Peter.dylib` ; `cryptid=0`, **minOS 15.0**, zéro résidu (strings + Info.plist) — dernier reliquat `CydiaSubstrate.framework` supprimé en vague 7c.
- **Rebinding des images de l'app** : le rebind GOT (`uname` / `sysctl` / `sysctlbyname` + **`SecItemAdd/CopyMatching/Update/Delete`**) parcourt les sections `__got` / `__auth_got` / `__la_symbol_ptr` / `__nl_symbol_ptr` des images **de l'app** (binaire principal + frameworks du bundle), déjà chargées **et** celles chargées ensuite (`_dyld_register_func_for_add_image`), avec exclusion propre de notre image (`dladdr`) et `vm_protect VM_PROT_COPY`. **Le dyld shared cache est exclu** (`/System/`, `/usr/lib`) : rebind des libs système = récursion infinie dans nos hooks → crash instantané (correction vague 7b).
- **Keychain en C** : les appels `SecItem*` faits en C par Instagram passent par des **wrappers** qui réécrivent `kSecAttrAccessGroup` vers le **vrai** groupe du certificat (item bidon → groupe réel) — repli direct vers l'API si pas encore rebindé.
- **Conteneurs v2** : `-[LSBundleProxy groupContainerURLs]` (merge du faux conteneur) et `-[CKEntitlements initWithEntitlementsDict:]` (entitlement `com.apple.security.application-groups` injecté pour CloudKit), en plus du hook `NSFileManager` d'origine.
- **Module « Device identity »** (bouton pill flottant haut-droite + ligne dans Support) : `Real • <ID court>`, `Machine ID` / `No machine ID yet`, **Mask everything & relaunch**, **Roll a new fingerprint**, saisie manuelle ID et machine ID, copie des deux, **Block Apple attestation** (DeviceCheck / App Attest, **Off** par défaut), **Relaunch now**, **Hide button until relaunch**. Les hooks couvrent `getDeviceId` (scan global des classes), `FBFamilyDeviceID`, `instagram.mid` / `com.instagram.device.midheader` (NSUserDefaults, écriture serveur bloquée) et l'IDFV (pin conteneur > valeur d'origine).
- **Safe mode** : *Support → « Disable all tweaks & relaunch »* coupe **tous** les hooks au prochain lancement (seuls le rapporteur de crash et le fix sideload restent actifs) ; l'UI de réactivation propose *Re-enable & relaunch* / *Keep*.
- **`inject_dylib.py` idempotent** : si le `LC_LOAD_WEAK_DYLIB` est déjà présent, le script ne fait rien (rebuild local sûr).

### Vague 7c (build actuel) — démarrage différé : fix du plantage à l'ouverture

- **Cause racine identifiée par analyse reverse de l'IPA de référence (elle démarre)** : notre `__attribute__((constructor))` exécutait **tout synchrone pendant l'init dyld** — I/O keychain `SecItem*`, `dlopen(AdSupport)`, scan global des classes (`objc_copyClassList`), écritures `NSUserDefaults`/`CFPreferences`, enregistrement du rebind GOT et création de fenêtres UIKit. L'IPA de référence, elle, n'a **aucun constructeur C** (section `__mod_init_func` absente de ses dylibs) et diffuse toute son initialisation (`dispatch_after`, notifications d'app) **après** le chargement de dyld.
- **Refonte** : le constructeur ne fait plus que le **rapporteur de crash** (aucune I/O, aucun dlopen, aucune fenêtre pendant le verrou dyld). Tout le reste — sideload fix, Device identity, état, hooks empreinte/GPS, rebind, proxy, overlay — part en `dispatch_async` sur la queue principale via `NWStartTweaks()`, donc avant toute interaction utilisateur ; l'overlay et le bouton sont rattrapés par le timer de 2 s.
- **Base encore plus propre** : le dernier reliquat de l'archive d'origine, `CydiaSubstrate.framework` (4 entrées / 381 999 o), a été retiré → **3669 entrées**, binaire byte-identique (LC `@rpath/Peter.dylib` ×2 conservés), zéro référence à un autre tweak dans les LC ou le contenu.

---

## Installer

1. Télécharger l'IPA : **[Release `nine9wham`](https://github.com/mpouki04-tech/nine9wham/releases/download/nine9wham/nine9wham_instagram_454.ipa)**
   sha256 : `b95a08ef640d15d08ec7484944ec44837ba293e8aefd891befc08856888f0237` (343 771 950 octets)
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

**Méthode d'injection** : `LC_LOAD_WEAK_DYLIB` `@rpath/Peter.dylib` + `LC_RPATH @executable_path/Frameworks` (déjà présent dans la base 454). Aucun `LC_LOAD_DYLIB` fort → l'app démarre même si le dylib manque.

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

La consigne initiale visait une base tierce. La base utilisée est **454.0.0 propre** (`com.burbn.instagram_v454.0.0_sideload_clean.ipa`) :

- `cryptid=0` (déjà décryptée), **minOS 15.0**, aucune modification du binaire d'origine,
- **aucun dylib injecté** : les 2 `LC_LOAD_WEAK_DYLIB` résiduels d'un autre tweak ont été réécrits vers `@rpath/Peter.dylib` (même taille, NUL-pad) et les bundles/dylibs/frameworks tiers retirés de l'archive (dont `CydiaSubstrate.framework`),
- `LC_RPATH @executable_path/Frameworks` **déjà présent** → injection valide sans toucher aux rpaths,
- `CFBundleExecutable=Instagram`, zéro résidu (strings, clés Info.plist).

Résultat : une base saine, sans aucun résidu d'un autre tweak.

> **Contrôles avant publication** : la base est vérifiée en local (`magic MH_MAGIC_64`, `cryptid=0`, rpath présent, aucun `Peter.dylib` déjà injecté) avant d'être téléversée dans la release `base` que le CI télécharge.

---

## Build (CI)

Push sur `main` → GitHub Actions (`macos-14`) :

```
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -O2 -fobjc-arc -dynamiclib -install_name @rpath/Peter.dylib \
  -framework Foundation -framework UIKit -framework CoreLocation -framework Security \
  -framework MapKit -framework CoreGraphics -framework QuartzCore \
  -o Peter.dylib tweak/Peter.m
```

puis : téléchargement de la base (release `base`) → `inject_dylib.py` → copie dans `Frameworks/` → repack → `verify_ipa.py` → **upload en release `nine9wham`**.

---

## Sécurité / licences

- Aucune licence **Bumble** ni **Blaze** n'est incluse : seul le **design** du menu et l'**architecture** des conteneurs/localisation ont été analysés, puis réécrits.
- Tweak inclus : uniquement notre code (`Peter.dylib`). Aucun tweak tiers, aucune bibliothèque injectée, aucune UI étrangère dans l'IPA.


---

## Vague 8 — base refaite depuis l'IPA RyukGram + demarrage auto-diagnostiquant

**Base reconstruite a la source.** La base n'est plus derivee d'une archive
intermediaire : elle est re-extraite de l'IPA de reference
`1697-RyukGram_sideload_v1.5.1_IG454.0.0.ipa` (qui fonctionne), puis **tout
RyukGram est retire** :

- `Frameworks/RyukGram.dylib`, `Frameworks/zxPluginsInject.dylib`,
  `Frameworks/CydiaSubstrate.framework/`, `RyukGram.bundle/`, tous les
  `_CodeSignature/` ;
- les 2 `LC_LOAD_WEAK_DYLIB` d'origine sont re-ecrits **sur place** (meme
  taille, NUL-pad) : `[168] -> @rpath/Peter.dylib`,
  `[169] -> @rpath/NWSupport.dylib` (faible + inexistant = ignore par dyld).
  Il n'y a donc **plus deux references identiques** a `Peter.dylib` ;
- binaire principal inchange par ailleurs (`ncmds=171`, `sizeofcmds=17312`,
  `LC_UUID 4c4c448c...`, `cryptid=0`, minOS 16.3.0).

Base publiee (release `base`) : `com.burbn.instagram_v454.0.0_sideload_clean.ipa`
— **343 479 610 octets**, sha256
`a59bf7503243cca025861d332be161aca4eb47ac2e618cfb7de4bfdb0bd965f6`.

**Constructeur dyld vide.** `NWInit` ne fait plus qu'un
`dispatch_async(main, NWStartTweaks)` : plus aucune API Foundation/UIKit/I-O
pendant le verrou dyld.

**Demarrage par etapes + garde anti-boucle de crash.** Chaque etape est
marquee dans `NSUserDefaults` ; si un lancement meurt, le suivant s'arrete
**avant** l'etape fautive, affiche une alerte « Recovery mode » qui nomme
l'etape, et l'app reste utilisable. Ordre : rapporteur de crash -> **bouton
flottant d'abord** -> sideload fix -> safe mode -> device identity -> etat ->
hooks empreinte/GPS -> rebind GOT -> proxy -> timers.

**Scan `getDeviceId` differe.** L'enumeration de toutes les classes
(`objc_copyClassList` + `class_getInstanceMethod`, tres lourde) ne bloque plus
l'ouverture : elle part 6 s plus tard sur une file d'arriere-plan (etape 9).

### Vague 8b — escalade de la garde + IPA publiee

La garde anti-boucle **escalade** desormais : si un lancement en mode
recuperation echoue encore, l'etape neutralisee descend d'un cran
(`fault - 1`, minimum 1). L'app finit donc **toujours** par atteindre un
demarrage sain, meme si la premiere etape attribuee n'etait pas la bonne.
`NWBuildID` passe a `w8-2` : chaque nouveau dylib re-tente toutes les etapes.

IPA publiee (release `nine9wham`) :
`nine9wham_instagram_454.ipa` — **343 765 757 octets**, sha256
`8620583cd33dec3eead56205c799639ca85b54c883bb1cd9d4b0c73227f48c30`
(digest GitHub identique). Contenu verifie : 3640 entrees, aucun residu
RyukGram/zx/Substrate/FLEX, un seul `LC_LOAD_WEAK_DYLIB` `@rpath/Peter.dylib`
(+ `@rpath/NWSupport.dylib` faible et inexistant, ignore par dyld),
`cryptid=0`, `LC_RPATH @executable_path/Frameworks`, `Peter.dylib` 510 560 o
(minOS 15.0, sdk 17.5). CI : run `42089891033`, succes, **13 warnings**
(identiques a la reference).

### Vague 9 — fin du plantage a ~5 s + identite par conteneur

**Cause du plantage a ~5 s apres l'ouverture.** Le scan global de
`getDeviceId` (`objc_copyClassList` + `class_getInstanceMethod` sur **toutes**
les classes, y compris les classes Swift d'Instagram) forcait la realisation de
toutes les classes d'un coup, 6 s apres le lancement. Remplace par un scan
**incremental** : `class_copyMethodList` (sans realisation), **lots de 100
classes toutes les 45 ms** sur la main queue, `@autoreleasepool` par lot,
`@try` par classe, garde anti-double-installation. Le hook repond d'abord
l'identite du conteneur, donc l'app n'attend plus le scan.

**Identite automatique et etanche par conteneur.**
`NWGenerateFingerprintKeepingLocale` complete toute empreinte existante
(modele, iOS, device ID, machine ID, FDID...) sans toucher a la langue ni au
fuseau du conteneur. La migration s'execute au demarrage
(`NWBootstrapState`) : chaque conteneur obtient son propre telephone, sans
conflit. `NWRollIdentityForContainer` regenere l'appareil d'un conteneur
precis. Le pin global de Device identity (Mask / Enter ID) est desormais
**scopé au conteneur proprietaire** (`nw9.dev.pin.owner`) : un autre conteneur
ne peut plus heriter du device ID / machine ID d'un autre.

**Pays -> langue -> appareil.** `NWMapFollowCountry` ne regenere l'identite
que si le **pays change** (deplacer la carte dans le meme pays ne change pas
l'appareil). Choisir les Etats-Unis donne un appareil **entierement aleatoire**
et applique l'anglais (New York -> anglais, Paris -> francais, Tokyo ->
japonais). `NWSwitchContainer` et `NWBootstrapState` appliquent la langue du
conteneur actif des le demarrage (relance proposee apres bascule).

**UI Device identity comprehensible + noir translucide.** Le bouton flottant
et la carte « Device identity » utilisent un flou `SystemMaterialDark` + voile
noir (alpha 0.38). Deux cartes d'explication (EN/FR/ES) : « How it works » et
« This container » (nom, pays et langue **en toutes lettres**, modele + iOS).
Les items d'origine sont conserves : `Device identity`, `Real • ...`,
`No machine ID yet`, `Mask everything & relaunch`, `Roll a new fingerprint`,
`Enter ID manually...`, `Enter machine ID manually...`, `Copy current ID`,
`Copy machine ID`, `Block Apple attestation: Off`, `Relaunch now`,
`Hide button until relaunch`.

**Listes en noms complets.** « Choose country » et « Choose Language »
affichent « France », « francais », « Japanese — Japan · Asia/Tokyo » au lieu
des codes `fr_FR` / `FR`.

**Garde du scan.** Le scan note son heure de debut (`nw9.scan.start`). Au
lancement suivant, si le rapporteur de crash a ecrit un rapport plus recent
que ce debut, la cause est le scan : **l'etape 9 est sautee** (alerte Recovery
« scan device id ») et, apres 2 crashs constates, le scan reste desactive
(`nw9.scan.off`) jusqu'au prochain build. Un arret manuel de l'app n'ecrit
aucun rapport : pas de fausse detection.

**IPA publiee (release `nine9wham`)** : `nine9wham_instagram_454.ipa` —
**343 771 950 octets**, sha256
`b95a08ef640d15d08ec7484944ec44837ba293e8aefd891befc08856888f0237`
(digest GitHub identique). Contenu verifie : 3640 entrees, un seul
`LC_LOAD_WEAK_DYLIB` `@rpath/Peter.dylib`, `cryptid=0`, rpath
`@executable_path/Frameworks`, `Peter.dylib` **512 528 o** contenant `w9-2`,
aucun residu RyukGram. CI : run `42112979440`, succes, **13 warnings**
(identiques a la reference).
