// Une journée validée n'est plus un cul-de-sac : le technicien demande son
// ouverture avec un motif, le back office accorde ou refuse.
// Lancer : npm i playwright && node tests/demande-deblocage.mjs
import { chromium } from 'playwright';

const A = { id:'A1', prenom:'Back Office', nom:'', role:'admin', actif:true, demo:false,
  matin_debut_def:'08:00', matin_fin_def:'12:00', apm_debut_def:'13:00', apm_fin_def:'17:00' };
const E = { id:'E1', prenom:'Steve', nom:'Carvalho', metier:'Ferblantier', role:'employe',
  actif:true, demo:false, cct:'ferblanterie',
  matin_debut_def:'08:00', matin_fin_def:'12:00', apm_debut_def:'13:00', apm_fin_def:'17:00' };

const jour = (extra = {}) => Object.assign({
  employe_id:'E1', jour:'2026-09-07', matin_type:'travail', matin_debut:'08:00', matin_fin:'12:00',
  apm_type:'travail', apm_debut:'13:00', apm_fin:'18:30', remarque:'', approuve:true,
  approuve_le:'08.09.2026', confirme:true, demande_etat:null, demande_motif:null,
  demande_le:null, demande_reponse:null }, extra);

const nav = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });

async function ecran(qui, ptg) {
  const ctx = await nav.newContext({ viewport:{ width:390, height:844 }, deviceScaleFactor:2,
    isMobile:true, hasTouch:true });
  const pg = await ctx.newPage();
  pg.on('pageerror', e => console.log('  !! ERREUR JS :', e.message));
  pg.on('dialog', d => { pg.__dlg = d.message(); d.accept(); });
  await pg.addInitScript(({ qui, A, E, ptg }) => {
    localStorage.setItem('hor_token','tok');
    localStorage.setItem('hor_moi', JSON.stringify(qui === 'admin' ? A : E));
    const rep = o => new Response(JSON.stringify(o), { status:200, headers:{ 'Content-Type':'application/json' } });
    window.__rpc = [];
    window.fetch = async (u, o) => {
      const n = String(u).split('/rpc/')[1];
      window.__rpc.push({ n, corps: o && o.body ? JSON.parse(o.body) : null });
      if (n === 'admin_donnees') return rep({ ok:true, entreprise:'Essai', employes:[A,E],
        pointages:ptg, msg_non_lus:0, tracabilite_depuis:'2026-01-01', aujourdhui:'2026-09-09' });
      if (n === 'mes_pointages') return rep({ ok:true, employe:E, pointages:ptg });
      if (n === 'messages_lire') return rep({ ok:true, messages:[], non_lus:0, fils:[], fil:null, autres_mois:[] });
      if (n === 'retards_saisie') return rep({ ok:true, retards:[], aujourdhui:'2026-09-09' });
      return rep({ ok:true });
    };
  }, { qui, A, E, ptg });
  await pg.goto(new URL('../app/index.html', import.meta.url).href);
  await pg.waitForTimeout(1000);
  await pg.evaluate(() => { S.annee = 2026; S.mois = 9; S.auj = '2026-09-09'; });
  return pg;
}
const lire = (pg, sel) => pg.evaluate(s => {
  const e = document.querySelector(s);
  return e && e.offsetParent !== null ? e.innerText.replace(/\n+/g, ' | ') : null;
}, sel);

console.log('TECHNICIEN — journée validée, rien de demandé');
let pg = await ecran('emp', [jour()]);
await pg.evaluate(() => ouvrirJour('E1','2026-09-07'));
await pg.waitForTimeout(350);
console.log('  verrou      :', await lire(pg,'#mj-verrou'));
console.log('  enregistrer visible :', await pg.evaluate(()=>!document.getElementById('mj-save').hidden));
console.log('  champ heure verrouillé :', await pg.evaluate(()=>document.getElementById('mj-af').disabled));
await pg.locator('#mj-dem-ouvrir').tap(); await pg.waitForTimeout(200);
console.log('  formulaire ouvert :', await pg.evaluate(()=>!document.getElementById('mj-dem-form').hidden));
await pg.locator('#mj-dem-envoyer').tap(); await pg.waitForTimeout(300);
console.log('  motif vide refusé :', JSON.stringify(pg.__dlg));
await pg.locator('#mj-dem-motif').fill('J’ai oublié 2h de dépannage chez un client le soir');
await pg.locator('#mj-dem-envoyer').tap(); await pg.waitForTimeout(400);
const env = await pg.evaluate(()=>window.__rpc.find(r=>r.n==='demande_modification'));
console.log('  appel envoyé      :', env ? env.corps.p_jour + ' — « ' + env.corps.p_motif.slice(0,40) + '… »' : 'AUCUN');
await pg.context().close();

console.log('\nTECHNICIEN — demande en attente');
pg = await ecran('emp', [jour({ demande_etat:'attente', demande_motif:'Oubli de 2h de dépannage',
  demande_le:'09.09.2026 08:10' })]);
await pg.evaluate(() => ouvrirJour('E1','2026-09-07'));
await pg.waitForTimeout(350);
console.log('  verrou      :', await lire(pg,'#mj-verrou'));
console.log('  bouton demander caché :', await pg.evaluate(()=>document.getElementById('mj-dem-ouvrir').hidden));
await pg.context().close();

console.log('\nTECHNICIEN — demande refusée');
pg = await ecran('emp', [jour({ demande_etat:'refusee', demande_motif:'Oubli',
  demande_reponse:'Le mois est déjà clôturé, on régularisera en octobre' })]);
await pg.evaluate(() => ouvrirJour('E1','2026-09-07'));
await pg.waitForTimeout(350);
console.log('  verrou      :', await lire(pg,'#mj-verrou'));
await pg.context().close();

console.log('\nBACK OFFICE — une demande en attente');
pg = await ecran('admin', [jour({ demande_etat:'attente',
  demande_motif:'Oubli de 2h de dépannage chez un client', demande_le:'09.09.2026 08:10' })]);
await pg.evaluate(() => { S.ongletAdmin='equipe'; renderAdmin(); });
await pg.waitForTimeout(400);
console.log('  bandeau     :', await lire(pg,'.demandes'));
await pg.locator('[data-dem]').tap(); await pg.waitForTimeout(400);
console.log('  fenêtre ouverte sur :', await pg.evaluate(()=>document.getElementById('mj-titre').textContent));
console.log('  encart      :', await lire(pg,'#mj-dem-admin'));
await pg.locator('#mj-dem-rep').fill('D’accord, corrige et je revalide');
await pg.locator('#mj-dem-accorder').tap(); await pg.waitForTimeout(400);
const rep = await pg.evaluate(()=>window.__rpc.find(r=>r.n==='admin_repondre_demande'));
console.log('  appel réponse :', rep ? 'accordé=' + rep.corps.p_accorde + ' — « ' + rep.corps.p_reponse + ' »' : 'AUCUN');
await pg.context().close();

console.log('\nBACK OFFICE — aucune demande : pas de bandeau');
pg = await ecran('admin', [jour()]);
await pg.evaluate(() => { S.ongletAdmin='equipe'; renderAdmin(); });
await pg.waitForTimeout(400);
console.log('  bandeau     :', await lire(pg,'.demandes') || '(absent, correct)');
await pg.context().close();

await nav.close();
