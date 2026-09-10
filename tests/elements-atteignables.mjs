// Essai tactile sur téléphone (390×844, écran tactile, serveur simulé).
// Lancer : npm i playwright && node tests/elements-atteignables.mjs
import { chromium } from 'playwright';
const A={id:'A1',prenom:'Back Office',nom:'',role:'admin',actif:true,demo:false,cle:'a'.repeat(32),
  matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const E={id:'E1',prenom:'Sami',nom:'Ferjani',metier:'Ferblantier',role:'employe',actif:true,demo:false,
  cle:'b'.repeat(32),matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const P=(j,md,mf,ad,af,o)=>({id:j,employe_id:(o&&o.e)||'E1',jour:j,matin_type:'travail',matin_debut:md,
  matin_fin:mf,apm_type:'travail',apm_debut:ad,apm_fin:af,remarque:(o&&o.rem)||'',
  approuve:!!(o&&o.app),confirme:!(o&&o.conf===false),saisi_par:(o&&o.e)||'E1'});
const PTG=[P('2026-09-01','08:00','12:00','13:00','17:00',{app:true}),
           P('2026-09-02','07:00','12:00','13:00','18:00',{}),
           P('2026-09-04','07:30','12:00','13:00','18:30',{conf:false})];
const MSG=[{id:'M1',auteur:'Sami',auteur_id:'E1',role:'employe',texte:'Une question sur mes heures',
  jour:'2026-09-02',quand:'04.09.2026 18:00',modifie:false,automatique:false}];
const JR=[{id:1,acteur_nom:'Sami',acteur_role:'employe',action:'saisie',cible:'02.09.2026',detail:{},
  jour:'lundi 7 septembre',heure:'08:12'}];

// Le contrôle : au centre de chaque élément touchable, qui reçoit réellement le doigt ?
const SONDE = () => {
  const dedans = (a, b) => { for (let n = b; n; n = n.parentElement) if (n === a) return true; return false; };
  // Quand une fenêtre est ouverte, tout ce qui est derrière est couvert : c'est
  // voulu. On ne sonde alors que le contenu de la fenêtre.
  const voile = Array.from(document.querySelectorAll('.voile.ouvert')).pop();
  const racine = voile || document;
  const cibles = Array.from(racine.querySelectorAll(
    'button:not([hidden]), [data-jour], [data-j], [data-dj], [data-demande], [data-lien], [data-essai], .val-jour, .cellule'));
  const mauvais = [];
  for (const el of cibles) {
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) continue;                       // caché : pas notre affaire
    if (getComputedStyle(el).visibility === 'hidden') continue;
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue;
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) continue;   // hors écran
    // Hors de la partie visible d'un conteneur qui défile : on ne peut pas le
    // toucher sans faire défiler d'abord, ce n'est pas un recouvrement.
    let horsDefile = false;
    for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.overflowX === 'auto' || cs.overflowX === 'scroll' ||
          cs.overflowY === 'auto' || cs.overflowY === 'scroll') {
        const rn = n.getBoundingClientRect();
        if (x < rn.left || x > rn.right || y < rn.top || y > rn.bottom) horsDefile = true;
      }
    }
    if (horsDefile) continue;
    const recu = document.elementFromPoint(x, y);
    if (!recu || (recu !== el && !dedans(el, recu))) {
      mauvais.push({ quoi: (el.id || el.className || el.tagName) + ' « ' +
        (el.textContent || '').trim().slice(0, 28) + ' »',
        recouvertPar: recu ? (recu.id || recu.className || recu.tagName) : 'rien',
        taille: Math.round(r.width) + '×' + Math.round(r.height) });
    }
  }
  return mauvais;
};

const nav=await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined});
for (const [nomVue, moi] of [['TECHNICIEN', E], ['BACK OFFICE', A]]) {
  const ctx=await nav.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true});
  const pg=await ctx.newPage();
  await pg.addInitScript(({A,E,PTG,MSG,JR,moi})=>{
   localStorage.setItem('hor_token','tok');localStorage.setItem('hor_moi',JSON.stringify(moi));
   const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
   window.fetch=async u=>{const n=String(u).split('/rpc/')[1];
    if(n==='mes_pointages')return rep({ok:true,employe:E,pointages:PTG});
    if(n==='admin_donnees')return rep({ok:true,entreprise:'Essai',employes:[A,E],pointages:PTG,
      msg_non_lus:1,tracabilite_depuis:'2026-01-01',aujourdhui:'2026-09-07'});
    if(n==='messages_lire')return rep({ok:true,messages:MSG,non_lus:1,
      fils:[{employe_id:'E1',nom:'Sami Ferjani',non_lus:1}],fil:'E1',autres_mois:[{annee:2026,mois:8,non_lus:2}]});
    if(n==='retards_saisie')return rep({ok:true,retards:[{employe_id:'E1',prenom:'Sami',manquants:3,
      dernier:'2026-09-02'}],aujourdhui:'2026-09-07'});
    if(n==='journal_lire')return rep({ok:true,lignes:JR,acteurs:[{id:'E1',nom:'Sami',nb:4},{id:'A1',nom:'BO',nb:9}]});
    return rep({ok:true});};},{A,E,PTG,MSG,JR,moi});
  await pg.goto('file:///home/user/horaires/docs/index.html');
  await pg.waitForTimeout(1200);
  console.log('\n' + nomVue);
  const ecrans = nomVue === 'TECHNICIEN'
    ? [['écran principal', ()=>{S.annee=2026;S.mois=9;S.auj='2026-09-07';S.jourSel='2026-09-07';S.moisDeplie=false;S.qOuvert=false;renderEmp();renderMsgEmp();}],
       ['détail du mois déplié', ()=>{S.moisDeplie=true;renderEmp();}],
       ['questions ouvertes', ()=>{S.moisDeplie=false;S.qOuvert=true;renderEmp();renderMsgEmp();}],
       ['fenêtre de saisie', ()=>{ouvrirJour(S.moi.id,'2026-09-02');}]]
    : [['feuilles de temps', ()=>{S.annee=2026;S.mois=9;S.auj='2026-09-07';S.ongletAdmin='equipe';renderAdmin();}],
       ['revue d’un collaborateur', ()=>{ouvrirDetails('E1');}],
       ['employés', ()=>{fermerDetails();S.ongletAdmin='employes';renderAdmin();}],
       ['exporter', ()=>{S.ongletAdmin='export';renderAdmin();}],
       ['questions', ()=>{S.ongletAdmin='messages';renderAdmin();}],
       ['logs', ()=>{S.ongletAdmin='journal';renderAdmin();}]];
  for (const [nom, prep] of ecrans) {
    await pg.evaluate(prep); await pg.waitForTimeout(600);
    const m = await pg.evaluate(SONDE);
    console.log('  ' + (m.length ? '✗' : '✓') + ' ' + nom.padEnd(26) +
      (m.length ? m.length + ' élément(s) recouvert(s)' : 'tout est atteignable'));
    m.forEach(x => console.log('       ' + x.quoi + '  ← recouvert par ' + x.recouvertPar + '  (' + x.taille + ')'));
  }
  await ctx.close();
}
await nav.close();
