import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const navigateur=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
 const pg=await navigateur.newPage({viewport:{width:1280,height:900}}),erreurs=[];pg.on('pageerror',e=>erreurs.push(e.message));
 await pg.addInitScript(()=>{
  const admin={id:'A1',prenom:'Back Office',role:'admin',actif:true},emp={id:'E1',prenom:'Technicien',role:'employe',actif:true,pointage_actif:true};
  localStorage.setItem('hor_token','test-admin');localStorage.setItem('hor_moi',JSON.stringify(admin));
  const events=[{action:'debut',at:'2026-10-12T06:00:00Z'},{action:'fin',at:'2026-10-12T12:00:00Z'}];
  window.essai={p:{employe_id:emp.id,jour:'2026-10-12',pointe_evenements:events,pointe_segments:[[480,840]],pointe_etat:'termine',pointe_version:2,pointe_attente:true,version_decision:'v2',confirme:true,approuve:false,matin_type:'travail',apm_type:'travail'},c:{id:'C1',employe_id:emp.id,employe:emp.prenom,jour:'2026-10-12',etat:'attente',avant:events,proposition:events,motif:'Fin <img src=x onerror=alert(1)> corrigée'},appels:[]};
  const rep=o=>new Response(JSON.stringify(o),{status:200});
  window.fetch=async(u,o)=>{const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');essai.appels.push({fn,a});
   if(fn==='admin_donnees')return rep({ok:true,employes:[admin,emp],pointages:[essai.p],pointage_demandes:essai.c.etat==='attente'?[essai.c]:[],aujourdhui:'2026-10-12',entreprise:'Essai'});
   if(fn==='pointage_lire')return rep({ok:true,jour:essai.p.jour,pointage:essai.p,evenements:essai.p.pointe_evenements,etat:essai.p.pointe_etat,version:essai.p.pointe_version,corrections:[essai.c]});
   if(fn==='admin_pointage_enregistrer'){essai.p.pointe_evenements=a.p_evenements.map(e=>({action:e.action,at:'2026-10-12T'+e.heure+'+02:00'}));essai.p.pointe_etat='termine';essai.p.pointe_segments=[[480,990]];essai.p.approuve=false;essai.p.pointe_version++;return rep({ok:true});}
   if(fn==='pointage_decider'){essai.c.etat=a.p_accepter?'acceptee':'refusee';essai.p.pointe_attente=false;essai.p.pointe_version++;return rep({ok:true});}
   if(fn==='admin_decider_heures'){essai.p.approuve=true;essai.p.minutes_refusees=360-a.p_minutes_approuvees;return rep({ok:true});}
   if(fn==='journal_lire')return rep({ok:true,lignes:[],acteurs:[]});
   if(fn==='retards_saisie')return rep({ok:true,retards:[]});
   return rep({ok:true});
  };
 });
 await pg.goto(new URL('../app/index.html',import.meta.url).href);
 await pg.waitForSelector('[data-dem-pointe]');assert.equal(await pg.locator('#pointe-demandes-admin img').count(),0);
 await pg.locator('[data-dem-pointe]').click();await pg.waitForSelector('[data-accepter]');
 assert.equal(await pg.locator('#pointe-contenu img').count(),0,'motif correctement échappé');
 assert.equal(await pg.locator('[data-decider-pointe]').count(),0,'pas de décision avant traitement de la correction');
 await pg.locator('[data-accepter]').click();await pg.waitForSelector('[data-decider-pointe]');
 await pg.locator('[data-minutes-pointe]').fill('340');await pg.locator('[data-motif-decision]').fill('20 minutes non retenues');await pg.locator('[data-decider-pointe]').click();
 await pg.waitForFunction(()=>essai.p.approuve);assert.equal(await pg.evaluate(()=>essai.p.minutes_refusees),20);
 assert.equal(await pg.evaluate(()=>essai.appels.find(x=>x.fn==='admin_decider_heures').a.p_version),'v2');
 assert.equal(await pg.locator('[data-editer-pointe]').innerText(),'Modifier les heures');
 await pg.evaluate(()=>{essai.p.pointe_etat='pause';essai.p.pointe_evenements=essai.p.pointe_evenements.slice(0,1);});
 await pg.evaluate(()=>ouvrirPointe('E1','2026-10-12',true));await pg.waitForSelector('[data-editer-pointe]');
 assert.ok(!(await pg.locator('#pointe-contenu').innerText()).includes('Demander une correction'));
 await pg.locator('[data-editer-pointe]').click();await pg.locator('[data-ajouter-pointe]').click();
 await pg.locator('.pointe-edition input').nth(1).fill('16:30:00');
 await pg.locator('[data-envoyer-correction]').click();await pg.waitForSelector('[data-decider-pointe]');
 assert.equal(await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_pointage_enregistrer').length),1);
 assert.equal(await pg.evaluate(()=>essai.p.approuve),false);
 await pg.locator('[data-decider-pointe]').click();await pg.waitForFunction(()=>essai.p.approuve);
 await pg.locator('[data-editer-pointe]').click();await pg.locator('.pointe-edition input').nth(1).fill('16:00:00');
 await pg.locator('[data-envoyer-correction]').click();await pg.waitForFunction(()=>essai.appels.filter(x=>x.fn==='admin_pointage_enregistrer').length===2);
 await pg.waitForSelector('[data-decider-pointe]');
 await pg.locator('#pointe-fermer').click();await pg.locator('[data-ong="export"]').click();assert.equal(await pg.locator('#pointe-demandes-admin').isHidden(),true);
 assert.deepEqual(erreurs,[]);console.log('✓ Back-office : demandes visibles, motif protégé, correction préalable, décision partielle versionnée et retour à l’export');
}finally{await navigateur.close();}
