import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const nav=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
 const pg=await nav.newPage({viewport:{width:1280,height:1000}}),erreurs=[];pg.on('pageerror',e=>erreurs.push(e.message));
 await pg.addInitScript(()=>{
 const admin={id:'A',prenom:'Bureau',role:'admin'},emp={id:'E',prenom:'Technicien',nom:'Essai',role:'employe',pointage_actif:true};
 localStorage.setItem('hor_token','test');localStorage.setItem('hor_moi',JSON.stringify(admin));
 window.essai={appels:[],p:null,perdre:false,conflit:false,recus:{}};const rep=x=>new Response(JSON.stringify(x));
 window.fetch=async(u,o)=>{const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');essai.appels.push({fn,a});
 const lire=()=>({ok:true,jour:'2026-10-14',aujourdhui:'2026-10-14',serveur:'2026-10-14T18:00:00+02:00',pointage:essai.p,evenements:essai.p?.pointe_evenements||[],etat:essai.p?.pointe_etat||'vide',version:essai.p?.pointe_version||0,corrections:[],incomplets:[]});
 if(fn==='admin_donnees')return rep({ok:true,employes:[admin,emp],pointages:essai.p?[essai.p]:[],aujourdhui:'2026-10-14'});
 if(fn==='pointage_lire')return rep(lire());
 if(fn==='admin_pointer'||fn==='admin_modifier_heure_pointage'||fn==='admin_pointage_enregistrer'){
  if(essai.conflit)return rep({ok:false,code:'conflit',erreur:'Un pointage a changé entre-temps.'});
  essai.p??={employe_id:'E',jour:'2026-10-14',matin_type:'travail',apm_type:'travail',pointe_evenements:[],pointe_segments:[],pointe_version:0};
  if(!essai.recus[a.p_requete]){
   const at='2026-10-14T'+a.p_heure+(a.p_heure?.length===5?':00':'')+'+02:00';
   if(fn==='admin_pointer'){essai.p.pointe_evenements.push({id:a.p_requete,action:a.p_action,at});essai.p.pointe_etat={debut:'travail',pause:'pause',reprise:'travail',fin:'termine'}[a.p_action];}
   else if(fn==='admin_pointage_enregistrer')essai.p.pointe_evenements=a.p_evenements.map(e=>e.heure?{action:e.action,at:'2026-10-14T'+e.heure+(e.heure.length===5?':00':'')+'+02:00'}:e);
   else essai.p.pointe_evenements[a.p_indice].at=at;
   essai.p.pointe_version++;essai.recus[a.p_requete]=true;
  }
  if(essai.perdre){essai.perdre=false;throw new Error('Réponse perdue');}return rep(lire());
 }
 return rep({ok:true,lignes:[],acteurs:[],retards:[]});};
 });
 const ligne=(a,indice=-1)=>pg.locator('.pointe-heure-ligne').filter({has:pg.locator('[data-pointer-admin="'+a+'"][data-indice-admin="'+indice+'"]')});
 const saisir=async(a,h,v,indice=-1)=>{const l=ligne(a,indice);await l.locator('input').fill(h);await l.locator('button').click();await pg.waitForFunction(v=>pointeDialogue?.donnees?.version===v,v);};
 const suite=async(action)=>{
  // Le rendu téléphone utilise exactement les événements reçus après la saisie admin.
  const obtenu=await pg.evaluate(()=>{
   const ancien={moi:S.moi,jour:S.jourSel},r=pointeDialogue.donnees;S.moi={id:'E',role:'employe',pointage_actif:true};S.jourSel=r.jour;
   Object.assign(POINTE,{donnees:r,jour:r.jour,horloge:Date.parse(r.serveur),recuLocal:Date.now(),occupe:false,requete:null});$('pointe-carte').hidden=false;peindrePointe();
   const bouton=$('pointe-carte').querySelector('[data-pointe-action]'),fin=$('pointe-carte').querySelector('[data-pointe-fin]');
   S.moi=ancien.moi;S.jourSel=ancien.jour;
   return {action:bouton?.dataset.pointeAction||null,fin:!!fin};
  });assert.equal(obtenu.action,action);assert.equal(obtenu.fin,action==='pause'||action==='reprise');
 };
 await pg.goto(process.env.HORAIRES_TEST_URL||new URL('../app/index.html',import.meta.url).href);await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{await charger();ouvrirJour('E','2026-10-14');});await pg.waitForSelector('[data-pointer-admin]');
 assert.deepEqual(await pg.locator('.pointe-etape h4').allTextContents(),['Début de journée','Début de pause','Reprise du travail','Fin de journée']);
 assert.equal(await ligne('debut').locator('input').inputValue(),'08:00');
 for(const a of ['pause','reprise','fin'])assert.equal(await ligne(a).locator('button').isDisabled(),true);
 await suite('debut');
 await ligne('debut').locator('input').fill('07:45');await pg.evaluate(()=>essai.perdre=true);await ligne('debut').locator('button').click();
 await pg.waitForFunction(()=>document.querySelector('[data-pointer-admin="debut"]').textContent==='Vérifier / réessayer');
 assert.equal(await ligne('debut').locator('input').isDisabled(),true);
 await ligne('debut').locator('button').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.version===1);
 const appels=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_pointer').map(x=>x.a));assert.deepEqual(appels[0],appels[1]);
 assert.equal(await pg.evaluate(()=>essai.p.pointe_evenements.length),1);await suite('pause');
 await saisir('debut','08:00',2,0);await suite('pause');
 assert.equal(await pg.evaluate(()=>essai.p.pointe_evenements.length),1,'corriger le début ne crée pas la pause');
 assert.match(await pg.locator('.pointe-suite').innerText(),/Prendre une pause/);
 await pg.setViewportSize({width:390,height:664});await pg.screenshot({path:'work/essais/quatre-etapes-mobile.png',fullPage:true});
 assert.equal(await pg.evaluate(()=>document.querySelector('.pointe-dialogue').scrollWidth<=document.querySelector('.pointe-dialogue').clientWidth),true);
 await pg.evaluate(()=>essai.conflit=true);await ligne('pause').locator('button').click();await pg.waitForSelector('[data-actualiser-admin]:not([hidden])');
 assert.equal(await ligne('pause').locator('button').isDisabled(),true);
 await pg.evaluate(()=>essai.conflit=false);await pg.locator('[data-actualiser-admin]').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.version===2&&!document.querySelector('[data-pointer-admin="pause"]').disabled);
 await saisir('pause','12:00',3);await suite('reprise');
 await saisir('pause','12:05',4,1);await suite('reprise');
 await saisir('reprise','13:00',5);await suite('pause');
 await saisir('reprise','13:05',6,2);await suite('pause');
 await saisir('fin','17:00',7);await suite(null);
 await saisir('fin','17:15',8,3);await suite(null);
 assert.equal(await pg.evaluate(()=>essai.p.pointe_evenements.length),4);
 assert.equal(await pg.locator('[data-indice-admin="-1"]').count(),0,'journée terminée : seules les corrections sont proposées');
 assert.equal(await pg.locator('.pointe-etape').count(),4,'les quatre étapes restent visibles');
 // Cas réel : fin enregistrée pendant une pause, reprise oubliée.
 await pg.evaluate(async()=>{essai.p.pointe_evenements.splice(2,1);await ouvrirPointe('E','2026-10-14',true);});
 assert.equal(await ligne('reprise').locator('input').isEnabled(),true);
 const avant=await pg.evaluate(()=>structuredClone(essai.p.pointe_evenements));
 await ligne('reprise').locator('input').fill('11:00');await ligne('reprise').locator('button').click();
 assert.match(await pg.locator('[data-erreur-admin]').innerText(),/entre le début de pause et la fin/);
 assert.equal(await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_pointage_enregistrer').length),0);
 await ligne('reprise').locator('input').fill('13:00');await pg.evaluate(()=>essai.perdre=true);await ligne('reprise').locator('button').click();
 await pg.waitForFunction(()=>document.querySelector('[data-pointer-admin="reprise"]').textContent==='Vérifier / réessayer');
 await ligne('reprise').locator('button').click();await pg.waitForFunction(()=>pointeDialogue?.donnees?.version===9);
 const insertions=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_pointage_enregistrer').map(x=>x.a));
 assert.equal(insertions.length,2);assert.deepEqual(insertions[0],insertions[1]);
 assert.deepEqual(await pg.evaluate(()=>essai.p.pointe_evenements.filter(e=>e.action!=='reprise')),avant);
 assert.equal(await pg.evaluate(()=>essai.p.pointe_evenements.length),4);await suite(null);
 assert.equal(await ligne('reprise',2).locator('button').innerText(),'Enregistrer cette heure');
 await pg.evaluate(()=>{S.moi.role='compta';peindreDialoguePointe();ouvrirJour('E','2026-10-14');});
 assert.equal(await pg.locator('#mj-pointer').isVisible(),false);assert.equal(await pg.locator('[data-pointer-admin]').count(),0);
 assert.deepEqual(erreurs,[]);console.log('✓ Quatre étapes visibles, saisie/correction isolée de chacune, boutons téléphone cohérents, réseau/conflit et mobile');
}finally{await nav.close();}
