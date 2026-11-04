// La refonte doit reprendre la structure de la maquette tout en conservant
// les parcours réels. Données locales, requêtes externes bloquées.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const LOGO = 'data:image/svg+xml;base64,' + readFileSync(new URL('./fixtures/logo-hugo-dubois.svg', import.meta.url)).toString('base64');
const EMPLOYES = ['Alen', 'Sami', 'Steve'].map((prenom, i) => ({ id: 'E' + (i + 1), prenom,
  nom: 'Essai', metier: 'Dépannage', role: 'employe', actif: true, demo: false,
  matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' }));
const ADMIN = { id: 'A1', prenom: 'Back Office', nom: '', role: 'admin', actif: true, demo: false };
const COMPTA = { id: 'C1', prenom: 'Fiduciaire', nom: '', role: 'compta', actif: true, demo: false };
const POINTAGES = EMPLOYES.flatMap((e, i) => ['2026-08-31', '2026-09-01', '2026-09-07', '2026-09-14', '2026-09-15'].map(jour => ({
  id: e.id + '-' + jour, employe_id: e.id, jour, matin_type: 'travail', matin_debut: '08:00', matin_fin: '12:00',
  apm_type: 'travail', apm_debut: '13:00', apm_fin: i === 1 ? '17:30' : '17:00',
  approuve: jour < '2026-09-14' || i === 2, confirme: jour < '2026-09-15', remarque: '', saisi_par: e.id
})));
const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
const contexts = [];
const erreurs = [];

async function ecran(role, largeur) {
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: largeur < 600 ? 664 : 900 },
    isMobile: largeur < 600, hasTouch: largeur < 600, serviceWorkers: 'block' });
  contexts.push(ctx);
  await ctx.route(/^https?:\/\//, route => route.abort('blockedbyclient'));
  const pg = await ctx.newPage();
  pg.on('pageerror', erreur => erreurs.push(erreur.message));
  pg.on('dialog', dialogue => dialogue.dismiss());
  await pg.clock.install({ time: new Date('2026-09-15T14:32:00+02:00') });
  await pg.addInitScript(({ role, ADMIN, COMPTA, EMPLOYES, POINTAGES, LOGO }) => {
    const moi = role === 'admin' ? ADMIN : role === 'compta' ? COMPTA : EMPLOYES[0];
    localStorage.setItem('hor_token', 'test-' + role);
    localStorage.setItem('hor_moi', JSON.stringify(moi));
    window.__appels = [];
    window.fetch = async (url, options) => {
      const nom = String(url).split('/rpc/')[1];
      if (!nom) throw new Error('Accès hors simulateur interdit');
      const args = JSON.parse(options?.body || '{}');
      window.__appels.push({ nom, args });
      const prefixe = args.p_annee + '-' + String(args.p_mois).padStart(2, '0');
      const pointages = POINTAGES.filter(p => p.jour.startsWith(prefixe));
      let resultat = { ok: true };
      if (nom === 'marque_lire') resultat = { ok: true, entreprise: 'Hugo Dubois', couleur: '#013384', logo: LOGO };
      if (nom === 'mes_pointages') resultat = { ok: true, employe: EMPLOYES[0], pointages: pointages.filter(p => p.employe_id === 'E1') };
      if (nom === 'admin_donnees' || nom === 'compta_donnees') resultat = { ok: true, entreprise: 'Hugo Dubois',
        employes: [ADMIN, ...EMPLOYES, COMPTA], pointages, moi, msg_non_lus: 0,
        tracabilite_depuis: '2026-01-01', aujourdhui: '2026-09-15' };
      if (nom === 'messages_lire') resultat = { ok: true, messages: [], non_lus: 0,
        fils: EMPLOYES.map(e => ({ employe_id: e.id, nom: e.prenom, non_lus: 0 })), fil: 'E1', autres_mois: [] };
      if (nom === 'retards_saisie') resultat = { ok: true, retards: [], aujourdhui: '2026-09-15' };
      if (nom === 'journal_lire') resultat = { ok: true, lignes: [], acteurs: [] };
      return new Response(JSON.stringify(resultat), { status: 200, headers: { 'Content-Type': 'application/json' } });
    };
  }, { role, ADMIN, COMPTA, EMPLOYES, POINTAGES, LOGO });
  await pg.goto(new URL('../app/index.html', import.meta.url).href);
  await pg.locator(role === 'employe' ? '#v-emp' : '#v-admin').waitFor({ state: 'visible' });
  await pg.waitForFunction(() => S.marqueChargee);
  return pg;
}
async function stable(pg, sels, action, n=12){
 const positions=()=>Promise.all(sels.map(s=>pg.locator(s).boundingBox()));
 const avant=await positions();
 for(let i=0;i<n;i++){
  await action();await pg.waitForFunction(()=>chargeSeq===chargeTerminee);
  for(const sel of sels)await pg.locator(sel).waitFor({state:'visible'});
  const apres=await positions();
  for(let j=0;j<sels.length;j++)for(const cle of ['x','y','width','height'])
   assert(Math.abs(avant[j][cle]-apres[j][cle])<1,sels[j]+' '+cle+' varie : '+JSON.stringify({avant:avant[j],apres:apres[j]}));
 }
}
try{
 for(const largeur of [320,390,768,1280,1440]){
  for(const role of ['admin','compta','employe']){
   console.log('Vérification '+role+' '+largeur);
   const pg=await ecran(role,largeur);
   const emp=role==='employe',prefixe=emp?'emp':'adm';
   if(emp){await stable(pg,['#emp-semaine-prev','#emp-semaine-next'],()=>pg.locator('#emp-semaine-prev').click());await pg.locator('#btn-tout-mois').click();}
   const sels=emp?['#emp-prev','#emp-next']:['#adm-prev','#adm-next','#equipe-prev','#equipe-suiv'];
   await stable(pg,sels,async()=>{
    const mois=await pg.locator('#'+prefixe+'-mois-lib').innerText();
    await pg.locator('#'+prefixe+'-prev').click();
    await pg.waitForFunction(({prefixe,mois})=>document.querySelector('#'+prefixe+'-mois-lib').textContent!==mois,{prefixe,mois});
   });
   if(!emp)await stable(pg,sels,()=>pg.locator('#equipe-prev').click());
   if(role==='admin'){
    await pg.evaluate(async()=>{S.annee=2026;S.mois=9;await charger();ouvrirJour('E1','2026-09-14',true);});
    await stable(pg,['#voile-jour [aria-label="Jour précédent"]','#voile-jour [aria-label="Jour suivant"]'],()=>pg.locator('#voile-jour [aria-label="Jour précédent"]').click());
   }
   assert(await pg.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Débordement '+role+' '+largeur);
   await pg.close();
  }
  console.log('Flèches stables : trois rôles, mois et semaines, '+largeur+' px : OK');
 }
 assert.deepEqual(erreurs,[]);
}finally{for(const ctx of contexts)await ctx.close();await navigateur.close();}
