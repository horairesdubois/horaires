// Essai d’écran, serveur simulé : raccourcis d’heures et avertissement.
// Lancer : npm i playwright && node tests/raccourcis-heures.mjs
import { chromium } from 'playwright';
const SAMI = { id: 'E1', prenom: 'Sami', nom: 'F', role: 'employe', actif: true, demo: false,
  matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' };

const nav = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const ctx = await nav.newContext();
const pg = await ctx.newPage();
const dialogues = [];
pg.on('dialog', d => { dialogues.push(d.message()); d.dismiss(); });   // on refuse : on veut voir la question
await pg.addInitScript(({ SAMI }) => {
  localStorage.setItem('hor_token', 'tok'); localStorage.setItem('hor_moi', JSON.stringify(SAMI));
  const rep = o => new Response(JSON.stringify(o), { status: 200, headers: { 'Content-Type': 'application/json' } });
  window.__appels = [];
  window.fetch = async (u, o) => {
    const n = String(u).split('/rpc/')[1];
    window.__appels.push(n);
    if (n === 'mes_pointages') return rep({ ok: true, employe: SAMI, pointages: [] });
    if (n === 'messages_lire') return rep({ ok: true, messages: [], non_lus: 0, fils: [], fil: null, autres_mois: [] });
    return rep({ ok: true });
  };
}, { SAMI });
await pg.goto('file:///home/user/horaires/docs/index.html');
await pg.waitForTimeout(900);

await pg.evaluate(() => { S.annee = 2026; S.mois = 9; ouvrirJour('E1', '2026-09-02'); });
await pg.waitForTimeout(300);

const lire = () => pg.evaluate(() => ({
  md: document.getElementById('mj-md').value, mf: document.getElementById('mj-mf').value,
  ad: document.getElementById('mj-ad').value, af: document.getElementById('mj-af').value,
  total: document.getElementById('mj-total').textContent,
  alerte: document.getElementById('mj-sup-alerte').style.display === 'block'
    ? document.getElementById('mj-sup-alerte').textContent : null
}));

console.log('1. journée type proposée :', JSON.stringify(await lire()));

await pg.locator('#mj-plus1').click();
console.log('2. après « + 1 heure »   :', JSON.stringify(await lire()));

await pg.locator('#mj-plus1').click();
console.log('3. une seconde fois      :', JSON.stringify(await lire()));

// L'après-midi devient une absence : le raccourci doit viser le matin.
await pg.selectOption('#mj-statut-a', 'vacances');
await pg.waitForTimeout(200);
await pg.locator('#mj-plus1').click();
const apres = await lire();
console.log('4. après-midi en vacances, « + 1 heure » vise le matin :', apres.mf, '(après-midi :', apres.af + ')');

// Les deux demi-journées absentes : plus de raccourci à montrer.
await pg.selectOption('#mj-statut-m', 'vacances');
await pg.waitForTimeout(200);
console.log('5. journée entièrement absente, « + 1 heure » caché :',
  await pg.evaluate(() => document.getElementById('mj-plus1').hidden));

// Retour au travail, et on enregistre sans motif pour voir le texte exact.
await pg.selectOption('#mj-statut-m', 'travail');
await pg.selectOption('#mj-statut-a', 'travail');
await pg.waitForTimeout(200);
await pg.evaluate(() => { document.getElementById('mj-af').value = '19:00'; majTotalApercu(); });
await pg.waitForTimeout(200);
console.log('6. avertissement :', JSON.stringify((await lire()).alerte));
dialogues.length = 0;
await pg.locator('#mj-save').click();
await pg.waitForTimeout(500);
console.log('7. question à l’enregistrement :', JSON.stringify(dialogues[0] || 'AUCUNE'));
await nav.close();
