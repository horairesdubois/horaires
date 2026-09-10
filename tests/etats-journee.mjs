// Essai d’écran, serveur simulé : les trois états d’une journée, vus du technicien.
// Lancer : npm i playwright && node tests/etats-journee.mjs
import { chromium } from 'playwright';
const D={id:'D1',prenom:'Démo',nom:'',metier:"Compte d'essai",role:'employe',actif:true,demo:false,
  matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const P=(j,md,mf,ad,af,o)=>({id:j,employe_id:'D1',jour:j,matin_type:'travail',matin_debut:md,matin_fin:mf,
  apm_type:'travail',apm_debut:ad,apm_fin:af,remarque:'',approuve:!!o.app,confirme:o.conf!==false,saisi_par:'D1'});
const PTG=[
  P('2026-09-01','08:00','12:00','13:00','17:00',{app:true}),          // approuvée
  P('2026-09-02','08:00','12:00','13:00','17:30',{}),                  // envoyée, à approuver
  P('2026-09-04','07:00','12:00','13:00','18:00',{conf:false})];       // posée par le back office
const nav=await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined});
const ctx=await nav.newContext({viewport:{width:390,height:844},deviceScaleFactor:2});
const pg=await ctx.newPage();
await pg.addInitScript(({D,PTG})=>{
 localStorage.setItem('hor_token','tok');localStorage.setItem('hor_moi',JSON.stringify(D));
 const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
 window.fetch=async u=>{const n=String(u).split('/rpc/')[1];
  if(n==='mes_pointages')return rep({ok:true,employe:D,pointages:PTG});
  if(n==='messages_lire')return rep({ok:true,messages:[],non_lus:0,fils:[],fil:null,autres_mois:[]});
  return rep({ok:true});};},{D,PTG});
await pg.goto(new URL('../app/index.html', import.meta.url).href);
await pg.waitForTimeout(1000);
const R=new URL('../work/essais/', import.meta.url).pathname;
for (const [jour,nom] of [['2026-09-02','etat-envoye'],['2026-09-01','etat-approuve'],['2026-09-04','etat-confirmer']]) {
  await pg.evaluate(j=>{S.annee=2026;S.mois=9;S.auj='2026-09-07';S.jourSel=j;renderEmp();},jour);
  await pg.waitForTimeout(300);
  const r=await pg.evaluate(()=>({
    pastille:document.getElementById('js-etat').textContent,

    h:document.documentElement.scrollHeight}));
  console.log(nom.padEnd(17), '→', r.pastille);
  if (nom==='etat-envoye') await pg.screenshot({path:R+'etats.png'});
}
console.log('rappel du mois  :', await pg.evaluate(()=>document.getElementById('emp-etat').textContent));
console.log('hauteur         :', await pg.evaluate(()=>document.documentElement.scrollHeight), 'pour 844');
await nav.close();
