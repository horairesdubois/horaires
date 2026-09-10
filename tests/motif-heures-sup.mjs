// Essai d’écran, sans toucher à la production : le serveur est simulé.
// Lancer : npm i playwright && node tests/motif-heures-sup.mjs
import { chromium } from 'playwright';

const ADMIN = { id: 'A1', prenom: 'Back Office', nom: '', role: 'admin', actif: true,
  matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' };
const SAMI = { id: 'E1', prenom: 'Sami', nom: 'Ferjani', role: 'employe', actif: true, metier: 'Ferblantier',
  matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' };

// Le 2 septembre : 10h travaillées, aucune remarque → « heures en plus, sans explication ».
const PTG = [{ id: 'P1', employe_id: 'E1', jour: '2026-09-02',
  matin_type: 'travail', matin_debut: '07:00', matin_fin: '12:00',
  apm_type: 'travail', apm_debut: '13:00', apm_fin: '18:00',
  remarque: '', approuve: false, confirme: true, saisi_par: 'E1' }];

const appels = [];

async function ouvrir(role) {
  const nav = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const ctx = await nav.newContext();
  const pg = await ctx.newPage();
  pg.on('dialog', d => { appels.push({ dialogue: d.message().slice(0, 90) }); d.accept(); });
  await pg.addInitScript(({ role, ADMIN, SAMI, PTG }) => {
    localStorage.setItem('hor_token', '11111111-1111-1111-1111-111111111111');
    localStorage.setItem('hor_moi', JSON.stringify(role === 'admin' ? ADMIN : SAMI));
    window.__appels = [];
    const vrai = window.fetch;
    window.fetch = async (url, opt) => {
      const nom = String(url).split('/rpc/')[1];
      const corps = opt && opt.body ? JSON.parse(opt.body) : {};
      window.__appels.push({ nom, corps });
      const rep = o => new Response(JSON.stringify(o), { status: 200, headers: { 'Content-Type': 'application/json' } });
      if (nom === 'admin_donnees') return rep({ ok: true, entreprise: 'Essai', employes: [ADMIN, SAMI],
        pointages: PTG, msg_non_lus: 0, tracabilite_depuis: '2026-01-01', aujourdhui: '2026-09-07' });
      // Le technicien répond après autorisation de corriger ; une journée
      // confirmée resterait à juste titre en lecture seule.
      if (nom === 'mes_pointages') return rep({ ok: true, employe: SAMI,
        pointages: PTG.map(p => ({ ...p, confirme: false, demande_etat: 'accordee' })) });
      if (nom === 'messages_lire') return rep({ ok: true, messages: window.__msgs || [], non_lus: 0,
        fils: [], fil: corps.p_employe || null, autres_mois: [] });
      if (nom === 'message_ecrire') {
        window.__msgs = [{ id: 'M1', auteur: 'Back Office', auteur_id: 'A1', role: 'admin',
          texte: corps.p_texte, jour: corps.p_jour, quand: '07.09.2026 10:00', modifie: false, automatique: false }];
        return rep({ ok: true });
      }
      if (nom === 'retards_saisie') return rep({ ok: true, retards: [], aujourdhui: '2026-09-07' });
      if (nom === 'marque_lire') return rep({ ok: true });
      if (nom === 'enregistrer_jour') return rep({ ok: true });
      return rep({ ok: true });
    };
  }, { role, ADMIN, SAMI, PTG });
  await pg.goto(new URL('../app/index.html', import.meta.url).href);
  await pg.waitForTimeout(1200);
  return { nav, pg };
}

// ---------- 1. Côté back office : la demande en un bouton ----------
{
  const { nav, pg } = await ouvrir('admin');
  await pg.evaluate(() => { S.annee = 2026; S.mois = 9; renderAdmin(); });
  await pg.waitForTimeout(300);
  await pg.evaluate(() => ouvrirDetails('E1'));
  await pg.waitForTimeout(600);

  const signale = await pg.locator('.rem.sansmotif').first().innerText();
  console.log('1. ligne signalée      :', JSON.stringify(signale.replace(/\s+/g, ' ')));

  await pg.locator('[data-demande]').first().click();
  await pg.waitForTimeout(600);

  const envoi = await pg.evaluate(() => window.__appels.filter(a => a.nom === 'message_ecrire').pop());
  console.log('2. message envoyé      :', envoi ? 'oui' : 'NON');
  if (envoi) {
    console.log('   jour rattaché       :', envoi.corps.p_jour);
    console.log('   destinataire        :', envoi.corps.p_employe);
    console.log('   texte               :', envoi.corps.p_texte.slice(0, 95) + '…');
  }
  const apres = await pg.locator('.rem.demandee, .rem.sansmotif').first().innerText();
  console.log('3. la ligne devient    :', JSON.stringify(apres.replace(/\s+/g, ' ')));
  const modaleOuverte = await pg.locator('#voile-jour.ouvert').count();
  console.log('4. la journée ne s’est PAS ouverte par mégarde :', modaleOuverte === 0 ? 'correct' : 'ÉCHEC');
  await nav.close();
}

// ---------- 2. Côté technicien : la question et l'insistance ----------
{
  const { nav, pg } = await ouvrir('employe');
  await pg.evaluate(() => {
    S.annee = 2026; S.mois = 9;
    S.messages = [{ id: 'M1', auteur: 'Back Office', auteur_id: 'A1', role: 'admin',
      texte: 'Bonjour Sami, peux-tu préciser la raison des 2h00 de plus…', jour: '2026-09-02',
      quand: '07.09.2026 10:00', modifie: false, automatique: false }];
    ouvrirJour('E1', '2026-09-02');
  });
  await pg.waitForTimeout(400);
  const q = await pg.locator('#mj-demande').innerText();
  console.log('\n5. question visible sur la journée :', JSON.stringify(q.replace(/\s+/g, ' ').slice(0, 80)) + '…');
  const alerte = await pg.locator('#mj-sup-alerte').isVisible();
  const txtAlerte = await pg.locator('#mj-sup-alerte').innerText();
  console.log('6. avertissement heures en plus    :', alerte ? JSON.stringify(txtAlerte.replace(/\s+/g,' ')) : 'INVISIBLE');

  // Il écrit l'explication : l'avertissement doit disparaître.
  await pg.locator('#mj-rem').fill('Déplacement Chavannes-de-Bogis');
  await pg.waitForTimeout(200);
  console.log('7. après explication, avertissement :', await pg.locator('#mj-sup-alerte').isVisible() ? 'ENCORE LÀ' : 'disparu');

  // Il l'efface et enregistre : on doit lui demander confirmation.
  await pg.locator('#mj-rem').fill('');
  await pg.waitForTimeout(150);
  appels.length = 0;
  await pg.locator('#mj-save').click();
  await pg.waitForTimeout(600);
  console.log('8. enregistrer sans motif           :', appels.length ? JSON.stringify(appels[0].dialogue) : 'AUCUNE QUESTION POSÉE');
  const enreg = await pg.evaluate(() => window.__appels.filter(a => a.nom === 'enregistrer_jour').length);
  console.log('9. il a pu passer outre             :', enreg > 0 ? 'oui (comme demandé)' : 'NON — bloqué');
  await nav.close();
}
