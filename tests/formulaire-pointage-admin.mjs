import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const nav=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
 const pg=await nav.newPage({viewport:{width:1280,height:1000}}),erreurs=[];pg.on('pageerror',e=>erreurs.push(e.message));pg.on('dialog',d=>d.accept());
 await pg.addInitScript(()=>{
 const admin={id:'A',prenom:'Bureau',role:'admin'},emp={id:'E',prenom:'Essai',role:'employe',pointage_actif:true};
 localStorage.setItem('hor_token','test');localStorage.setItem('hor_moi',JSON.stringify(admin));
 window.essai={appels:[],p:{employe_id:'E',jour:'2026-10-12',matin_type:'travail',apm_type:'travail',remarque:'',approuve:true,confirme:true,pointe_etat:'termine',pointe_version:1,version_decision:'v1',pointe_segments:[[480,720],[780,1020]],pointe_evenements:[{action:'debut',at:'2026-10-12T08:00:17+02:00'},{action:'pause',at:'2026-10-12T12:00:00+02:00'},{action:'reprise',at:'2026-10-12T13:00:00+02:00'},{action:'fin',at:'2026-10-12T17:00:38+02:00'}]}};
 const rep=x=>new Response(JSON.stringify(x));
 window.fetch=async(u,o)=>{const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');essai.appels.push({fn,a});
 if(fn==='admin_donnees')return rep({ok:true,employes:[admin,emp],pointages:[essai.p],aujourdhui:'2026-10-13'});
 if(fn==='admin_formulaire_pointage'){essai.p.pointe_evenements=a.p_evenements.map(e=>({action:e.action,at:e.at||'2026-10-12T'+e.heure+'+02:00'}));Object.assign(essai.p,{pointe_version:2,version_decision:'v2',pointe_segments:[[480,720],[780,1050]],approuve:false,remarque:a.p_remarque});return rep({ok:true});}
 if(fn==='admin_decider_heures'){essai.p.approuve=true;return rep({ok:true});}
 return rep({ok:true,lignes:[],acteurs:[],retards:[]});};
 });
 await pg.goto(new URL('../app/index.html',import.meta.url).href);await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{await charger();ouvrirJour('E','2026-10-12');});
 assert.equal(await pg.locator('#voile-jour').evaluate(e=>e.classList.contains('ouvert')),true);
 assert.equal(await pg.locator('#voile-pointe').evaluate(e=>e.classList.contains('ouvert')),false);
 for(const [id,v] of [['mj-md','08:00'],['mj-mf','12:00'],['mj-ad','13:00'],['mj-af','17:00']])assert.equal(await pg.locator('#'+id).inputValue(),v);
 assert.equal(await pg.locator('#mj-af').isEnabled(),true,'modifiable après validation');
 await pg.locator('#mj-af').fill('17:30');await pg.locator('#mj-rem').fill('Chantier terminé');
 await pg.screenshot({path:'work/essais/formulaire-pointage-admin.png'});
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>MJ.pointage?.version_decision==='v2');
 const appel=await pg.evaluate(()=>essai.appels.find(x=>x.fn==='admin_formulaire_pointage').a);
 assert.equal(appel.p_evenements[0].at,'2026-10-12T08:00:17+02:00','secondes inchangées conservées');
 assert.equal(appel.p_evenements[3].heure,'17:30');assert.equal(appel.p_remarque,'Chantier terminé');
 assert.equal(await pg.locator('#mj-total').innerText(),'8h30');
 await pg.locator('#mj-approuver').click();await pg.waitForFunction(()=>essai.p.approuve);
 await pg.evaluate(()=>ouvrirJour('E','2026-10-12'));assert.equal(await pg.locator('#mj-af').isEnabled(),true);
 await pg.evaluate(()=>{essai.p.pointe_evenements=essai.p.pointe_evenements.slice(0,1);essai.p.pointe_etat='travail';S.pointages=[essai.p];ouvrirJour('E','2026-10-12');});
 assert.equal(await pg.locator('#mj-md').inputValue(),'08:00');assert.equal(await pg.locator('#mj-mf').inputValue(),'');
 assert.equal(await pg.locator('#mj-approuver').isVisible(),false,'incomplet à enregistrer avant validation');
 assert.deepEqual(erreurs,[]);console.log('✓ Formulaire habituel : heures préremplies, secondes préservées, remarque, validation et recorrection, journée incomplète');
}finally{await nav.close();}
