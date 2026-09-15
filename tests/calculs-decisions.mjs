import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const html=readFileSync(new URL('../app/index.html',import.meta.url),'utf8');
const source=html.slice(html.indexOf('const parseT ='),html.indexOf('/* Journée normale des employés'));
const exportSource=html.slice(html.indexOf('function ajouterFeuilleDecisions('),html.indexOf('function chargerXLSX('));
const ctx=vm.createContext({});
vm.runInContext(`const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));\n${source}\n${exportSource}`,ctx);
vm.runInContext(`
var p={approuve:true,minutes_refusees:120,motif_refus:'<img src=x onerror=alert(1)>',matin_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:'19:00'};
var S={employes:[{id:'E1',prenom:'Steve'}]};
function nomComplet(e){return e.prenom;}
var feuille;
var XLSX={utils:{aoa_to_sheet:lignes=>({lignes}),book_append_sheet:(wb,ws,nom)=>{feuille={ws,nom};}}};
ajouterFeuilleDecisions({},['E1'],{E1:{'2026-09-14':p}},[{iso:'2026-09-14'}]);
`,ctx);
assert.equal(vm.runInContext('jourMin(p)',ctx),600);
assert.equal(vm.runInContext('minutesApprouvees(p)',ctx),480);
assert.equal(vm.runInContext('minutesRefusees(p)',ctx),120);
assert.match(vm.runInContext('htmlDecisionHeures(p)',ctx),/&lt;img/);
assert.doesNotMatch(vm.runInContext('htmlDecisionHeures(p)',ctx),/<img/);
assert.deepEqual(JSON.parse(vm.runInContext('JSON.stringify(feuille.ws.lignes[1].slice(3,6))',ctx)),['10:00','8:00','2:00']);
vm.runInContext('p.minutes_refusees=600',ctx);
assert.equal(vm.runInContext('minutesApprouvees(p)',ctx),0);
assert.match(vm.runInContext('libDecisionHeures(p)',ctx),/toutes les heures refusées/);
vm.runInContext('p.approuve=false',ctx);
assert.equal(vm.runInContext('minutesRefusees(p)',ctx),0);
assert.equal(vm.runInContext('minutesApprouvees(p)',ctx),0);
console.log('✓ Saisie conservée, totaux séparés, refus total, motif échappé et export détaillé');
