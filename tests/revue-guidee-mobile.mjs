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

 await pg.goto(new URL('../app/index.html',import.meta.url).href);await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{
  await charger();
  const original=window.fetch;window.questions=[];
  window.fetch=async(u,o)=>{
   const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');
   if(fn==='message_ecrire'){questions.push(a);return new Response(JSON.stringify({ok:true}));}
   if(fn==='admin_decider_heures'){essai.appels.push({fn,a});essai.p.approuve=true;essai.p.minutes_refusees=570-a.p_minutes_approuvees;return new Response(JSON.stringify({ok:true}));}
   return original(u,o);
  };
  essai.p={employe_id:'E',jour:'2026-10-14',matin_type:'travail',apm_type:'travail',pointe_segments:[[480,720],[780,1110]],pointe_etat:'termine',pointe_version:1,version_decision:1,approuve:false,pointe_evenements:['debut','pause','reprise','fin'].map((action,i)=>({id:'P'+i,action,at:'2026-10-14T'+['08:00','12:00','13:00','18:30'][i]+':00+02:00'}))};
  await charger();ouvrirJour('E','2026-10-14');
 });
 await pg.waitForSelector('[data-revue-etape]');
 assert.equal(await pg.locator('#voile-jour').evaluate(e=>e.classList.contains('ouvert')),false);
 assert.equal(await pg.locator('[data-minutes-pointe]').count(),0);
 assert.match(await pg.locator('[data-decider-pointe]').innerText(),/9h30/);
 const before=await pg.evaluate(()=>JSON.stringify(essai.p));
 await pg.locator('[data-revue-etape="question"]').click();
 await pg.locator('[data-question-jour]').fill('Pourquoi cette fin tardive ?');
 await pg.locator('[data-envoyer-question]').dblclick({delay:50});
 assert.equal(await pg.evaluate(()=>questions.length),1);
 assert.deepEqual(await pg.evaluate(()=>({emp:questions[0].p_employe,jour:questions[0].p_jour,mois:questions[0].p_mois})),{emp:'E',jour:'2026-10-14',mois:10});
 assert.equal(await pg.evaluate(()=>JSON.stringify(essai.p)),before,'une question ne change pas les pointages');
 await pg.locator('[data-question-jour]').fill('Brouillon à conserver');
 await pg.locator('[data-revue-jour="2026-10-13"]').click();
 await pg.waitForFunction(()=>pointeDialogue.jour==='2026-10-13'&&!!document.querySelector('[data-revue-etape]'));
 await pg.locator('[data-revue-jour="2026-10-14"]').click();
 await pg.waitForFunction(()=>pointeDialogue.jour==='2026-10-14'&&!!document.querySelector('[data-revue-etape]'));
 await pg.locator('[data-revue-etape="question"]').click();
 assert.equal(await pg.locator('[data-question-jour]').inputValue(),'Brouillon à conserver');
 await pg.locator('[data-revue-etape="controle"]').click();
 const heure=pg.locator('[data-heure-admin]').first();await heure.fill('08:15:00');
 pg.once('dialog',d=>d.dismiss());await pg.locator('[data-revue-jour="2026-10-13"]').click();
 assert.equal(await pg.evaluate(()=>pointeDialogue.jour),'2026-10-14');
 await pg.locator('[data-decider-pointe]').click();
 assert.equal(await pg.evaluate(()=>essai.appels.filter(a=>a.fn==='admin_decider_heures').length),0,'ne pas valider des changements non sauvés');
 await heure.fill('08:00:00');
 await pg.locator('[data-decider-pointe]').click();
 await pg.waitForFunction(()=>essai.p.approuve);
 assert.equal(await pg.evaluate(()=>essai.appels.find(a=>a.fn==='admin_decider_heures').a.p_minutes_approuvees),570);
 await pg.waitForSelector('[data-decision-avancee]');
 await pg.locator('[data-decision-avancee] summary').click();await pg.locator('[data-decision-h]').fill('8');await pg.locator('[data-decision-m]').fill('0');
 pg.once('dialog',d=>d.accept());await pg.locator('[data-decider-pointe]').click();
 await pg.waitForFunction(()=>essai.p.minutes_refusees===90);
 for(const width of [320,390,768,1280]){
  await pg.setViewportSize({width,height:664});
  assert.equal(await pg.locator('.pointe-dialogue').evaluate(e=>e.scrollWidth<=e.clientWidth),true,'pas de débordement '+width);
  assert.equal(await pg.locator('[data-revue-jour]').first().evaluate(e=>e.getBoundingClientRect().height>=44),true);
 }
 await pg.setViewportSize({width:390,height:664});await pg.locator('.pointe-dialogue').evaluate(e=>e.scrollTop=0);await pg.screenshot({path:'work/essais/revue-guidee-mobile.png'});
 await pg.locator('[data-revue-etape="question"]').click();await pg.screenshot({path:'work/essais/revue-question-mobile.png'});
 const tendance=await pg.evaluate(()=>{
  const lignes=Array.from({length:14},(_,i)=>({jour:'2026-10-'+String(i+1).padStart(2,'0'),matin_type:'travail',apm_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_debut:'13:00',apm_fin:'18:00',approuve:true,minutes_refusees:30}));
  return htmlTendanceHeures(lignes,'2026-10-01','2026-10-14','2026-10-20');
 });
 assert.match(tendance,/Évolution des heures/);assert.match(tendance,/partielle/);assert.match(tendance,/ne sont pas le solde contractuel/);
 // Une ancienne journée manuelle conserve la saisie et reçoit navigation et question.
 await pg.evaluate(()=>{$('pointe-fermer').click();ouvrirJour('E','2026-10-02',true);});
 assert.equal(await pg.locator('#voile-jour [data-envoyer-question]').count(),1);
 await pg.locator('#voile-jour [data-question-jour]').fill('Question ancienne journée');await pg.locator('#voile-jour [data-envoyer-question]').click();
 assert.equal(await pg.evaluate(()=>questions.at(-1).p_jour),'2026-10-02');
 assert.deepEqual(erreurs,[]);
 console.log('Revue guidée : navigation, brouillons, question sans mutation, protection des corrections, validation totale et partielle, 320–1280 px : OK');
}finally{await nav.close();}
