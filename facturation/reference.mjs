// Références de paiement suisses.
//
// Deux mondes, à ne pas mélanger — la banque refuse la combinaison inverse :
//   • QR-IBAN (IID 30000–31999) → référence QRR, 27 chiffres.
//   • IBAN ordinaire            → référence SCOR (ISO 11649) ou aucune.
//
// La référence est ce qui rend les relances possibles : sans elle, le camt.054
// de la banque ne dit pas quelle facture a été payée, et on relance des clients
// à jour. C'est l'erreur qui coûte le plus cher en réputation.

import {
  calculateQRReferenceChecksum,
  calculateSCORReferenceChecksum,
  isQRIBAN,
  isIBANValid,
  isQRReferenceValid,
  isSCORReferenceValid
} from "swissqrbill/utils";

/**
 * Référence QRR : 27 chiffres = 26 significatifs + 1 clé de contrôle.
 * Convention retenue : 6 chiffres de numéro client, 10 de numéro de facture,
 * 10 libres (réservés — mis à zéro). Lisible à l'œil sur un extrait bancaire.
 */
export function referenceQRR(noClient, noFacture) {
  const client = String(noClient).replace(/\D/g, "").padStart(6, "0");
  const facture = String(noFacture).replace(/\D/g, "").padStart(10, "0");
  if (client.length > 6) throw new Error("Numéro de client trop long (6 chiffres max)");
  if (facture.length > 10) throw new Error("Numéro de facture trop long (10 chiffres max)");
  const corps = (client + facture).padEnd(26, "0");
  return corps + calculateQRReferenceChecksum(corps);
}

/**
 * Référence SCOR (ISO 11649) — pour un IBAN ordinaire, quand la banque n'a pas
 * encore fourni le QR-IBAN. Fonctionne aussi hors de Suisse.
 */
export function referenceSCOR(noFacture) {
  const corps = String(noFacture).replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  if (corps.length === 0 || corps.length > 21) {
    throw new Error("Référence SCOR : 1 à 21 caractères alphanumériques");
  }
  return "RF" + calculateSCORReferenceChecksum(corps) + corps;
}

/**
 * Choisit la référence qui correspond au compte : c'est le compte qui commande,
 * pas l'inverse. Évite le rejet bancaire silencieux.
 */
export function referencePourCompte(iban, noClient, noFacture) {
  if (!isIBANValid(iban)) throw new Error(`IBAN invalide : ${iban}`);
  return isQRIBAN(iban)
    ? { type: "QRR", reference: referenceQRR(noClient, noFacture) }
    : { type: "SCOR", reference: referenceSCOR(noFacture) };
}

/** Retrouve la facture depuis une référence lue dans un camt.054. */
export function decoderQRR(reference) {
  const nettoye = String(reference).replace(/\s/g, "");
  if (!isQRReferenceValid(nettoye)) return null;
  return {
    noClient: Number(nettoye.slice(0, 6)),
    noFacture: Number(nettoye.slice(6, 16))
  };
}

export { isQRIBAN, isIBANValid, isQRReferenceValid, isSCORReferenceValid };
