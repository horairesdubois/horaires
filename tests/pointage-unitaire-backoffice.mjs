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
 const ajouter=async(action,heure)=>{await pg.locator('[data-ajouter-pointe]').click();const row=pg.locator('.pointe-edition').last();await row.locator('select').selectOption(action);await row.locator('input').fill(heure);};
 const sauver=async(version)=>{await pg.locator('[data-envoyer-correction]').click();await pg.waitForFunction(v=>pointeDialogue?.donnees?.version===v,version);};
 await pg.goto(new URL('../app/index.html',import.meta.url).href);await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{await charger();ouvrirJour('E','2026-10-14');});await pg.waitForSelector('[data-editeur-pointe]');
 assert.equal(await pg.locator('[data-pointer-admin]').count(),0);
 await ajouter('debut','08:00:00');await sauver(1);
 await ajouter('pause','12:00:00');await ajouter('reprise','13:00:00');await ajouter('fin','17:00:00');await sauver(2);
 assert.equal(await pg.locator('.pointe-edition input').count(),4);
 await pg.locator('.pointe-edition input').nth(1).fill('12:15:00');await pg.locator('.pointe-edition input').nth(2).fill('13:15:00');
 await pg.evaluate(()=>essai.perdre=true);await pg.locator('[data-envoyer-correction]').click();await pg.waitForFunction(()=>document.querySelector('[data-erreur-pointe]').textContent.includes('connexion'));
 await sauver(3);
 const appels=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_pointage_enregistrer').map(x=>x.a));assert.deepEqual(appels.at(-1),appels.at(-2),'réessai identique après réponse perdue');
 assert.equal(await pg.evaluate(()=>essai.p.pointe_evenements.length),4);
 await pg.locator('.pointe-edition input').first().fill('08:30:00');await pg.evaluate(()=>essai.conflit=true);await pg.locator('[data-envoyer-correction]').click();await pg.waitForFunction(()=>document.querySelector('[data-erreur-pointe]').textContent.includes('changé'));
 assert.equal(await pg.locator('.pointe-edition input').first().inputValue(),'08:30:00');
 assert.equal(await pg.evaluate(()=>essai.p.pointe_version),3);
 await pg.evaluate(()=>essai.conflit=false);await sauver(4);
 await pg.locator('[data-retirer]').nth(3).click();await ajouter('pause','15:00:00');await ajouter('reprise','15:15:00');await ajouter('fin','17:30:00');await sauver(5);
 assert.equal(await pg.locator('.pointe-edition').count(),6,'plusieurs pauses dans le même éditeur');
 for(const width of [320,390,1280]){await pg.setViewportSize({width,height:664});assert.equal(await pg.locator('.pointe-dialogue').evaluate(e=>e.scrollWidth<=e.clientWidth),true);}
 await pg.evaluate(()=>{S.moi.role='compta';peindreDialoguePointe();});assert.equal(await pg.locator('[data-editeur-pointe]').count(),0);
 assert.deepEqual(erreurs,[]);console.log('Éditeur unique : création, corrections groupées, plusieurs pauses, conflit, réessai idempotent, accès compta et mobile : OK');
}finally{await nav.close();}
