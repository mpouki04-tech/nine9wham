// ---------------------------------------------------------------------------
// Variante de DIAGNOSTIC (bisect vague 11) — dylib VOLONTAIREMENT INERTE.
//
// But : isoler le crash au lancement en 1 bit.
//   - si l'IPA "inert" s'ouvre  -> le crash vient du CODE de tweak/Peter.m
//   - si l'IPA "inert" crash    -> le crash est independant de notre code
//                                   (base 449 / emballage Sideloadly)
//
// Ce fichier remplace tweak/Peter.m UNIQUEMENT quand le workflow est lance
// avec `-f variant=inert`. Le build par defaut (variant=full) est
// inchange et continue de compiler tweak/Peter.m.
// ---------------------------------------------------------------------------

#include <stdio.h>

__attribute__((constructor))
static void NWDiagInertInit(void) {
    // Aucun hook, aucun acces Foundation/UIKit, aucune ecriture.
    // Le seul effet est une ligne sur stderr, visible dans le log systeme.
    fprintf(stderr, "[nine9wham-diag] dylib inerte charge (aucun hook pose)\n");
    fflush(stderr);
}
