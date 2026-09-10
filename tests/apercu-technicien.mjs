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

// --- il ouvre l'aperçu depuis l'onglet Employés ---
await bo.evaluate(() => { S.ongletAdmin = 'employes'; renderAdmin(); });
await bo.waitForTimeout(300);
const btn = bo.locator('[data-essai]');
console.log('2. bouton « Ouvrir » présent     :', await btn.count() === 1 ? 'oui' : 'NON');
console.log('   libellé                       :', (await btn.innerText()).trim());

const [apercu] = await Promise.all([ctx.waitForEvent('page'), btn.click()]);
await apercu.waitForLoadState();
await apercu.waitForTimeout(1200);
console.log('3. l’aperçu affiche              :', await apercu.evaluate(() => S.moi && S.moi.prenom),
            '(vue technicien :', await apercu.evaluate(() => !document.getElementById('v-emp').hidden), ')');

// --- où chaque session s'est installée ---
const ouEst = p => p.evaluate(() => ({
  session: !!sessionStorage.getItem('hor_token'),
  navigateur: localStorage.getItem('hor_token')
}));
console.log('4. aperçu   → sessionStorage :', (await ouEst(apercu)).session,
            '| localStorage :', (await ouEst(apercu)).navigateur);
console.log('5. back office → localStorage :', (await ouEst(bo)).navigateur);

// --- le back office est-il resté lui-même ? ---
await bo.reload();
await bo.waitForTimeout(900);
console.log('6. après rechargement, le back office est toujours :',
            await bo.evaluate(() => S.moi && S.moi.prenom));

// --- se déconnecter de l'aperçu ne doit rien casser à côté ---
await apercu.evaluate(() => deconnexion());
await apercu.waitForTimeout(600);
console.log('7. aperçu déconnecté             : sessionStorage vidé =',
            await apercu.evaluate(() => !sessionStorage.getItem('hor_token')));
console.log('   le back office garde sa clé   :', (await ouEst(bo)).navigateur);
await bo.reload();
await bo.waitForTimeout(900);
console.log('8. et il est toujours connecté   :', await bo.evaluate(() => S.moi && S.moi.prenom));

// --- coller le lien dans un onglet neuf où traîne la session admin ---
// 9. lien d'aperçu collé à la main : il s'annonce, donc aucune question
const colle = await ctx.newPage();
await colle.goto(new URL('../app/index.html', import.meta.url).href + '#c=' + DEMO.cle + '&apercu=1');
await colle.waitForTimeout(1200);
console.log('9. lien d’aperçu collé → on obtient :', await colle.evaluate(() => S.moi && S.moi.prenom));
console.log('   et le back office n’a pas bougé  :', (await ouEst(bo)).navigateur);

// 10. lien d'un VRAI technicien, sur un appareil où le back office est ouvert :
//     on doit être prévenu avant d'être délogé.
const vrai = await ctx.newPage();
let question = null;
vrai.on('dialog', d => { question = d.message(); d.dismiss(); });   // on refuse
await vrai.goto(new URL('../app/index.html', import.meta.url).href + '#c=' + ADMIN.cle);
await vrai.waitForTimeout(1200);
console.log('10. lien d’un vrai compte → question posée :', question ? JSON.stringify(question.replace(/\n+/g,' ')) : 'AUCUNE');
console.log('    refusée → on reste sur             :', await vrai.evaluate(() => S.moi && S.moi.prenom));
console.log('    et la session du navigateur tient  :', (await ouEst(bo)).navigateur);

await nav.close();
