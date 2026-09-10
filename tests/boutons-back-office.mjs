// Essai tactile sur téléphone (390×844, écran tactile, serveur simulé).
// Lancer : npm i playwright && node tests/boutons-back-office.mjs
import { chromium } from 'playwright';
const A={id:'A1',prenom:'Back Office',nom:'',role:'admin',actif:true,demo:false,cle:'a'.repeat(32),
  matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const E={id:'E1',prenom:'Sami',nom:'Ferjani',metier:'Ferblantier',role:'employe',actif:true,demo:false,
  cle:'b'.repeat(32),matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const PTG=[{id:'p1',employe_id:'E1',jour:'2026-09-02',matin_type:'travail',matin_debut:'07:00',
  matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:'18:00',remarque:'',
  approuve:false,confirme:true,saisi_par:'E1'}];
const MSG=[{id:'M1',auteur:'Sami',auteur_id:'E1',role:'employe',texte:'Une question',jour:null,
  quand:'04.09.2026 18:00',modifie:false,automatique:false}];
const JR=[{id:1,acteur_nom:'Sami Ferjani',acteur_role:'employe',action:'saisie',cible:'02.09.2026',
  detail:{par:'technicien',horaire:'tapé'},jour:'lundi 7 septembre',heure:'08:12'}];

const nav=await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined});
const ctx=await nav.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true});
const pg=await ctx.newPage();
pg.on('pageerror', e=>console.log('  !! ERREUR JS :', e.message));
pg.on('dialog', d=>d.accept());
await pg.addInitScript(({A,E,PTG,MSG,JR})=>{
 localStorage.setItem('hor_token','tok');localStorage.setItem('hor_moi',JSON.stringify(A));
 const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
 window.__rpc=[];
 window.fetch=async (u,o)=>{const n=String(u).split('/rpc/')[1];window.__rpc.push(n);
  if(n==='admin_donnees')return rep({ok:true,entreprise:'Essai',employes:[A,E],pointages:PTG,
    msg_non_lus:1,tracabilite_depuis:'2026-01-01',aujourdhui:'2026-09-07'});
  if(n==='messages_lire')return rep({ok:true,messages:MSG,non_lus:1,
    fils:[{employe_id:'E1',nom:'Sami Ferjani',non_lus:1}],fil:'E1',autres_mois:[]});
  if(n==='retards_saisie')return rep({ok:true,retards:[{employe_id:'E1',prenom:'Sami',
    manquants:3,dernier:'2026-09-02'}],aujourdhui:'2026-09-07'});
  if(n==='journal_lire')return rep({ok:true,lignes:JR,acteurs:[{id:'E1',nom:'Sami',nb:1}]});
  return rep({ok:true});};},{A,E,PTG,MSG,JR});
await pg.goto(new URL('../app/index.html', import.meta.url).href);
await pg.waitForTimeout(1100);

const poser = async (ong) => { await pg.evaluate(o=>{
  ['voile-jour','voile-emp','voile-det'].forEach(v=>document.getElementById(v).classList.remove('ouvert'));
  S.annee=2026;S.mois=9;S.auj='2026-09-07';S.ongletAdmin=o;renderAdmin();},ong);
  await pg.waitForTimeout(400); };
const emp = () => pg.evaluate(()=>({rpc:window.__rpc.length,
  html:document.getElementById('v-admin').innerHTML.length+'|'+S.ongletAdmin+'|'+S.mois,
  modale:['voile-jour','voile-emp','voile-det'].filter(v=>document.getElementById(v)
    .classList.contains('ouvert')).join(',')}));
async function t(nom, sel, ong) {
  if (ong !== undefined) await poser(ong);
  const a = await emp();
  if (!(await pg.locator(sel).count())) return console.log('  ⊘', nom.padEnd(32), 'absent');
  try { await pg.locator(sel).first().tap({timeout:2500}); }
  catch(e){ return console.log('  ✗', nom.padEnd(32), 'INTAPABLE : '+e.message.split('\n')[0].slice(0,50)); }
  await pg.waitForTimeout(450);
  const b = await emp();
  const bouge = b.rpc>a.rpc || b.html!==a.html || b.modale!==a.modale;
  console.log(bouge?'  ✓':'  ✗ MORT', nom.padEnd(32),
    (b.rpc>a.rpc?'+'+(b.rpc-a.rpc)+' appel(s) ':'')+(b.modale!==a.modale?'modale:'+(b.modale||'fermée')+' ':'')+
    (b.html!==a.html&&b.rpc===a.rpc&&b.modale===a.modale?'écran modifié':''));
}
console.log('BACK OFFICE — onglets et navigation');
await t('Onglet Employés','[data-ong="employes"]','equipe');
await t('Onglet Exporter','[data-ong="export"]','equipe');
await t('Onglet Questions','[data-ong="messages"]','equipe');
await t('Onglet Logs','[data-ong="journal"]','equipe');
await t('Onglet Feuilles de temps','[data-ong="equipe"]','journal');
await t('Mois précédent','#adm-prev','equipe');
await t('Mois suivant','#adm-next','equipe');

console.log('\nFeuilles de temps');
await t('Encart « qui a décroché »','[data-retard]','equipe');
await poser('equipe');
await t('Nom d’un collaborateur','.emp-lien');
await poser('equipe');
await t('Une case du calendrier','.cellule');

console.log('\nRevue d’un collaborateur');
await poser('equipe');
await pg.locator('.emp-lien').first().tap(); await pg.waitForTimeout(500);
const dansDet = async (nom, sel) => {
  const a = await emp();
  if(!(await pg.locator(sel).count())) return console.log('  ⊘', nom.padEnd(32),'absent');
  try{ await pg.locator(sel).first().tap({timeout:2500}); }
  catch(e){ return console.log('  ✗', nom.padEnd(32),'INTAPABLE'); }
  await pg.waitForTimeout(450); const b = await emp();
  console.log((b.rpc>a.rpc||b.html!==a.html||b.modale!==a.modale)?'  ✓':'  ✗ MORT', nom.padEnd(32),
    (b.rpc>a.rpc?'+'+(b.rpc-a.rpc)+' appel(s)':'')+(b.modale!==a.modale?' modale:'+(b.modale||'fermée'):''));
};
await dansDet('Coche de validation','.val-jour');
await dansDet('Demander l’explication','[data-demande]');
await dansDet('Une journée de la revue','.jour-ligne');

console.log('\nEmployés, Export, Questions, Logs');
await t('Ajouter un accès','#btn-ajout-emp','employes');
await poser('employes'); await t('Modifier une fiche','[data-id]');
await poser('employes'); await t('Copier le lien','[data-lien]');
await t('Télécharger l’Excel','#btn-export','export');
await t('Enregistrer le nom','#btn-save-entreprise','export');
await t('Fil d’un collaborateur','.fils button','messages');
await poser('messages');
await t('Envoyer un message','#msg-envoyer', undefined);
await t('Filtre 7 jours','[data-jr="7"]','journal');
await poser('journal'); await t('Filtre par personne','.jr-qui button');
await t('Se déconnecter','#btn-sortir-adm','equipe');
await nav.close();
