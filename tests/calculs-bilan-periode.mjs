import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const html=readFileSync(new URL('../app/index.html',import.meta.url),'utf8');
const ctx=vm.createContext({});
const calculs=html.slice(html.indexOf('const parseT ='),html.indexOf('/* Journée normale des employés'));
const regles=html.slice(html.indexOf('const BASE_JOUR_MIN'),html.indexOf('function heuresTexte('));
const exportation=html.slice(html.indexOf('const BORD'),html.indexOf('async function exporterExcel()'));
const periode=html.slice(html.indexOf('function joursBilanPeriode('),html.indexOf('const DET ='));
vm.runInContext(`const esc=s=>String(s??''); const JS_COURT=['dim','lun','mar','mer','jeu','ven','sam']; const aujourdhui=()=> '2026-10-13'; const nomComplet=e=>e.prenom; const fmtJours=n=>String(n)+' j'; var S={annee:2026,mois:9,auj:'2026-10-13'}; var XLSX={utils:{aoa_to_sheet:lignes=>({lignes})}}; ${calculs}\n${regles}\n${exportation}\n${periode}`,ctx);
const jour=(date,fin='17:00',extra={})=>({jour:date,matin_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:fin,approuve:true,...extra});
function bilan(lignes,debut,fin,auj='2026-10-13'){ctx.entree={lignes,debut,fin,auj};return vm.runInContext('calculerBilanPeriode(entree.lignes,entree.debut,entree.fin,entree.auj)',ctx);}
let b=bilan([jour('2026-08-20','23:00'),jour('2026-08-21','19:00'),jour('2026-09-20','17:00'),jour('2026-09-21','23:00')],'2026-08-21','2026-09-20');
assert.equal(b.jours.length,31);assert.equal(b.travail,1080);assert.equal(b.sup,600);assert.equal(b.dues,10080);assert.equal(b.solde,-9000);assert.equal(b.manquants,19);
b=bilan([jour('2026-09-14','19:00')],'2026-09-14','2026-09-14');
assert.equal(b.sup,120);assert.equal(b.solde,0,'lundi : complément contractuel conservé');
b=bilan([jour('2026-09-10','19:00')],'2026-09-10','2026-09-10');
assert.equal(b.dues,0);assert.equal(b.sup,600);assert.equal(b.solde,600,'férié travaillé');
b=bilan([jour('2026-09-15','17:00',{matin_type:'vacances'})],'2026-09-15','2026-09-15');
assert.equal(b.travail,240);assert.equal(b.dues,240);assert.equal(b.solde,0);
b=bilan([jour('2026-09-15','19:00',{minutes_refusees:120})],'2026-09-15','2026-09-15');
assert.equal(b.refusees,120);assert.equal(b.sup,120);assert.equal(b.solde,120,'calcul sur saisies, refus distingués');
b=bilan([jour('2026-10-12','17:00',{pointe_segments:[[480,750]],pointe_etat:'pause',approuve:false})],'2026-10-12','2026-10-14');
assert.equal(b.travail,270);assert.equal(b.incomplets,1);assert.equal(b.attente,1);assert.equal(b.futurs,1);
assert.equal(bilan([],'2026-09-12','2026-09-13').solde,0,'week-end vide');
assert.equal(bilan([],'2024-02-28','2024-03-01').jours.length,3,'année bissextile');
for(const [a,z] of [['2026-09-20','2026-08-21'],['2026-02-30','2026-03-01'],['','2026-03-01'],['2020-01-01','2040-01-01']])assert.throws(()=>bilan([],a,z));
// Même résultat que l'export, pour plusieurs mois, années, absences et changements d'heure.
for(const [debut,fin] of [['2026-08-21','2026-09-20'],['2025-12-21','2026-01-20'],['2026-03-21','2026-04-20']]){
 ctx.dates={debut,fin};const jours=vm.runInContext('joursBilanPeriode(dates.debut,dates.fin)',ctx);
 const lignes=jours.filter((j,i)=>j.js!==0&&j.js!==6&&i%7!==0).map((j,i)=>jour(j.iso,i%3?'18:15':'16:30',{approuve:i%2===0,matin_type:i%11===0?'maladie':'travail'}));
 b=bilan(lignes,debut,fin);ctx.cas={jours,lignes};
 const f=vm.runInContext("feuilleEmploye({prenom:'Essai'},Object.fromEntries(cas.lignes.map(p=>[p.jour,p])),cas.jours,'Période')",ctx);
 assert.equal(b.travail,f.totMin);assert.equal(b.sup,f.totPlus);assert.equal(b.solde,f.solde);
}
console.log('✓ Périodes inclusives multi-mois/années, export cohérent, 42h/sem., fériés, absences, manquants, refus, pointages ouverts, dates invalides et futures');
