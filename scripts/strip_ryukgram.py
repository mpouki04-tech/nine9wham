#!/usr/bin/env python3
"""
strip_ryukgram.py - Supprime les residus "RyukGram" des ressources de l'app.

Usage:
    python3 scripts/strip_ryukgram.py <dossier_ipa_decompressee>

Contexte (vague 10-4) : la base de construction (release "base") est une
IPA RyukGram. Le binaire Instagram lui-meme n'en contient AUCUNE occurrence
(verifie sur 394 Mo), mais 4 ressources de l'extension Safari affichent
encore l'ancien nom ("Open in RyukGram"). Ce script remplace chaque
occurrence par "nine9wham" dans les fichiers TEXTE (UTF-8 valide) uniquement.

Garanties:
  - le binaire Instagram et les dylibs ne sont jamais ecrits (un fichier non
    UTF-8 contenant la chaine fait ECHOUER le script, pas etre modifie);
  - re-scan final : le script sort 1 si une occurrence subsiste, ce qui
    stoppe la CI avant publication.

Sortie : 0 si plus aucune occurrence, 1 sinon.
"""
import os
import re
import sys

PAT = re.compile(rb"ryukgram", re.IGNORECASE)


def repl(m):
    # "RYUKGRAM" -> NINE9WHAM, tout le reste -> nine9wham
    return b"NINE9WHAM" if m.group(0).isupper() else b"nine9wham"


def scan(root):
    """Retourne la liste (chemin, donnees) des fichiers contenant la chaine."""
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError as e:
                print("lecture impossible: %s (%s)" % (path, e))
                continue
            if PAT.search(data):
                hits.append((path, data))
    return hits


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print("dossier introuvable: %s" % root)
        return 2

    hits = scan(root)
    total = 0
    for path, data in hits:
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            # Fichier binaire contenant la chaine : on n'y touche PAS.
            print("RESIDU BINAIRE non nettoyable: %s" % path)
            return 1
        n = len(PAT.findall(data))
        with open(path, "wb") as f:
            f.write(PAT.sub(repl, data))
        total += n
        print("nettoye: %s (%d occurrence(s))" % (os.path.relpath(path, root), n))

    reste = scan(root)
    for path, _data in reste:
        print("RESIDU RESTANT: %s" % path)
    if reste:
        return 1
    print("OK: 0 residu RyukGram (%d occurrence(s) remplacee(s))" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
