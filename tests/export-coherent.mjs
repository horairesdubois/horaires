import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const html=readFileSync(new URL('../app/index.html',import.meta.url),'utf8');
const ctx=vm.createContext({});
const calculs=html.slice(html.indexOf('const parseT ='),html.indexOf('/* Journée normale des employés'));
const regles=html.slice(html.indexOf('const BASE_JOUR_MIN'),html.indexOf('function heuresTexte('));
const exportation=html.slice(html.indexOf('const BORD'),html.indexOf('async function exporterExcel()'));
vm.runInContext(`const esc=s=>String(s??''); const JS_COURT=['dim','lun','mar','mer','jeu','ven','sam']; const aujourdhui=()=> '2026-10-07'; const nomComplet=e=>e.prenom; const fmtJours=n=>String(n)+' j'; var S={annee:2026,mois:9}; var XLSX={utils:{aoa_to_sheet:lignes=>({lignes})}}; ${calculs}\n${regles}\n${exportation}`,ctx);
const pointage=(jour,fin,autres={})=>({jour,matin_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:fin,approuve:true,...autres});
function exporter(p){ctx.p=p;return vm.runInContext(`feuilleEmploye({prenom:'Essai'}, {[p.jour]:p}, [{iso:p.jour,num:Number(p.jour.slice(-2)),js:new Date(p.jour+'T12:00:00').getDay()}], 'septembre 2026')`,ctx);}
let f=exporter(pointage('2026-09-14','19:00'));
assert.equal(f.totPlus,120); assert.equal(f.solde,0); // 10 h le lundi : +2 h affichées, solde 42 h nul
f=exporter(pointage('2026-09-10','19:00'));
assert.equal(f.totPlus,600); assert.equal(f.totCred,480); assert.equal(f.totDues,480); assert.equal(f.solde,600);
f=exporter(pointage('2026-09-10','19:00',{matin_type:'ferie',apm_type:'ferie'}));
assert.equal(f.totPlus,0);assert.equal(f.solde,0); // férié non travaillé : aucun surplus fictif
f=exporter(pointage('2026-09-12','19:00'));
assert.equal(f.totPlus,600);assert.equal(f.solde,600);
f=exporter(pointage('2026-09-15','19:00',{minutes_refusees:120}));
let ligne=f.ws.lignes[6].map(c=>c?.v);
assert.deepEqual(Array.from(ligne.slice(-2)),['8:00','2:00']);
f=exporter(pointage('2026-09-15','19:00',{approuve:false,confirme:true}));
ligne=f.ws.lignes[6].map(c=>c?.v);
assert.deepEqual(Array.from(ligne.slice(-2)),['','']);
assert.match(ligne.at(-3),/attente/);
console.log('✓ Export : heures sup communes à l’application, solde contractuel distinct, férié sans double crédit, décisions partielles et attente préservées');

// Vérification facultative d’un export réel, fourni localement sans données privées dans le dépôt.
if(process.env.HORAIRES_SOURCE_EXPORT){
  const mois=JSON.parse(readFileSync(process.env.HORAIRES_SOURCE_EXPORT,'utf8'));
  let sup=0,travail=0,solde=0;
  for(const m of mois){
    ctx.m=m;
    const f=vm.runInContext(`S.mois=m.mois; var jours=Object.keys(m.pointages).filter(iso=>iso>='2026-08-20'&&iso<='2026-09-20').map(iso=>({iso,num:Number(iso.slice(-2)),js:new Date(iso+'T12:00:00').getDay()})); feuilleEmploye({prenom:'Essai'},m.pointages,jours,'2026')`,ctx);
    sup+=f.totPlus;travail+=f.totMin;solde+=f.solde;
    for(const l of f.ws.lignes){if(/^\d{2}\./.test(l[0]?.v))assert.equal(l.at(-3).v,'Approuvée');}
  }
  assert.equal(sup,3015); assert.equal(travail,13035); assert.equal(solde,2475);
  console.log('✓ Données réelles 20 août–20 septembre : 50h15 sup, 217h15 travaillées, 41h15 de solde contractuel');
}
