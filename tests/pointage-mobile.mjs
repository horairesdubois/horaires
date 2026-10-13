// Parcours mobile à 390 × 664 : reçus serveur, doublons et corrections.
import assert from 'node:assert/strict';
import {chromium} from 'playwright';
import {mkdirSync} from 'node:fs';
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
const ctx=await browser.newContext({viewport:{width:390,height:664},timezoneId:'America/New_York'});
const pg=await ctx.newPage();const erreurs=[];pg.on('pageerror',e=>erreurs.push(e.message));
await pg.addInitScript(()=>{
 const emp={id:'E1',prenom:'Essai',nom:'Technicien',role:'employe',actif:true,pointage_actif:true};
 localStorage.setItem('hor_token','essai');localStorage.setItem('hor_moi',JSON.stringify(emp));
 window.essai={events:[],etat:'vide',version:0,corrections:[],appels:[],recus:{},perdre:false};
 const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
 const pointage=()=>essai.events.length?{employe_id:'E1',jour:'2026-10-12',pointe_etat:essai.etat,pointe_evenements:essai.events,pointe_segments:essai.etat==='vide'||essai.version===1?[]:[[480,600]],pointe_version:essai.version,confirme:essai.etat==='termine',approuve:false,matin_type:'travail',apm_type:'travail'}:null;
 const lire=()=>({ok:true,jour:'2026-10-12',serveur:'2026-10-12T08:01:00Z',aujourdhui:'2026-10-12',pointage:pointage(),evenements:essai.events,etat:essai.etat,version:essai.version,corrections:essai.corrections,incomplets:[]});
 window.fetch=async(u,o)=>{const fn=String(u).split('/rpc/')[1],p=JSON.parse(o?.body||'{}');essai.appels.push({fn,p});
 if(fn==='mes_pointages')return rep({ok:true,employe:emp,pointages:pointage()?[pointage()]:[],aujourdhui:'2026-10-12'});
 if(fn==='messages_lire')return rep({ok:true,messages:[],non_lus:0,fils:[],autres_mois:[]});
 if(fn==='pointage_lire')return rep(lire());
 if(fn==='pointage_pointer'){
  if(!essai.recus[p.p_requete]&&p.p_version!==essai.version)return rep({ok:false,code:'conflit',erreur:'Version changée'});
  if(!essai.recus[p.p_requete]){essai.events.push({action:p.p_action,at:'2026-10-12T'+(essai.version===0?'06:00:17':'08:00:38')+'Z'});essai.etat={debut:'travail',pause:'pause',reprise:'travail',fin:'termine'}[p.p_action];essai.version++;essai.recus[p.p_requete]=true;}
  if(essai.perdre){essai.perdre=false;throw new TypeError('Network error');}return rep(lire());
 }
 if(fn==='pointage_corriger'){essai.corrections=[{id:'C1',etat:'attente',motif:p.p_motif,avant:essai.events,proposition:p.p_evenements.map(e=>({action:e.action,at:'2026-10-12T'+e.heure+'+02:00'}))}];return rep({ok:true});}
 return rep({ok:true});};
});
await pg.goto(new URL('../app/index.html',import.meta.url).href);
await pg.waitForSelector('[data-pointe-action="debut"]');
assert.equal(await pg.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
mkdirSync(new URL('../work/essais/',import.meta.url),{recursive:true});
await pg.screenshot({path:new URL('../work/essais/pointage-mobile-debut.png',import.meta.url).pathname,fullPage:true});
await pg.locator('[data-pointe-demande]').click();
await pg.locator('[data-texte-demande]').fill('Pointage manquant à midi : je demande une vérification.');
await pg.locator('[data-envoyer-demande]').dblclick({delay:40});
await pg.waitForFunction(()=>document.querySelector('[data-statut-demande]').textContent.includes('Demande envoyée'));
assert.equal(await pg.evaluate(()=>essai.appels.filter(a=>a.fn==='message_ecrire').length),1);
assert.equal(await pg.evaluate(()=>essai.appels.find(a=>a.fn==='message_ecrire').p.p_jour),'2026-10-12');
assert.equal(await pg.evaluate(()=>essai.events.length),0,'la demande n’ajoute aucune heure');
await pg.locator('#pointe-fermer').click();
await pg.locator('[data-pointe-action]').dblclick({delay:40});
await pg.waitForTimeout(2350);
assert.equal(await pg.evaluate(()=>essai.events.length),1,'double clic = une seule action');
assert.equal(await pg.locator('[data-pointe-action]').getAttribute('data-pointe-action'),'pause');
assert.match(await pg.locator('.pointe-recu').innerText(),/08:00:17/,'fuseau Zurich même téléphone étranger');
assert.equal(await pg.locator('[data-pointe-fin]').evaluate(e=>getComputedStyle(e).borderRadius),'50%');
await pg.screenshot({path:new URL('../work/essais/pointage-deux-ronds.png',import.meta.url).pathname,fullPage:true});
await pg.evaluate(()=>{essai.version++;essai.perdre=true;});
await pg.locator('[data-pointe-action]').click();
await pg.waitForSelector('[data-pointe-reessayer]');
assert.equal(await pg.locator('[data-pointe-action]').isDisabled(),true);
await pg.locator('[data-pointe-reessayer]').click();await pg.waitForTimeout(2300);
assert.equal(await pg.evaluate(()=>essai.events.length),2,'réponse perdue puis rejeu = pas de doublon');
const requetes=await pg.evaluate(()=>essai.appels.filter(a=>a.fn==='pointage_pointer').map(a=>a.p.p_requete));assert.equal(requetes[1],requetes[2]);
assert.equal(await pg.locator('[data-pointe-action]').getAttribute('data-pointe-action'),'reprise');
await pg.locator('[data-pointe-action]').click();await pg.waitForTimeout(2300);
pg.once('dialog',d=>d.accept());await pg.locator('[data-pointe-fin]').click();await pg.waitForTimeout(2300);
assert.match(await pg.locator('.pointe-etat').innerText(),/terminée/);assert.equal(await pg.locator('[data-pointe-action]').count(),0);
await pg.locator('[data-pointe-detail]').click();await pg.waitForSelector('[data-editer-pointe]');await pg.locator('[data-editer-pointe]').click();
assert.equal(await pg.locator('[data-ajouter-pointe],[data-retirer]').count(),0);
assert.equal(await pg.locator('.pointe-edition select').first().isDisabled(),true);
await pg.locator('[data-motif-pointe]').fill('Correction de l’heure de fin');
await pg.locator('.pointe-edition input').last().fill('10:30:00');await pg.locator('[data-envoyer-correction]').click();
await pg.waitForFunction(()=>document.querySelector('#pointe-contenu').textContent.includes('Correction en attente'));
assert.equal(await pg.evaluate(()=>essai.appels.find(a=>a.fn==='pointage_corriger').p.p_evenements.at(-1).heure),'10:30:00');
assert.equal(await pg.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
await pg.screenshot({path:new URL('../work/essais/pointage-mobile-correction.png',import.meta.url).pathname,fullPage:true});
await pg.evaluate(()=>sessionPerdue());assert.equal(await pg.locator('#voile-pointe').evaluate(e=>e.classList.contains('ouvert')),false);
assert.deepEqual(erreurs,[]);console.log('✓ Mobile : début/pause/reprise/fin, double tap, réponse perdue et même reçu, heure suisse, correction complète, déconnexion et largeur 390 px');
}finally{await browser.close();}
