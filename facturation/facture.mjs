// Facture et rappel suisses, avec section de paiement QR.
//
// Deux règles qui portent tout le module :
//
//   1. Un rappel n'est pas une nouvelle facture. Il reprend le MÊME numéro et
//      la MÊME référence de paiement, sinon le paiement ne se rapproche plus et
//      le client reste relancé après avoir payé.
//   2. Les mentions de l'art. 26 LTVA sont obligatoires : sans le numéro TVA du
//      prestataire, le taux et le montant de TVA, le client ne peut pas déduire
//      son impôt préalable — il redemandera la facture, et paiera plus tard.

import PDFDocument from "pdfkit";
import { SwissQRBill, Table } from "swissqrbill/pdf";
import { formatReference, mm2pt } from "swissqrbill/utils";
import { referencePourCompte } from "./reference.mjs";

const NOIR = "#132b46";
const GRIS = "#5d7186";
const VERT = "#047857";
const LIGNE = "#dde5ea";

const chf = n =>
  n.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, "’");

const jour = d =>
  new Intl.DateTimeFormat("fr-CH", {
    day: "2-digit", month: "2-digit", year: "numeric", timeZone: "Europe/Zurich"
  }).format(d instanceof Date ? d : new Date(d));

/** Totaux TVA incluse, arrondis au centime à chaque étape. */
export function calculerTotaux(lignes, tauxTva) {
  const arrondi = n => Math.round(n * 100) / 100;
  const detail = lignes.map(l => ({
    ...l,
    montant: arrondi(l.quantite * l.prixUnitaire)
  }));
  const ht = arrondi(detail.reduce((s, l) => s + l.montant, 0));
  const tva = arrondi(ht * tauxTva / 100);
  return { detail, ht, tva, ttc: arrondi(ht + tva) };
}

/**
 * Intérêt moratoire à 5 % l'an (art. 104 al. 1 CO), dû dès le lendemain de la
 * mise en demeure. On ne le facture donc pas au premier rappel courtois.
 */
export function interetMoratoire(montant, depuis, jusqua = new Date(), taux = 5) {
  const jours = Math.max(0, Math.floor((new Date(jusqua) - new Date(depuis)) / 86400000));
  return Math.round(montant * (taux / 100) * (jours / 360) * 100) / 100;
}

/**
 * Construit le PDF. `niveau` vaut 0 pour la facture, puis 1, 2, 3 pour les
 * rappels — 3 étant la mise en demeure.
 *
 * @returns {Promise<{pdf: Buffer, reference: string, type: string, ttc: number}>}
 */
export async function construireFacture({
  entreprise,
  client,
  facture,
  lignes,
  tauxTva = 8.1,
  niveau = 0,
  interets = 0,
  langue = "FR"
}) {
  const { type, reference } = referencePourCompte(
    entreprise.iban, client.numero, facture.numero
  );
  const { detail, ht, tva, ttc } = calculerTotaux(lignes, tauxTva);
  const duTotal = Math.round((ttc + interets) * 100) / 100;

  const titres = [
    "Facture",
    "Rappel de paiement",
    "Deuxième rappel",
    "Mise en demeure"
  ];
  const titre = titres[Math.min(niveau, 3)];

  const doc = new PDFDocument({ autoFirstPage: false, size: "A4" });
  const morceaux = [];
  doc.on("data", c => morceaux.push(c));
  const fini = new Promise(r => doc.on("end", r));
  doc.addPage({ margin: 0, size: "A4" });

  const G = mm2pt(20);          // marge gauche
  const D = mm2pt(190);         // bord droit du contenu
  let y = mm2pt(20);

  // ---------------------------------------------------------------- en-tête
  doc.font("Helvetica-Bold").fontSize(15).fillColor(NOIR)
     .text(entreprise.nom, G, y);
  doc.font("Helvetica").fontSize(9).fillColor(GRIS)
     .text(`${entreprise.adresse} · ${entreprise.npa} ${entreprise.ville}`, G, y + mm2pt(7))
     .text(`${entreprise.tva} · ${entreprise.email}`, G, y + mm2pt(11));

  // ------------------------------------------- adresse client (fenêtre droite)
  const yc = mm2pt(48);
  doc.font("Helvetica").fontSize(10).fillColor(NOIR)
     .text(client.nom, mm2pt(115), yc, { width: mm2pt(75) })
     .text(client.adresse, { width: mm2pt(75) })
     .text(`${client.npa} ${client.ville}`, { width: mm2pt(75) });

  // ---------------------------------------------------------------- titre
  y = mm2pt(74);
  doc.font("Helvetica-Bold").fontSize(17).fillColor(niveau >= 2 ? "#b3261e" : NOIR)
     .text(`${titre} ${facture.numero}`, G, y);

  y += mm2pt(11);
  const meta = [
    ["Date", jour(facture.date)],
    ["Échéance", jour(facture.echeance)],
    ["Prestation", facture.periode],
    ["Référence", formatReference(reference)]
  ];
  doc.fontSize(9);
  for (const [k, v] of meta) {
    doc.font("Helvetica").fillColor(GRIS).text(k, G, y, { width: mm2pt(28) });
    doc.font("Helvetica-Bold").fillColor(NOIR).text(v, G + mm2pt(28), y);
    y += mm2pt(4.6);
  }

  if (facture.lieu) {
    doc.font("Helvetica").fontSize(9).fillColor(GRIS)
       .text(`Lieu d'intervention : ${facture.lieu}`, G, y);
    y += mm2pt(6);
  }

  // ---------------------------------------------------------------- lignes
  y += mm2pt(4);
  const table = new Table({
    rows: [
      {
        backgroundColor: "#eaeff2",
        columns: [
          { text: "Désignation", width: mm2pt(88) },
          { text: "Qté", align: "right", width: mm2pt(16) },
          { text: "Unité", width: mm2pt(18) },
          { text: "Prix unit.", align: "right", width: mm2pt(24) },
          { text: "Montant", align: "right", width: mm2pt(24) }
        ],
        fontName: "Helvetica-Bold",
        header: true
      },
      ...detail.map(l => ({
        columns: [
          { text: l.designation, width: mm2pt(88) },
          { text: l.quantite.toFixed(2), align: "right", width: mm2pt(16) },
          { text: l.unite, width: mm2pt(18) },
          { text: chf(l.prixUnitaire), align: "right", width: mm2pt(24) },
          { text: chf(l.montant), align: "right", width: mm2pt(24) }
        ]
      }))
    ],
    borderColor: LIGNE,
    borderWidth: 0.5,
    fontSize: 9,
    padding: 5,
    textColor: NOIR,
    width: mm2pt(170)
  });
  table.attachTo(doc, G, y);
  y = doc.y + mm2pt(4);

  // ---------------------------------------------------------------- totaux
  const totaux = [
    ["Total hors TVA", chf(ht), false],
    [`TVA ${tauxTva.toFixed(1).replace(".", ",")} %`, chf(tva), false]
  ];
  if (interets > 0) totaux.push(["Intérêt moratoire 5 % (art. 104 CO)", chf(interets), false]);
  totaux.push([niveau > 0 ? "Montant encore dû" : "Total à payer", chf(duTotal), true]);

  doc.fontSize(9);
  for (const [k, v, gras] of totaux) {
    doc.font(gras ? "Helvetica-Bold" : "Helvetica")
       .fillColor(gras ? VERT : GRIS)
       .text(k, mm2pt(110), y, { align: "right", width: mm2pt(50) });
    doc.font(gras ? "Helvetica-Bold" : "Helvetica").fillColor(NOIR)
       .text(`CHF ${v}`, mm2pt(162), y, { align: "right", width: mm2pt(28) });
    if (gras) doc.moveTo(mm2pt(110), y - 3).lineTo(D, y - 3)
                 .lineWidth(0.5).strokeColor(LIGNE).stroke();
    y += mm2pt(gras ? 7 : 5);
  }

  // ---------------------------------------------------------------- pied
  const pieds = [
    `Payable dans les ${facture.delaiJours ?? 30} jours, sans escompte.`,
    "Merci de mentionner la référence de paiement figurant sur le bulletin ci-dessous.",
    "",
    "Nous constatons que cette facture est restée impayée à ce jour. Nous vous remercions de la régler sous 10 jours.",
    "Malgré notre rappel, cette facture demeure impayée. Un dernier délai de 10 jours vous est accordé.",
    "Nous vous mettons formellement en demeure de régler ce montant sous 10 jours. À défaut, une poursuite sera engagée sans autre avis, et l'intérêt moratoire de 5 % l'an court dès réception du présent courrier."
  ];
  const texte = niveau === 0
    ? [pieds[0], pieds[1]]
    : [pieds[2 + niveau], `Facture ${facture.numero} du ${jour(facture.date)}, échue le ${jour(facture.echeance)}.`];

  // Le bloc de paiement occupe les 105 derniers millimètres de la page. Le pied
  // s'y adosse à position fixe : un rappel plus bavard qu'une facture ne doit
  // jamais repousser la section QR sur une deuxième page.
  const yPied = Math.max(y, mm2pt(172));
  doc.font("Helvetica").fontSize(8.5).fillColor(niveau >= 3 ? "#b3261e" : GRIS);
  let yt = yPied;
  for (const t of texte.filter(Boolean)) {
    doc.text(t, G, yt, { width: mm2pt(170) });
    yt = doc.y + mm2pt(1.5);
  }

  // ------------------------------------------------------ section paiement QR
  // La norme impose un bloc de paiement noir sur blanc : on réinitialise la
  // couleur, sinon le rouge de la mise en demeure déteint sur le récépissé et
  // la banque peut refuser le bulletin.
  doc.fillColor("#000000").strokeColor("#000000");

  new SwissQRBill({
    amount: duTotal,
    creditor: {
      account: entreprise.iban,
      address: entreprise.adresse,
      city: entreprise.ville,
      country: "CH",
      name: entreprise.nom,
      zip: entreprise.npa
    },
    currency: "CHF",
    debtor: {
      address: client.adresse,
      city: client.ville,
      country: "CH",
      name: client.nom,
      zip: client.npa
    },
    reference
  }, { language: langue }).attachTo(doc, 0, mm2pt(192));

  doc.end();
  await fini;
  return { pdf: Buffer.concat(morceaux), reference, type, ttc: duTotal };
}
