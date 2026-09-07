// Essai tactile sur téléphone (390×844, écran tactile, serveur simulé).
// Lancer : npm i playwright && node tests/boutons-back-office-details.mjs
import { chromium } from 'playwright';
const A={id:'A1',prenom:'Back Office',nom:'',role:'admin',actif:true,demo:false,cle:'a'.repeat(32),
  matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const E={id:'E1',prenom:'Sami',nom:'Ferjani',metier:'Ferblantier',role:'employe',actif:true,demo:false,
  cle:'b'.repeat(32),matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const PTG=[{id:'p1',employe_id:'E1',jour:'2026-09-02',matin_type:'travail',matin_debut:'07:00',
  matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:'18:00',remarque:'',
  approuve:false,confirme:true,saisi_par:'E1'}];
const JR=[{id:1,acteur_nom:'Sami',acteur_role:'employe',action:'saisie',cible:'02.09.2026',
  detail:{},jour:'lundi 7 septembre',heure:'08:12'}];
const ACT=[{id:'E1',nom:'Sami',nb:4},{id:'A1',nom:'Back Office',nb:9}];

const nav=await chromium.launch({executablePath:'/opt/pw-browsers/chromium-1194/chrome-linux/chrome'});
const ctx=await nav.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true,
  permissions:['clipboard-read','clipboard-write']});
const pg=await ctx.newPage();
pg.on('pageerror', e=>console.log('  !! ERREUR JS :', e.message));
const dialogues=[];
pg.on('dialog', d=>{dialogues.push(d.type()+': '+d.message().slice(0,60)); d.accept();});
await pg.addInitScript(({A,E,PTG,JR,ACT})=>{
 localStorage.setItem('hor_token','tok');localStorage.setItem('hor_moi',JSON.stringify(A));
 const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
 window.__rpc=[];window.__corps=[];
 window.fetch=async (u,o)=>{const n=String(u).split('/rpc/')[1];window.__rpc.push(n);
  if(o&&o.body)window.__corps.push({n,c:JSON.parse(o.body)});
  if(n==='admin_donnees')return rep({ok:true,entreprise:'Essai',employes:[A,E],pointages:PTG,
    msg_non_lus:0,tracabilite_depuis:'2026-01-01',aujourdhui:'2026-09-07'});
  if(n==='messages_lire')return rep({ok:true,messages:[],non_lus:0,
    fils:[{employe_id:'E1',nom:'Sami Ferjani',non_lus:0}],fil:'E1',autres_mois:[]});
  if(n==='retards_saisie')return rep({ok:true,retards:[],aujourdhui:'2026-09-07'});
  if(n==='journal_lire')return rep({ok:true,lignes:JR,acteurs:ACT});
  return rep({ok:true});};},{A,E,PTG,JR,ACT});
await pg.goto('file:///home/user/horaires/docs/index.html');
await pg.waitForTimeout(1100);
const poser = async (o) => { await pg.evaluate(x=>{
  ['voile-jour','voile-emp','voile-det'].forEach(v=>document.getElementById(v).classList.remove('ouvert'));
  S.annee=2026;S.mois=9;S.auj='2026-09-07';S.ongletAdmin=x;S.jrQui=null;renderAdmin();},o);
  await pg.waitForTimeout(450); };

console.log('LES CINQ CAS REPRIS ISOLÉMENT');

// 1. « Demander l'explication » ne doit PAS ouvrir la journée
await poser('equipe');
await pg.evaluate(()=>ouvrirDetails('E1')); await pg.waitForTimeout(600);
const n1 = await pg.locator('[data-demande]').count();
if (!n1) console.log('  ⊘ Demander l’explication        pas de journée signalée dans ce jeu d’essai');
else { await pg.evaluate(()=>{window.__rpc=[];});
  await pg.locator('[data-demande]').first().tap();
  await pg.waitForTimeout(700);
  const r = await pg.evaluate(()=>({rpc:window.__rpc,
    jourOuverte:document.getElementById('voile-jour').classList.contains('ouvert')}));
  console.log((r.rpc.includes('message_ecrire') && !r.jourOuverte) ? '  ✓' : '  ✗',
    'Demander l’explication'.padEnd(32), 'message parti:'+r.rpc.includes('message_ecrire'),
    '| journée ouverte par erreur:', r.jourOuverte); }

// 2. Une journée de la revue ouvre bien la fenêtre de saisie
await poser('equipe');
await pg.evaluate(()=>ouvrirDetails('E1')); await pg.waitForTimeout(600);
await pg.locator('#det-liste .jour-ligne').first().tap(); await pg.waitForTimeout(500);
console.log((await pg.evaluate(()=>document.getElementById('voile-jour').classList.contains('ouvert')))
  ? '  ✓' : '  ✗ MORT', 'Une journée de la revue'.padEnd(32), 'ouvre la fenêtre de saisie');

// 3. Copier le lien : rien ne bouge à l'écran, mais le lien part quelque part
await poser('employes');
dialogues.length = 0;
const presse = await pg.evaluate(async () => {
  const b = document.querySelector('[data-lien]');
  b.click();
  await new Promise(r=>setTimeout(r,400));
  try { return await navigator.clipboard.readText(); } catch(e){ return 'lecture impossible'; }
});
console.log((presse.includes('#c=') || dialogues.length) ? '  ✓' : '  ✗ MORT',
  'Copier le lien'.padEnd(32), presse.includes('#c=') ? 'lien dans le presse-papiers' : ('boîte: '+dialogues.join('')));

// 4. Envoyer un message, le champ rempli
await poser('messages');
await pg.locator('#msg-texte').fill('Essai depuis le téléphone');
await pg.evaluate(()=>{window.__rpc=[];window.__corps=[];});
await pg.locator('#msg-envoyer').tap(); await pg.waitForTimeout(700);
const env = await pg.evaluate(()=>window.__corps.filter(x=>x.n==='message_ecrire'));
console.log(env.length ? '  ✓' : '  ✗ MORT', 'Envoyer un message'.padEnd(32),
  env.length ? 'texte transmis : '+JSON.stringify(env[0].c.p_texte) : 'rien ne part');

// 5. Filtre par personne, avec deux acteurs
await poser('journal');
await pg.waitForTimeout(500);
const n5 = await pg.locator('.jr-qui button').count();
if (!n5) console.log('  ✗ Filtre par personne            absent malgré deux acteurs');
else { await pg.evaluate(()=>{window.__rpc=[];});
  await pg.locator('.jr-qui button').nth(1).tap(); await pg.waitForTimeout(600);
  const r = await pg.evaluate(()=>({rpc:window.__rpc, qui:S.jrQui}));
  console.log(r.rpc.includes('journal_lire') ? '  ✓' : '  ✗ MORT',
    'Filtre par personne'.padEnd(32), 'filtre posé sur '+r.qui); }
await nav.close();
