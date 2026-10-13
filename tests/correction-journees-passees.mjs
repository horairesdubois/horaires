import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const nav=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
 const pg=await nav.newPage({viewport:{width:1280,height:1000}}),erreurs=[];
 pg.on('pageerror',e=>erreurs.push(e.message));
 pg.on('dialog',d=>d.accept());
 await pg.addInitScript(()=>{
  const admin={id:'A',prenom:'Bureau',role:'admin'},emp={id:'E',prenom:'Essai',role:'employe',pointage_actif:true};
  localStorage.setItem('hor_token','test');localStorage.setItem('hor_moi',JSON.stringify(admin));
  window.essai={appels:[],p:{employe_id:'E',jour:'2026-10-12',matin_type:'travail',apm_type:'travail',remarque:'',approuve:false,pointe_etat:'pause',pointe_version:2,version_decision:'v2',pointe_segments:[],pointe_evenements:[{action:'debut',at:'2026-10-12T19:11:04.70382Z'},{action:'pause',at:'2026-10-12T19:11:56.520068Z'}]}};
  const rep=x=>new Response(JSON.stringify(x));
  window.fetch=async(u,o)=>{
   const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');essai.appels.push({fn,a});
   if(fn==='admin_donnees')return rep({ok:true,employes:[admin,emp],pointages:[essai.p],aujourdhui:'2026-10-13'});
   if(fn==='admin_formulaire_pointage'){
    const ev=a.p_evenements.map(e=>({action:e.action,at:e.at||'2026-10-12T'+e.heure+'+02:00'}));
    const min=t=>{const d=new Date(t);return (d.getUTCHours()+2)*60+d.getUTCMinutes();};
    essai.p.pointe_segments=[];
    for(let i=0;i<ev.length;i+=2)essai.p.pointe_segments.push([min(ev[i].at),min(ev[i+1].at)]);
    Object.assign(essai.p,{pointe_evenements:ev,pointe_etat:'termine',pointe_version:essai.p.pointe_version+1,version_decision:'v'+(essai.p.pointe_version+1),approuve:false,remarque:a.p_remarque});
    return rep({ok:true});
   }
   if(fn==='admin_decider_heures'){essai.p.approuve=true;return rep({ok:true});}
   return rep({ok:true,lignes:[],acteurs:[],retards:[]});
  };
 });
 await pg.goto(new URL('../app/index.html',import.meta.url).href);
 await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{await charger();ouvrirJour('E','2026-10-12');});
 const champs=['mj-md','mj-mf','mj-ad','mj-af'];
 for(const id of champs)assert.equal(await pg.locator('#'+id).isEnabled(),true,'champ passé modifiable : '+id);
 assert.equal(await pg.locator('#mj-ad').inputValue(),'21:11');
 assert.equal(await pg.locator('#mj-af').inputValue(),'21:11');
 assert.equal(await pg.locator('#mj-approuver').isVisible(),false,'approbation après clôture');
 assert.match(await pg.locator('#mj-demande').innerText(),/journée passée/);
 // Clôturer à heures inchangées conserve les secondes malgré pause -> fin.
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>MJ.pointeOriginal?.pointe_version===3);
 const premier=await pg.evaluate(()=>essai.appels.find(x=>x.fn==='admin_formulaire_pointage').a.p_evenements);
 assert.deepEqual(premier,[{action:'debut',at:'2026-10-12T19:11:04.70382Z'},{action:'fin',at:'2026-10-12T19:11:56.520068Z'}]);
 for(const [id,v] of champs.map((id,i)=>[id,['08:00','12:00','13:00','17:00'][i]]))await pg.locator('#'+id).fill(v);
 await pg.locator('#mj-rem').fill('Heures vérifiées');
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>MJ.pointeOriginal?.pointe_version===4);
 assert.equal(await pg.locator('#mj-total').innerText(),'8h00');
 assert.deepEqual(await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_formulaire_pointage').at(-1).a.p_evenements.map(e=>e.action)),['debut','pause','reprise','fin']);
 await pg.locator('#mj-approuver').click();await pg.waitForFunction(()=>essai.p.approuve);
 await pg.evaluate(()=>ouvrirJour('E','2026-10-12'));
 await pg.locator('#mj-af').fill('16:30');await pg.locator('#mj-save').click();
 await pg.waitForFunction(()=>MJ.pointeOriginal?.pointe_version===5);
 assert.equal(await pg.locator('#mj-total').innerText(),'7h30');assert.equal(await pg.evaluate(()=>essai.p.approuve),false);
 // Une plage à moitié saisie ne part pas au serveur.
 await pg.locator('#mj-af').fill('');await pg.locator('#mj-save').click();
 assert.equal(await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_formulaire_pointage').length),3);
 await pg.locator('#mj-ad').fill('');await pg.locator('#mj-save').click();
 await pg.waitForFunction(()=>MJ.pointeOriginal?.pointe_version===6);
 assert.equal(await pg.locator('#mj-total').innerText(),'4h00');
 // Deux plages jointives représentent une journée continue, sans fausse pause.
 for(const [id,v] of champs.map((id,i)=>[id,['08:00','12:00','12:00','20:30'][i]]))await pg.locator('#'+id).fill(v);
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>MJ.pointeOriginal?.pointe_version===7);
 const continu=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_formulaire_pointage').at(-1).a.p_evenements);
 assert.deepEqual(continu.map(e=>e.action),['debut','fin'],'pas de pause/reprise à la même heure');
 assert.equal(await pg.locator('#mj-total').innerText(),'12h30');
 assert.equal(await pg.locator('#mj-md').inputValue(),'08:00');
 assert.equal(await pg.locator('#mj-mf').inputValue(),'20:30');
 assert.equal(await pg.locator('#mj-ad').inputValue(),'');
 assert.equal(await pg.locator('#mj-af').inputValue(),'');
 await pg.locator('#mj-approuver').click();await pg.waitForFunction(()=>essai.p.approuve);
 await pg.evaluate(()=>ouvrirJour('E','2026-10-12'));
 // Une vraie pause courte conserve ses secondes même si les minutes sont égales.
 await pg.evaluate(()=>{Object.assign(essai.p,{pointe_evenements:[{action:'debut',at:'2026-10-12T08:00:00+02:00'},{action:'pause',at:'2026-10-12T12:00:10+02:00'},{action:'reprise',at:'2026-10-12T12:00:40+02:00'},{action:'fin',at:'2026-10-12T20:30:00+02:00'}]});S.pointages=[essai.p];ouvrirJour('E','2026-10-12');});
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>MJ.pointeOriginal?.pointe_version===8);
 const courte=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_formulaire_pointage').at(-1).a.p_evenements);
 assert.equal(courte.length,4,'une vraie pause de 30 secondes inchangée reste conservée');
 assert.equal(courte[1].at,'2026-10-12T12:00:10+02:00');
 assert.equal(courte[2].at,'2026-10-12T12:00:40+02:00');
 // Retour au cas initial sur téléphone, puis journée laissée au travail.
 await pg.setViewportSize({width:390,height:664});
 await pg.evaluate(()=>{essai.p.pointe_etat='travail';essai.p.pointe_evenements=[{action:'debut',at:'2026-10-12T06:00:00Z'}];S.pointages=[essai.p];ouvrirJour('E','2026-10-12');});
 for(const id of champs)assert.equal(await pg.locator('#'+id).isEnabled(),true);
 assert.equal(await pg.locator('#mj-defaut').isVisible(),true);
 assert.equal(await pg.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'pas de débordement mobile');
 await pg.screenshot({path:'work/essais/correction-journee-passee-mobile.png'});
 assert.deepEqual(erreurs,[]);
 console.log('✓ Journées passées : correction, validation, matin seul, journée continue 12h30, vraie pause courte conservée, mobile');
}finally{await nav.close();}
