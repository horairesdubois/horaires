// Garde-fous de la rédaction assistée, sans réseau.
//
// Ce que ces tests vérifient n'est pas que l'IA écrit bien — ça, seul l'usage
// le dira. Ils vérifient qu'une IA qui écrit MAL ne peut pas faire sortir de
// prix faux ni de document déformé. C'est la propriété qu'on doit pouvoir
// garantir à un client, et elle doit tenir même le jour où le modèle déraille.

import assert from "node:assert/strict";
import { test } from "node:test";
import { verrouiller, redigerRelance, TEXTE_MISE_EN_DEMEURE } from "./ia.mjs";
import { construireFacture, calculerTotaux } from "./facture.mjs";

const CATALOGUE = [
  { code: "MO-STD", designation: "Main-d'œuvre, heure ouvrable", unite: "heure", prix: 125.00 },
  { code: "MO-SAM", designation: "Main-d'œuvre, samedi", unite: "heure", prix: 165.00 },
  { code: "DEP-GE", designation: "Déplacement, zone Genève", unite: "forfait", prix: 90.00 }
];
const index = new Map(CATALOGUE.map(p => [p.code, p]));

test("le prix vient du catalogue, pas du modèle", () => {
  const r = verrouiller({
    lignes: [
      // Le modèle tente de dicter un prix : le champ n'existe pas au contrat,
      // et même présent il n'est pas lu.
      { code: "MO-STD", quantite: 2, prixUnitaire: 999, prix: 999, justification: "2 h sur place" }
    ],
    hors_catalogue: [], remarques: ""
  }, index);

  assert.equal(r.lignes.length, 1);
  assert.equal(r.lignes[0].prixUnitaire, 125.00);
  assert.equal(r.lignes[0].designation, "Main-d'œuvre, heure ouvrable");
});

test("un code inventé est refusé, sans repêchage par ressemblance", () => {
  const r = verrouiller({
    lignes: [{ code: "MO-STANDARD", quantite: 2, justification: "" }],
    hors_catalogue: [], remarques: ""
  }, index);

  assert.equal(r.lignes.length, 0);
  assert.equal(r.refusees.length, 1);
  assert.match(r.refusees[0].motif, /absent du catalogue/);
  assert.equal(r.pretAEnvoyer, false);
});

test("les quantités aberrantes sont refusées", () => {
  const r = verrouiller({
    lignes: [
      { code: "MO-STD", quantite: 0, justification: "" },
      { code: "MO-STD", quantite: -3, justification: "" },
      { code: "MO-STD", quantite: 99999, justification: "" },
      { code: "DEP-GE", quantite: "beaucoup", justification: "" },
      { code: "MO-SAM", quantite: 1.5, justification: "ok" }
    ],
    hors_catalogue: [], remarques: ""
  }, index);

  assert.equal(r.lignes.length, 1, "seule la quantité plausible survit");
  assert.equal(r.lignes[0].code, "MO-SAM");
  assert.equal(r.refusees.length, 4);
});

test("une prestation hors catalogue n'est jamais chiffrée par l'IA", () => {
  const r = verrouiller({
    lignes: [{ code: "MO-STD", quantite: 1, justification: "" }],
    hors_catalogue: [{
      designation: "Location nacelle 12 m", unite: "jour", quantite: 1,
      motif: "aucun code de location au catalogue"
    }],
    remarques: "Le prix de la nacelle est à confirmer auprès du loueur."
  }, index);

  assert.equal(r.aValider.length, 1);
  assert.equal(r.aValider[0].prixUnitaire, null, "pas de prix inventé");
  assert.equal(r.pretAEnvoyer, false, "rien ne part tant qu'il reste à trancher");
});

test("une proposition propre est prête à envoyer", () => {
  const r = verrouiller({
    lignes: [
      { code: "MO-SAM", quantite: 2.5, justification: "intervention samedi matin" },
      { code: "DEP-GE", quantite: 1, justification: "déplacement Champel" }
    ],
    hors_catalogue: [], remarques: ""
  }, index);

  assert.equal(r.pretAEnvoyer, true);
  assert.equal(calculerTotaux(r.lignes, 8.1).ht, 502.50);
});

test("la mise en demeure n'est jamais rédigée par l'IA", async () => {
  let appele = false;
  const r = await redigerRelance({
    niveau: 3,
    appelerClaude: async () => { appele = true; return { texte: "n'importe quoi" }; }
  });

  assert.equal(appele, false, "le modèle n'est même pas sollicité");
  assert.equal(r.texte, TEXTE_MISE_EN_DEMEURE);
  assert.equal(r.parIA, false);
});

test("un texte de relance contenant un chiffre est écarté", async () => {
  const r = await redigerRelance({
    niveau: 1,
    appelerClaude: async () => ({ texte: "Votre facture de CHF 531.31 est échue depuis 12 jours." })
  });

  assert.equal(r.parIA, false, "on retombe sur le gabarit fixe");
  assert.match(r.texte, /sans suite/);
  assert.equal(/\d/.test(r.texte), false, "aucun chiffre ne sort du modèle");
});

test("un texte de relance conforme est accepté", async () => {
  const attendu = "Sauf omission de notre part, ce document est resté sans réponse. Nous vous remercions d'y donner suite.";
  const r = await redigerRelance({ niveau: 1, appelerClaude: async () => ({ texte: attendu }) });

  assert.equal(r.parIA, true);
  assert.equal(r.texte, attendu);
});

test("le format du document ne dépend pas de l'origine des lignes", async () => {
  const commun = {
    entreprise: {
      nom: "Hugo Dubois Dépannage Sàrl", adresse: "Rue de Lyon 42", npa: 1203,
      ville: "Genève", iban: "CH44 3199 9123 0008 8901 2",
      tva: "CHE-123.456.789 TVA", email: "facturation@dubois-depannage.ch"
    },
    client: {
      numero: 1047, nom: "Régie Beaulieu SA", adresse: "Av. de Champel 18",
      npa: 1206, ville: "Genève"
    },
    facture: {
      numero: "2026-0142", date: "2026-06-12", echeance: "2026-07-12",
      periode: "12.06.2026", lieu: "Av. de Champel 18", delaiJours: 30
    }
  };

  // Les mêmes lignes, saisies à la main d'un côté, passées par l'IA de l'autre.
  const aLaMain = [
    { designation: "Main-d'œuvre, samedi", unite: "heure", quantite: 2.5, prixUnitaire: 165.00 },
    { designation: "Déplacement, zone Genève", unite: "forfait", quantite: 1, prixUnitaire: 90.00 }
  ];
  const parIA = verrouiller({
    lignes: [
      { code: "MO-SAM", quantite: 2.5, justification: "samedi matin" },
      { code: "DEP-GE", quantite: 1, justification: "Champel" }
    ],
    hors_catalogue: [], remarques: ""
  }, index).lignes;

  const a = await construireFacture({ ...commun, lignes: aLaMain });
  const b = await construireFacture({ ...commun, lignes: parIA });

  assert.equal(a.ttc, b.ttc);
  assert.equal(a.reference, b.reference);
  // Même gabarit, même pagination : le PDF ne diffère que par l'horodatage
  // interne de PDFKit. On compare la taille à l'octet près, à 32 octets près.
  assert.ok(Math.abs(a.pdf.length - b.pdf.length) < 32,
    `taille des PDF trop différente : ${a.pdf.length} vs ${b.pdf.length}`);
});
