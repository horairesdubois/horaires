// Démonstration : une facture et sa mise en demeure, à partir des mêmes données.
// node demo.mjs   →   facture-2026-0142.pdf  et  mise-en-demeure-2026-0142.pdf

import { writeFile } from "node:fs/promises";
import { construireFacture, interetMoratoire, calculerTotaux } from "./facture.mjs";

// QR-IBAN de test (IID 31999) — à remplacer par celui de votre banque.
const entreprise = {
  nom: "Hugo Dubois Dépannage Sàrl",
  adresse: "Rue de Lyon 42",
  npa: 1203,
  ville: "Genève",
  iban: "CH44 3199 9123 0008 8901 2",
  tva: "CHE-123.456.789 TVA",
  email: "facturation@dubois-depannage.ch"
};

const client = {
  numero: 1047,
  nom: "Régie Beaulieu SA",
  adresse: "Avenue de Champel 18",
  npa: 1206,
  ville: "Genève"
};

const lignes = [
  { designation: "Dépannage sanitaire — fuite colonne montante", quantite: 2.5, unite: "heure", prixUnitaire: 125.00 },
  { designation: "Déplacement urgence, zone Genève", quantite: 1, unite: "forfait", prixUnitaire: 90.00 },
  { designation: "Joint torique 32 mm + collier de serrage inox", quantite: 2, unite: "pièce", prixUnitaire: 14.50 },
  { designation: "Majoration intervention hors horaire (samedi)", quantite: 1, unite: "forfait", prixUnitaire: 60.00 }
];

const facture = {
  numero: "2026-0142",
  date: "2026-06-12",
  echeance: "2026-07-12",
  periode: "12.06.2026",
  lieu: "Avenue de Champel 18, 1206 Genève — 3e étage",
  delaiJours: 30
};

const { ttc } = calculerTotaux(lignes, 8.1);

// 1. La facture
const f = await construireFacture({ entreprise, client, facture, lignes });
await writeFile(`facture-${facture.numero}.pdf`, f.pdf);

// 2. La mise en demeure, 62 jours après l'échéance — même numéro, même référence
const interets = interetMoratoire(ttc, facture.echeance, "2026-09-12");
const m = await construireFacture({
  entreprise, client, facture, lignes, niveau: 3, interets
});
await writeFile(`mise-en-demeure-${facture.numero}.pdf`, m.pdf);

console.log(`Référence de paiement  ${f.reference}  (type ${f.type})`);
console.log(`Facture                CHF ${ttc.toFixed(2)}`);
console.log(`Intérêt moratoire      CHF ${interets.toFixed(2)}  (5 % l'an, 62 jours)`);
console.log(`Mise en demeure        CHF ${m.ttc.toFixed(2)}`);
console.log(`\nLa référence est identique sur les deux documents : le paiement se rapproche quand même.`);
