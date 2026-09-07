// Essai d’écran, serveur simulé : la bande de jours, les états, la hauteur.
// Lancer : npm i playwright && node tests/ecran-technicien.mjs
import { chromium } from 'playwright';
const SAMI = { id: 'E1', prenom: 'Sami', nom: 'Ferjani', metier: 'Ferblantier', role: 'employe',
  actif: true, demo: false, matin_debut_def: '08:00', matin_fin_def: '12:00',
  apm_debut_def: '13:00', apm_fin_def: '17:00' };
const j = (jour, md, mf, ad, af, o = {}) => ({ id: jour, employe_id: 'E1', jour,
  matin_type: 'travail', matin_debut: md, matin_fin: mf, apm_type: 'travail',
  apm_debut: ad, apm_fin: af, remarque: o.rem || '', approuve: !!o.val, confirme: o.conf !== false,
  saisi_par: 'E1' });
const PTG = [
  j('2026-09-01','08:00','12:00','13:00','17:00',{val:true}),
  j('2026-09-02','08:00','12:00','13:00','17:30',{val:true, rem:'Fin de chantier'}),
  j('2026-09-04','07:00','12:00','13:00','18:00',{conf:false}),   // posée, à confirmer
];
// le 3 manque, le 7 (aujourd'hui) n'est pas saisi

const nav = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const ctx = await nav.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
const pg = await ctx.newPage();
await pg.addInitScript(({ SAMI, PTG }) => {
  localStorage.setItem('hor_token', 'tok'); localStorage.setItem('hor_moi', JSON.stringify(SAMI));
  const rep = o => new Response(JSON.stringify(o), { status: 200, headers: { 'Content-Type': 'application/json' } });
  window.fetch = async (u, o) => {
    const n = String(u).split('/rpc/')[1];
    if (n === 'mes_pointages') return rep({ ok: true, employe: SAMI, pointages: PTG });
    if (n === 'messages_lire') return rep({ ok: true, messages: [], non_lus: 0, fils: [], fil: null, autres_mois: [] });
    return rep({ ok: true });
  };
}, { SAMI, PTG });
await pg.goto('file:///home/user/horaires/docs/index.html');
await pg.waitForTimeout(900);
await pg.evaluate(() => { S.annee = 2026; S.mois = 9; S.auj = '2026-09-07'; renderEmp(); });
await pg.waitForTimeout(400);

const D = '/tmp/claude-0/-home-user-horaires/4c57d827-a9fc-5130-ad81-4346fd29ca84/scratchpad/';
await pg.screenshot({ path: D + 'tech-1.png' });
const h = await pg.evaluate(() => ({
  page: document.documentElement.scrollHeight, fenetre: window.innerHeight,
  jourSel: S.jourSel, etat: document.getElementById('js-etat').textContent,
  date: document.getElementById('js-date').textContent
}));
console.log('hauteur page :', h.page, '· fenêtre :', h.fenetre,
            '→', h.page <= h.fenetre ? 'AUCUN DÉFILEMENT' : 'défile de ' + (h.page - h.fenetre) + 'px');
console.log('jour choisi  :', h.date, '—', h.etat);

// on touche le 4 (posée, à confirmer)
await pg.locator('[data-j="2026-09-04"]').click();
await pg.waitForTimeout(300);
console.log('après appui sur le 4 :', await pg.evaluate(() => document.getElementById('js-date').textContent),
            '—', await pg.evaluate(() => document.getElementById('js-etat').textContent),
            '| bouton :', (await pg.evaluate(() => document.getElementById('btn-pointer').innerText)).replace(/\n/g,' · '));
await pg.screenshot({ path: D + 'tech-2.png' });

// le 3 (manquant)
await pg.locator('[data-j="2026-09-03"]').click();
await pg.waitForTimeout(300);
console.log('après appui sur le 3 :', await pg.evaluate(() => document.getElementById('js-etat').textContent),
            '| bouton :', (await pg.evaluate(() => document.getElementById('btn-pointer').innerText)).replace(/\n/g,' · '));

// le 6 (dimanche)
await pg.locator('[data-j="2026-09-06"]').click();
await pg.waitForTimeout(300);
console.log('après appui sur le 6 :', await pg.evaluate(() => document.getElementById('js-etat').textContent),
            '| bouton caché :', await pg.evaluate(() => document.getElementById('btn-pointer').hidden));

// le détail du mois
await pg.locator('#btn-tout-mois').click();
await pg.waitForTimeout(300);
await pg.screenshot({ path: D + 'tech-3.png', fullPage: true });
console.log('détail du mois ouvert, lignes :', await pg.locator('.jour-ligne').count());
await nav.close();
