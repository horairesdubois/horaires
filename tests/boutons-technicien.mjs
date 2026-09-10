// Essai tactile sur téléphone (390×844, écran tactile, serveur simulé).
// Lancer : npm i playwright && node tests/boutons-technicien.mjs
import { chromium } from 'playwright';
const D={id:'D1',prenom:'Démo',nom:'',metier:"Compte d'essai",role:'employe',actif:true,demo:false,
  matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const P=(j,md,mf,ad,af,o)=>({id:j,employe_id:'D1',jour:j,matin_type:'travail',matin_debut:md,matin_fin:mf,
  apm_type:'travail',apm_debut:ad,apm_fin:af,remarque:'',approuve:!!(o&&o.app),
  confirme:!(o&&o.conf===false),saisi_par:'D1'});
const PTG=[P('2026-09-01','08:00','12:00','13:00','17:00',{app:true}),
           P('2026-09-02','08:00','12:00','13:00','17:30',{}),
           P('2026-09-04','07:00','12:00','13:00','18:00',{conf:false})];
const MSG=[{id:'M1',auteur:'Back Office',auteur_id:'A1',role:'admin',texte:'Bonjour',jour:'2026-09-04',
  quand:'07.09.2026 08:00',modifie:false,automatique:false}];

const nav=await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined});
const ctx=await nav.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,
  userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'});
const pg=await ctx.newPage();
pg.on('pageerror', e=>console.log('  !! ERREUR JS :', e.message));
pg.on('dialog', d=>d.accept());
await pg.addInitScript(({D,PTG,MSG})=>{
 localStorage.setItem('hor_token','tok');localStorage.setItem('hor_moi',JSON.stringify(D));
 const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
 window.__rpc=[];
 window.fetch=async (u,o)=>{const n=String(u).split('/rpc/')[1];window.__rpc.push(n);
  if(n==='mes_pointages')return rep({ok:true,employe:D,pointages:PTG});
  if(n==='messages_lire')return rep({ok:true,messages:MSG,non_lus:0,fils:[],fil:null,autres_mois:[]});
  return rep({ok:true});};},{D,PTG,MSG});
await pg.goto(new URL('../app/index.html', import.meta.url).href);
await pg.waitForTimeout(900);

const poser = async () => { await pg.evaluate(()=>{
  ['voile-jour','voile-emp','voile-det'].forEach(v=>document.getElementById(v).classList.remove('ouvert'));
  S.annee=2026;S.mois=9;S.auj='2026-09-07';
  S.jourSel='2026-09-07';S.vueEmp='aujourdhui';S.moisDeplie=false;S.qOuvert=false;renderEmp();renderMsgEmp();});
  await pg.waitForTimeout(250); };

// Signature de l'écran : si rien ne change et qu'aucun appel ne part, le bouton est mort.
const empreinte = () => pg.evaluate(()=>({
  rpc: window.__rpc.length,
  html: document.getElementById('v-emp').innerHTML.length + '|' +
        document.getElementById('js-date').textContent + '|' + S.jourSel + '|' +
        S.mois + '|' + S.moisDeplie + '|' + S.qOuvert + '|' + S.vueEmp,
  modale: ['voile-jour','voile-emp','voile-det'].filter(v=>document.getElementById(v)
            .classList.contains('ouvert')).join(',') }));

async function tester(nom, sel, avant) {
  if (avant) await avant();
  const a = await empreinte();
  const n = await pg.locator(sel).count();
  if (!n) return console.log('  ⊘', nom.padEnd(34), 'absent de l’écran');
  try { await pg.locator(sel).first().tap({ timeout: 2500 }); }
  catch (e) { return console.log('  ✗', nom.padEnd(34), 'INTAPABLE : ' + e.message.split('\n')[0].slice(0,60)); }
  await pg.waitForTimeout(450);
  const b = await empreinte();
  const bouge = b.rpc > a.rpc || b.html !== a.html || b.modale !== a.modale;
  console.log(bouge ? '  ✓' : '  ✗ MORT', nom.padEnd(34),
    (b.rpc > a.rpc ? '+' + (b.rpc - a.rpc) + ' appel(s) ' : '') +
    (b.modale !== a.modale ? 'modale:' + (b.modale||'fermée') + ' ' : '') +
    (b.html !== a.html && b.rpc === a.rpc && b.modale === a.modale ? 'écran modifié' : ''));
}

console.log('ÉCRAN TECHNICIEN');
await poser(); await tester('Enregistrer l’horaire normal', '#btn-pointer');
await poser(); await tester('Corriger l’horaire / absence', '#btn-modifier-jour');
await poser(); await tester('Bande : toucher le 2', '[data-j="2026-09-02"]',
  () => pg.locator('#emp-semaine-prev').tap());
await poser(); await tester('Semaine précédente', '#emp-semaine-prev');
await poser(); await tester('Semaine suivante', '#emp-semaine-next');
await poser(); await tester('Tout saisir', '#btn-remplir', () => pg.locator('#btn-tout-mois').tap());
await poser(); await tester('Détail du mois', '#btn-tout-mois');
await tester('Une ligne du détail', '.jour-ligne');
await poser(); await tester('Ces derniers jours : une ligne', '.dj');
await poser(); await tester('Questions (ouvrir)', '#q-tete');
await tester('Envoyer ma question', '#emp-msg-envoyer', async () => {
  await pg.evaluate(()=>empChangerVue('questions'));
  await pg.waitForTimeout(200);
  await pg.locator('#emp-msg-texte').fill('Essai');
});

console.log('\nFENÊTRE DE SAISIE');
await poser();
await pg.locator('#btn-modifier-jour').tap(); await pg.waitForTimeout(350);
const dansModale = async (nom, sel) => {
  const a = await pg.evaluate(()=>document.querySelector('#voile-jour .modale').innerHTML.length + '|' +
    ['mj-md','mj-mf','mj-ad','mj-af','mj-rem'].map(i=>document.getElementById(i).value).join(','));
  try { await pg.locator(sel).first().tap({timeout:2500}); }
  catch(e){ return console.log('  ✗', nom.padEnd(34), 'INTAPABLE'); }
  await pg.waitForTimeout(300);
  const b = await pg.evaluate(()=>document.querySelector('#voile-jour .modale').innerHTML.length + '|' +
    ['mj-md','mj-mf','mj-ad','mj-af','mj-rem'].map(i=>document.getElementById(i).value).join(','));
  const ouverte = await pg.evaluate(()=>document.getElementById('voile-jour').classList.contains('ouvert'));
  console.log((a!==b||!ouverte)?'  ✓':'  ✗ MORT', nom.padEnd(34),
    (!ouverte?'fenêtre fermée':(a!==b?'champs modifiés':'aucun effet')));
};
// « Journée type » ne se voit que sur une journée qui n'a PAS déjà cet horaire :
// une journée vide est pré-remplie à l'ouverture, l'appui n'y change rien.
await pg.evaluate(()=>{document.getElementById('voile-jour').classList.remove('ouvert');
  S.jourSel='2026-09-04';renderEmp();ouvrirJour(S.moi.id,'2026-09-04');});
await pg.waitForTimeout(350);
console.log('  (le 4 est saisi 07:00–18:00, donc différent de l’horaire type)');
await dansModale('Journée type', '#mj-defaut');
console.log('     champs après appui :', await pg.evaluate(()=>['mj-md','mj-mf','mj-ad','mj-af']
   .map(i=>document.getElementById(i).value).join(' · ')));
await dansModale('+ 1 heure', '#mj-plus1');
await dansModale('⏱ maintenant (matin début)', '.now[data-cible="mj-md"]');
await dansModale('Enregistrer', '#mj-save');
await poser();
await pg.locator('#btn-modifier-jour').tap(); await pg.waitForTimeout(350);
await dansModale('Annuler', '#mj-annuler');
await poser();
// Suppression d'une journée encore modifiable ; les journées confirmées sont
// volontairement verrouillées, ce que vérifie circuit-approbation.mjs.
await pg.evaluate(()=>ouvrirJour(S.moi.id,'2026-09-04')); await pg.waitForTimeout(300);
await dansModale('Supprimer', '#mj-suppr');

console.log('\nDÉCONNEXION');
await poser(); await tester('Se déconnecter', '#btn-sortir-emp');
await nav.close();
