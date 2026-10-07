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

// Comparaison quotidienne et mensuelle : absences, fériés, minutes, décisions et bornes.
const construireJours=(an,mois)=>Array.from({length:new Date(an,mois,0).getDate()},(_,i)=>{
  const iso=`${an}-${String(mois).padStart(2,'0')}-${String(i+1).padStart(2,'0')}`;
  return {iso,num:i+1,js:new Date(iso+'T12:00:00').getDay()};
});
const types=['travail','vacances','maladie','accident','ferie','conge_np','ecole','armee','autre'];
let controles=0;
for(const mois of [1,4,5,8,9,10,12]){
  for(const cct of ['ferblanterie','chauffage','vitrerie']){
    const jours=construireJours(2026,mois),map={};
    for(const j of jours){
      if(j.num%7===0)continue; // journées manquantes
      const min=j.num%6;
      map[j.iso]=pointage(j.iso,`18:${String(min).padStart(2,'0')}`,{
        matin_type:types[j.num%types.length], apm_type:types[(j.num+2)%types.length],
        approuve:j.num%3===0,confirme:j.num%2===0,minutes_refusees:j.num%3===0 && (types[j.num%types.length]==='travail'||types[(j.num+2)%types.length]==='travail')?1:0
      });
    }
    // Une ligne extérieure au mois ne doit jamais contaminer ses totaux.
    map['2025-12-01']=pointage('2025-12-01','19:00');
    ctx.cas={jours,map,mois,cct};
    const resultat=vm.runInContext(`S.mois=cas.mois; S.auj='2026-10-07';
      var f=feuilleEmploye({prenom:'Essai',cct:cas.cct},cas.map,cas.jours,'2026');
      ({f,soldeEcran:cas.jours.reduce((n,j)=>n+jourMin(cas.map[j.iso]),0)-heuresDues(cas.jours,cas.map),
        supEcran:cas.jours.reduce((n,j)=>n+heuresSupJour(cas.map[j.iso],j.iso,j.js),0)})`,ctx);
    assert.equal(resultat.f.solde,resultat.soldeEcran);
    assert.equal(resultat.f.totPlus,resultat.supEcran);
    let app=0,ref=0,trav=0,sup=0;
    for(const ligne of resultat.f.ws.lignes){
      if(!/^\d{2}\.\d{2}\.2026$/.test(ligne[0]?.v))continue;
      const vals=ligne.map(c=>c?.v),iso=vals[0].split('.').reverse().join('-'),p=map[iso];
      if(!p){assert.equal(vals[7],'');assert.equal(vals.at(-2),'');continue;}
      const toMin=t=>t?t.split(':').reduce((h,m)=>Number(h)*60+Number(m)):0;
      assert.equal(vals[3],p.matin_debut||'');assert.equal(vals[6],p.apm_fin||'');
      const n=toMin(vals[7]);trav+=n;sup+=Math.round((vals[11]||0)*60);
      if(p.approuve){assert.equal(toMin(vals.at(-2))+toMin(vals.at(-1)),n);app+=toMin(vals.at(-2));ref+=toMin(vals.at(-1));}
      else{assert.equal(vals.at(-2),'');assert.equal(vals.at(-1),'');}
      controles++;
    }
    assert.equal(app,resultat.f.totApprouvees);assert.equal(ref,resultat.f.totRefusees);
    assert.equal(trav,resultat.f.totMin);assert.equal(sup,resultat.f.totPlus);
  }
}
// Zéro approuvé distinct d'une journée absente.
f=exporter(pointage('2026-09-15',null,{matin_debut:null,matin_fin:null,apm_debut:null}));
assert.equal(f.ws.lignes[6][7].v,'0:00');assert.equal(f.ws.lignes[6].at(-2).v,'0:00');
// La date serveur prévaut sur celle de l’ordinateur : le 8 octobre reste futur.
vm.runInContext("S.auj='2026-10-07'",ctx);
f=exporter(pointage('2026-10-08','17:01'));
assert.equal(f.totDues,0);assert.equal(f.totPlus,1);
console.log(`✓ ${controles} journées comparées, 21 mois/branches : saisies, heures sup, soldes, approbations, refus et zéros cohérents`);

// La validation la plus récente peut concerner une journée ancienne.
ctx.validationMap={
 '2026-09-01':pointage('2026-09-01','17:00',{approuve_le:'07.10.2026'}),
 '2026-09-30':pointage('2026-09-30','17:00',{approuve_le:'03.10.2026'})
};
const validations=vm.runInContext(`feuilleEmploye({prenom:'Essai'},validationMap,[{iso:'2026-09-01',num:1,js:2},{iso:'2026-09-30',num:30,js:3}],'septembre 2026')`,ctx);
assert.match(validations.ws.lignes.find(r=>String(r[0]?.v).startsWith('✓ Validé'))[0].v,/07\.10\.2026/);
console.log('✓ Date de validation : dernière approbation effective, indépendamment de l’ordre des jours');
