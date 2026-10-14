import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const nav=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
 const pg=await nav.newPage({viewport:{width:1280,height:950}}),erreurs=[];pg.on('pageerror',e=>erreurs.push(e.message));
 await pg.addInitScript(()=>{
 const admin={id:'A',prenom:'Bureau',role:'admin'},emp={id:'E',prenom:'Technicien',nom:'Essai',role:'employe',pointage_actif:true};
 localStorage.setItem('hor_token','test');localStorage.setItem('hor_moi',JSON.stringify(admin));
 window.essai={appels:[],p:null,perdre:false,conflit:false};const rep=x=>new Response(JSON.stringify(x));
 window.fetch=async(u,o)=>{const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');essai.appels.push({fn,a});
 const lire=()=>({ok:true,jour:'2026-10-14',aujourdhui:'2026-10-14',pointage:essai.p,evenements:essai.p?.pointe_evenements||[],etat:essai.p?.pointe_etat||'vide',version:essai.p?.pointe_version||0,corrections:[],incomplets:[]});
 if(fn==='admin_donnees')return rep({ok:true,employes:[admin,emp],pointages:essai.p?[essai.p]:[],aujourdhui:'2026-10-14'});
 if(fn==='pointage_lire')return rep(lire());
 if(fn==='admin_pointer'){
  if(essai.conflit)return rep({ok:false,code:'conflit',erreur:'Un pointage a changé entre-temps.'});
  essai.p??={employe_id:'E',jour:'2026-10-14',matin_type:'travail',apm_type:'travail',pointe_evenements:[],pointe_segments:[],pointe_version:0};
  if(!essai.p.pointe_evenements.some(e=>e.id===a.p_requete)){essai.p.pointe_evenements.push({id:a.p_requete,action:a.p_action,at:'2026-10-14T'+a.p_heure+':00+02:00'});essai.p.pointe_version++;essai.p.pointe_etat={debut:'travail',pause:'pause',reprise:'travail',fin:'termine'}[a.p_action];}
  if(essai.perdre){essai.perdre=false;throw new Error('Réponse perdue');}return rep(lire());
 }
 return rep({ok:true,lignes:[],acteurs:[],retards:[]});};
 });
 await pg.goto(process.env.HORAIRES_TEST_URL||new URL('../app/index.html',import.meta.url).href);await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{await charger();ouvrirJour('E','2026-10-14');});await pg.locator('#mj-pointer').click();
 await pg.waitForSelector('[data-pointer-admin]');
 assert.equal(await pg.locator('[data-heure-admin]').inputValue(),'08:00');
 assert.deepEqual(await pg.locator('[data-action-admin] option').evaluateAll(es=>es.map(e=>e.value)),['debut']);
 await pg.locator('[data-heure-admin]').fill('07:45');await pg.evaluate(()=>essai.perdre=true);await pg.locator('[data-pointer-admin]').click();
 await pg.waitForFunction(()=>document.querySelector('[data-pointer-admin]').textContent==='Vérifier / réessayer');
 assert.equal(await pg.locator('[data-heure-admin]').isDisabled(),true,'requête conservée après perte réseau');
 await pg.locator('[data-pointer-admin]').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.version===1);
 assert.equal(await pg.evaluate(()=>essai.p.pointe_evenements.length),1);
 const appels=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_pointer').map(x=>x.a));assert.deepEqual(appels[0],appels[1]);assert.equal(appels[0].p_heure,'07:45');
 assert.deepEqual(await pg.locator('[data-action-admin] option').evaluateAll(es=>es.map(e=>e.value)),['pause','fin']);
 await pg.evaluate(()=>essai.conflit=true);await pg.locator('[data-pointer-admin]').click();await pg.waitForSelector('[data-actualiser-admin]:not([hidden])');
 assert.equal(await pg.locator('[data-pointer-admin]').isDisabled(),true,'conflit : pas de rejeu automatique');
 await pg.evaluate(()=>essai.conflit=false);await pg.locator('[data-actualiser-admin]').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.version===1&&!document.querySelector('[data-pointer-admin]').disabled);
 await pg.locator('[data-heure-admin]').fill('12:00');await pg.locator('[data-pointer-admin]').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.etat==='pause');
 assert.deepEqual(await pg.locator('[data-action-admin] option').evaluateAll(es=>es.map(e=>e.value)),['reprise','fin']);
 await pg.setViewportSize({width:390,height:664});await pg.screenshot({path:'work/essais/pointage-unitaire-mobile.png',fullPage:true});
 assert.equal(await pg.evaluate(()=>document.querySelector('.pointe-dialogue').scrollWidth<=document.querySelector('.pointe-dialogue').clientWidth),true,'pas de débordement mobile');
 await pg.locator('[data-pointer-admin]').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.version===3);
 await pg.locator('[data-action-admin]').selectOption('fin');await pg.locator('[data-pointer-admin]').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.etat==='termine');
 assert.equal(await pg.locator('[data-pointer-admin]').count(),0,'pas d’ajout sur journée terminée');
 await pg.evaluate(()=>{S.moi.role='compta';peindreDialoguePointe();ouvrirJour('E','2026-10-14');});
 assert.equal(await pg.locator('#mj-pointer').isVisible(),false);assert.equal(await pg.locator('[data-pointer-admin]').count(),0);
 assert.deepEqual(erreurs,[]);console.log('✓ Pointage isolé : heure choisie, toutes les transitions, réponse perdue, concurrence, mobile, accès back-office');
}finally{await nav.close();}
