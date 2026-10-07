// Exerce le vrai parcours d’export, sans API ni écriture dans les données métier.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import vm from 'node:vm';
const html=readFileSync(new URL('../app/index.html',import.meta.url),'utf8');
const morceau=(a,b)=>html.slice(html.indexOf(a),html.indexOf(b));
const ctx=vm.createContext({});
let xlsx=null;
if(process.env.HORAIRES_MODULE_XLSX){
  const navigateur=vm.createContext({});
  vm.runInContext(readFileSync(process.env.HORAIRES_MODULE_XLSX,'utf8'),navigateur);
  xlsx=navigateur.XLSX;
}
let livre,nom;
ctx.XLSX=xlsx?{...xlsx,writeFile:(wb,n)=>{livre=wb;nom=n;}}:{utils:{
  aoa_to_sheet:lignes=>({lignes}),book_new:()=>({SheetNames:[],Sheets:{}}),
  book_append_sheet:(wb,ws,n)=>{wb.SheetNames.push(n);wb.Sheets[n]=ws;}
},writeFile:(wb,n)=>{livre=wb;nom=n;}};
vm.runInContext(`
const esc=s=>String(s??'');
const MOIS=['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'];
const JS_COURT=['dim','lun','mar','mer','jeu','ven','sam'];
const nomComplet=e=>e.prenom;const fmtJours=n=>String(n)+' j';
${morceau('const parseT =','/* Journée normale des employés')}
${morceau('const BASE_JOUR_MIN','function heuresTexte(')}
${morceau('function joursDuMois(','const aujourdhui =')}
const aujourdhui=()=> '2026-10-07';
var S={annee:2026,mois:9,auj:'2026-09-20',entreprise:'Test',employes:[{id:'E1',prenom:'Test'},{id:'D1',prenom:'Démo',demo:true}],pointages:[]};
${morceau('function ptgMap()','function sessionPerdue()')}
var chargeSeq=1,chargeTerminee=1,attenteModule=null,avis=[];
var bouton={disabled:false,innerHTML:'',textContent:''};
const $=id=>id==='btn-export'?bouton:{querySelectorAll:()=>[{dataset:{id:'E1'}},{dataset:{id:'D1'}}]};
const toast=s=>avis.push(s);const rpc=()=>Promise.resolve({ok:true});
const chargerXLSX=()=>attenteModule||Promise.resolve();
${morceau('function ajouterFeuilleDecisions(','function chargerXLSX(')}
${morceau('const BORD','/* ---------- Initialisation ---------- */')}
`,ctx);
const p=(jour,extra={})=>({employe_id:'E1',jour,matin_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:'19:01',approuve:true,confirme:true,...extra});
ctx.donnees=[p('2026-09-02'),p('2026-09-03',{minutes_refusees:61}),p('2026-09-04',{approuve:false}),p('2026-09-05',{approuve:false,confirme:false}),p('2026-09-06',{minutes_refusees:601}),p('2026-09-07',{matin_debut:null,matin_fin:null,apm_debut:null,apm_fin:null}),p('2026-08-31'),p('2026-09-08',{employe_id:'D1'})];
await vm.runInContext('S.pointages=donnees; exporterExcel()',ctx);
assert.deepEqual(Array.from(livre.SheetNames),['Récapitulatif septembre','Test','Décisions sur les heures']);
assert.match(nom,/2026-09/);
const lignes=n=>xlsx?xlsx.utils.sheet_to_json(livre.Sheets[n],{header:1,defval:''}):livre.Sheets[n].lignes.map(r=>r.map(c=>c&&typeof c==='object'?c.v:c??''));
const detail=lignes('Test'),recap=lignes('Récapitulatif septembre')[5],decisions=lignes('Décisions sur les heures');
const tot=detail.find(r=>r[0]==='TOTAUX DU MOIS');
assert.equal(tot[7],'50:05');assert.equal(recap[3],'50:05');
assert.equal(tot.at(-2),'19:01');assert.equal(recap[21],'19:01');
assert.equal(tot.at(-1),'11:02');assert.equal(recap[22],'11:02');
assert.equal(tot[11],recap[6]);
assert.equal(decisions.length,7);
assert.equal(detail.find(r=>r[0]==='07.09.2026')[7],'0:00');
assert.equal(decisions.find(r=>r[1]==='2026-09-04')[4],'');
assert.equal(decisions.find(r=>r[1]==='2026-09-05')[2],'À confirmer par l’employé');
assert.equal(decisions.find(r=>r[1]==='2026-09-06')[4],'0:00');
// Vraie sérialisation facultative avec le module identique à celui de production.
if(xlsx){
 const bytes=Buffer.from(xlsx.write(livre,{bookType:'xlsx',type:'array'}));
 const relu=xlsx.read(bytes.toString('base64'),{type:'base64'});
 assert.equal(xlsx.utils.sheet_to_json(relu.Sheets.Test,{header:1}).find(r=>r[0]==='TOTAUX DU MOIS')[7],'50:05');
 if(process.env.HORAIRES_SORTIE_XLSX)writeFileSync(process.env.HORAIRES_SORTIE_XLSX,bytes);
}
// Navigation/rafraîchissement en cours : aucun fichier produit.
livre=null;await vm.runInContext('chargeSeq=2; exporterExcel()',ctx);assert.equal(livre,null);
assert.match(vm.runInContext('avis.at(-1)',ctx),/chargement/);
// Navigation durant le chargement asynchrone du module Excel : export annulé.
let finir;ctx.attenteModule=new Promise(r=>{finir=r;});
vm.runInContext('chargeTerminee=chargeSeq',ctx);
const pending=vm.runInContext('exporterExcel()',ctx);
vm.runInContext('S.mois=10;chargeSeq++;chargeTerminee=chargeSeq',ctx);finir();await pending;
assert.equal(livre,null);assert.match(vm.runInContext('avis.at(-1)',ctx),/changé/);
assert.equal(vm.runInContext('bouton.disabled',ctx),false);
console.log('✓ Export intégral : récapitulatif/détail/décisions identiques, démo et hors période exclus, refus total/partiel, attente, zéro et changements de mois');
