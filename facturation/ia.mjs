// Rédaction assistée : l'IA dirige le contenu, jamais la forme.
//
// LA GARANTIE, EN UNE PHRASE
// Le modèle ne renvoie que des codes de prestation et des quantités. Le prix
// vient du catalogue, dans notre code, après la réponse. La mise en page vient
// de facture.mjs, qui n'a aucun paramètre modifiable par le modèle. Une IA qui
// hallucine un tarif ne peut donc pas le faire sortir de la machine, et une IA
// qui hallucine une mise en page ne peut pas non plus : ni l'un ni l'autre ne
// sont des sorties possibles du contrat.
//
// CE QUI RESTE À L'IA
// Lire un rapport dicté en langage courant et décider quelles lignes le
// traduisent — c'est-à-dire exactement le travail que le back office fait à la
// main aujourd'hui, et qu'il continuera de valider.
//
// appelerClaude est injecté : la logique de sécurité se teste sans réseau.

import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";

const MODELE_REDACTION = "claude-opus-5";   // jugement : devis, argumentaires
const MODELE_VOLUME    = "claude-haiku-4-5"; // mécanique : classement, extraction

const UNITES = ["heure", "forfait", "piece", "metre", "jour", "kilometre"];

// Le schéma est volontairement pauvre : pas de prix, pas de total, pas de
// libellé de mise en page. Ce que le modèle ne peut pas exprimer, il ne peut
// pas le fausser.
const Proposition = z.object({
  lignes: z.array(z.object({
    code: z.string().describe("Code exact d'une prestation du catalogue fourni"),
    quantite: z.number().describe("Nombre d'unités, décimales autorisées"),
    justification: z.string().describe("La phrase du rapport qui justifie cette ligne")
  })),
  hors_catalogue: z.array(z.object({
    designation: z.string(),
    unite: z.enum(UNITES),
    quantite: z.number(),
    motif: z.string().describe("Pourquoi aucune prestation du catalogue ne convient")
  })),
  remarques: z.string().describe("Ce qui manque ou reste ambigu dans le rapport")
});

const SYSTEME = `Tu assistes le back office d'une entreprise de dépannage genevoise.
À partir du rapport d'intervention dicté par le technicien, tu proposes les lignes à facturer.

Règles absolues :
- Tu choisis uniquement des codes présents dans le catalogue fourni. Jamais un code inventé.
- Tu ne donnes aucun prix, aucun total, aucune TVA : ce n'est pas ton rôle et ce serait ignoré.
- Une prestation absente du catalogue va dans hors_catalogue, avec le motif. Ne la force pas dans un code approchant.
- Le temps facturé est celui du rapport, pas une estimation. Si le rapport ne dit pas la durée, ne mets pas de main-d'œuvre et signale-le dans remarques.
- Le déplacement ne se facture qu'une fois par intervention.
- Une majoration samedi, nuit ou dimanche remplace le tarif ordinaire, elle ne s'y ajoute pas.
- Dans le doute, propose moins et explique dans remarques. Une ligne oubliée se rattrape ; une ligne de trop se conteste.`;

/**
 * Traduit un rapport d'intervention en lignes facturables.
 *
 * @returns {Promise<{lignes: Array, aValider: Array, remarques: string, refusees: Array}>}
 */
export async function proposerLignes({
  rapport,
  catalogue,
  contexte = "",
  appelerClaude = appelClaudeReel,
  modele = MODELE_REDACTION
}) {
  if (!Array.isArray(catalogue) || catalogue.length === 0) {
    throw new Error("Catalogue vide : l'IA n'a rien contre quoi s'appuyer");
  }
  const index = new Map(catalogue.map(p => [p.code, p]));

  const proposition = await appelerClaude({
    modele,
    systeme: SYSTEME,
    schema: Proposition,
    message:
      `Catalogue des prestations :\n` +
      catalogue.map(p => `${p.code} — ${p.designation} (${p.unite})`).join("\n") +
      (contexte ? `\n\nContexte :\n${contexte}` : "") +
      `\n\nRapport du technicien :\n${rapport}`
  });

  return verrouiller(proposition, index);
}

/**
 * Le point de contrôle. Tout ce qui sort de l'IA passe ici avant d'exister.
 * Séparé de l'appel réseau pour être testable, et parce que c'est la fonction
 * qu'il faudra relire dans deux ans.
 */
export function verrouiller(proposition, index) {
  const lignes = [];
  const refusees = [];

  for (const l of proposition?.lignes ?? []) {
    const p = index.get(String(l.code ?? "").trim());
    if (!p) {
      // Code inventé : on ne cherche pas le plus ressemblant, on refuse.
      refusees.push({ code: l.code, motif: "code absent du catalogue" });
      continue;
    }
    const q = Number(l.quantite);
    if (!Number.isFinite(q) || q <= 0 || q > 1000) {
      refusees.push({ code: l.code, motif: `quantité invalide (${l.quantite})` });
      continue;
    }
    lignes.push({
      code: p.code,
      designation: p.designation,
      unite: p.unite,
      quantite: Math.round(q * 100) / 100,
      // Le prix vient du catalogue. Ce qu'aurait pu dire le modèle n'est
      // même pas lu : le schéma ne lui permettait pas de le dire.
      prixUnitaire: Number(p.prix),
      justification: String(l.justification ?? "").slice(0, 300)
    });
  }

  const aValider = (proposition?.hors_catalogue ?? []).map(h => ({
    designation: String(h.designation ?? "").slice(0, 120),
    unite: UNITES.includes(h.unite) ? h.unite : "forfait",
    quantite: Number.isFinite(Number(h.quantite)) && Number(h.quantite) > 0
      ? Math.round(Number(h.quantite) * 100) / 100 : 1,
    // Pas de prix : c'est au back office de le poser. Une prestation hors
    // catalogue chiffrée par l'IA, c'est un prix inventé qui part au client.
    prixUnitaire: null,
    motif: String(h.motif ?? "").slice(0, 200)
  }));

  return {
    lignes,
    aValider,
    refusees,
    remarques: String(proposition?.remarques ?? "").slice(0, 600),
    // Un document ne part jamais tout seul s'il reste quelque chose à trancher.
    pretAEnvoyer: lignes.length > 0 && aValider.length === 0 && refusees.length === 0
  };
}

// ---------------------------------------------------------------- relances

// Le texte du niveau 3 a un effet juridique : il constitue le débiteur en
// demeure au sens de l'art. 102 CO et fait courir l'intérêt moratoire. Il est
// figé, mot pour mot, et l'IA ne le voit même pas.
const TEXTE_MISE_EN_DEMEURE =
  "Nous vous mettons formellement en demeure de régler ce montant sous 10 jours. " +
  "À défaut, une poursuite sera engagée sans autre avis, et l'intérêt moratoire " +
  "de 5 % l'an court dès réception du présent courrier.";

const GABARITS = {
  1: "Un rappel courtois, deux phrases maximum. Pas de menace, pas d'excuse.",
  2: "Un rappel ferme mais courtois, deux phrases maximum. Rappelle qu'un premier rappel a été envoyé."
};

/**
 * Rédige le corps d'une relance. Les montants, dates et numéros ne sont jamais
 * demandés au modèle : ils sont réinjectés par nous après coup, dans le PDF.
 * Le modèle n'écrit que la phrase de contexte.
 */
export async function redigerRelance({
  niveau,
  cible = "facture",
  client,
  appelerClaude = appelClaudeReel
}) {
  if (niveau >= 3) return { texte: TEXTE_MISE_EN_DEMEURE, parIA: false };

  const gabarit = GABARITS[niveau];
  if (!gabarit) throw new Error(`Niveau de relance inconnu : ${niveau}`);

  const Texte = z.object({
    texte: z.string().describe("Deux phrases au maximum, en français, sans chiffre ni date")
  });

  const r = await appelerClaude({
    modele: MODELE_VOLUME,
    systeme:
      "Tu rédiges des relances pour une entreprise de dépannage genevoise. " +
      "Tu n'écris jamais de montant, de date, de numéro de facture ou de devis : " +
      "ils sont ajoutés ensuite. Tu ne menaces jamais de poursuite. " +
      "Vouvoiement, ton neutre et professionnel.",
    schema: Texte,
    message: `${gabarit}\nDocument : ${cible === "devis" ? "un devis resté sans réponse" : "une facture échue"}.\nClient : ${client ?? "professionnel"}.`
  });

  // Ceinture et bretelles : si le modèle a glissé un chiffre malgré la consigne,
  // on retombe sur le gabarit fixe plutôt que d'envoyer un montant inventé.
  const texte = String(r?.texte ?? "").trim();
  if (!texte || /\d/.test(texte) || texte.length > 400) {
    return { texte: SECOURS[niveau], parIA: false };
  }
  return { texte, parIA: true };
}

const SECOURS = {
  1: "Sauf erreur de notre part, ce document est resté sans suite à ce jour. Nous vous remercions de bien vouloir y donner suite.",
  2: "Malgré notre précédent rappel, nous n'avons pas eu de retour de votre part. Nous vous remercions de nous répondre dans les meilleurs délais."
};

// ---------------------------------------------------------------- appel réel

/** Appel Claude, sortie structurée stricte. Remplaçable en test. */
async function appelClaudeReel({ modele, systeme, schema, message }) {
  const client = new Anthropic();
  const reponse = await client.messages.parse({
    model: modele,
    max_tokens: 16000,
    system: systeme,
    thinking: { type: "adaptive" },
    messages: [{ role: "user", content: message }],
    output_config: { format: zodOutputFormat(schema) }
  });
  if (reponse.stop_reason === "refusal") {
    throw new Error("Requête refusée par le modèle");
  }
  return reponse.parsed_output;
}

export { TEXTE_MISE_EN_DEMEURE, MODELE_REDACTION, MODELE_VOLUME };
