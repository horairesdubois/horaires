// Essai d’écran, serveur simulé : le back office et l’aperçu côte à côte.
// Lancer : npm i playwright && node tests/apercu-technicien.mjs
import { chromium } from 'playwright';

const ADMIN = { id: 'A1', prenom: 'Back Office', nom: '', role: 'admin', actif: true, demo: false,
  cle: 'a'.repeat(32), matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' };
const DEMO = { id: 'D1', prenom: 'Démo', nom: '', metier: "Compte d'essai", role: 'employe', actif: true, demo: true,
  cle: 'd'.repeat(32), matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' };

const stub = ({ ADMIN, DEMO }) => {
  const rep = o => new Response(JSON.stringify(o), { status: 200, headers: { 'Content-Type': 'application/json' } });
  window.fetch = async (url, opt) => {
    const nom = String(url).split('/rpc/')[1];
    const c = opt && opt.body ? JSON.parse(opt.body) : {};
    if (nom === 'connexion_cle') {
      const e = c.p_cle === DEMO.cle ? DEMO : (c.p_cle === ADMIN.cle ? ADMIN : null);
      return e ? rep({ ok: true, token: 'tok-' + e.id, employe: e })
               : rep({ ok: false, erreur: 'Lien invalide' });
    }
    if (nom === 'admin_donnees') return rep({ ok: true, entreprise: 'Essai', employes: [ADMIN, DEMO],
      pointages: [], msg_non_lus: 0, tracabilite_depuis: '2026-01-01', aujourdhui: '2026-09-07' });
    if (nom === 'mes_pointages') return rep({ ok: true, employe: DEMO, pointages: [] });
    if (nom === 'messages_lire') return rep({ ok: true, messages: [], non_lus: 0, fils: [], fil: null, autres_mois: [] });
    if (nom === 'retards_saisie') return rep({ ok: true, retards: [], aujourdhui: '2026-09-07' });
    return rep({ ok: true });
  };
};

const nav = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
const ctx = await nav.newContext();
await ctx.addInitScript(stub, { ADMIN, DEMO });

// --- le back office, connecté et installé pour de bon ---
const bo = await ctx.newPage();
await bo.addInitScript(({ ADMIN }) => {
  localStorage.setItem('hor_token', 'tok-A1');
  localStorage.setItem('hor_moi', JSON.stringify(ADMIN));
}, { ADMIN });
await bo.goto(new URL('../app/index.html', import.meta.url).href);
await bo.waitForTimeout(900);
console.log('1. back office ouvert            :', await bo.evaluate(() => S.moi && S.moi.prenom));

// Le compte de simulation n’apparaît plus, même si une ancienne API le renvoie.
await bo.evaluate(() => { S.ongletAdmin = 'employes'; renderAdmin(); });
if (await bo.locator('[data-essai]').count()) throw new Error('Accès simulation encore affiché');
if (await bo.locator('#ong-employes').innerText().then(t => t.includes('Démo'))) throw new Error('Compte simulation encore affiché');
if (await bo.evaluate(() => S.employes.some(e => e.demo))) throw new Error('Démo encore dans les données affichées');
console.log('✓ Simulation retirée ; session back office conservée');
await nav.close();
