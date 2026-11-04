import assert from 'node:assert/strict';
import {mkdirSync} from 'node:fs';
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
 if(fn==='admin_enregistrer_absence'){
  if(essai.conflit)return rep({ok:false,erreur:'La journée a changé. Rouvrez-la.'});
  const evenements=a.p_evenements.map(e=>e.heure?{action:e.action,at:a.p_jour+'T'+e.heure+(e.heure.length===5?':00':'')+'+02:00'}:e);
  essai.p={employe_id:'E',jour:a.p_jour,matin_type:a.p_matin_type,apm_type:a.p_apm_type,pointe_evenements:evenements,pointe_etat:evenements.length||a.p_matin_type!=='travail'&&a.p_apm_type!=='travail'?'termine':'vide',pointe_segments:evenements.length?[[480,720]]:[],pointe_version:2,version_decision:'version-2',remarque:a.p_remarque,approuve:false};return rep({ok:true});
 }

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
 pg.on('dialog',d=>d.accept());
 await pg.evaluate(async()=>{await charger();ouvrirJour('E','2026-10-14');});
 await pg.getByRole('button',{name:'Absence · journée ou demi-journée'}).click();
 await pg.locator('#absence-motif').selectOption('vacances');await pg.locator('#absence-appliquer').click();
 assert.equal(await pg.locator('#mj-statut-m').inputValue(),'vacances');assert.equal(await pg.locator('#mj-statut-a').inputValue(),'vacances');
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>essai.p?.matin_type==='vacances'&&!document.getElementById('mj-save').disabled);
 assert.deepEqual(await pg.evaluate(()=>essai.appels.find(a=>a.fn==='admin_enregistrer_absence').a.p_evenements),[]);
 // Une journée pointée reste accessible et la moitié travaillée conserve ses secondes.
 await pg.evaluate(async()=>{
  fermerJour();essai.p={employe_id:'E',jour:'2026-10-14',matin_type:'travail',apm_type:'travail',pointe_etat:'termine',pointe_version:1,version_decision:'version-1',pointe_segments:[[480,720],[780,1020]],pointe_evenements:['debut','pause','reprise','fin'].map((action,i)=>({action,at:'2026-10-14T'+['08:00:17','12:00:38','13:00:00','17:00:00'][i]+'+02:00'}))};
  await charger();ouvrirJour('E','2026-10-14');
 });
 await pg.getByRole('button',{name:'Absence · journée ou demi-journée'}).click();
 await pg.locator('#absence-periode').selectOption('apm');await pg.locator('#absence-motif').selectOption('maladie');await pg.locator('#absence-appliquer').click();
 assert.equal(await pg.locator('#mj-statut-m').inputValue(),'travail');assert.equal(await pg.locator('#mj-statut-a').inputValue(),'maladie');
 for(const width of [320,390,768,1280]){
  await pg.setViewportSize({width,height:900});
  await pg.locator('#mj-absence').scrollIntoViewIfNeeded();
  assert(await pg.locator('#voile-jour .modale').evaluate(e=>e.scrollWidth<=e.clientWidth),'pas de débordement '+width);
  const box=await pg.locator('#absence-appliquer').boundingBox();assert(box.height>=44);
 }
 await pg.setViewportSize({width:390,height:664});await pg.locator('#mj-absence').scrollIntoViewIfNeeded();
 mkdirSync('work/essais',{recursive:true});await pg.screenshot({path:'work/essais/absence-mobile.png',style:'#toast{display:none!important}'});
 await pg.setViewportSize({width:1280,height:900});await pg.locator('#mj-absence').scrollIntoViewIfNeeded();await pg.screenshot({path:'work/essais/absence-ordinateur.png',style:'#toast{display:none!important}'});
 await pg.locator('#mj-save').click();await pg.waitForFunction(()=>essai.p?.apm_type==='maladie'&&!document.getElementById('mj-save').disabled);
 const appel=await pg.evaluate(()=>essai.appels.filter(a=>a.fn==='admin_enregistrer_absence').at(-1).a);
 assert.equal(appel.p_evenements.length,2);assert.equal(appel.p_evenements[0].at,'2026-10-14T08:00:17+02:00');assert.equal(appel.p_evenements[1].action,'fin');assert.equal(appel.p_version,'version-1');
 assert.equal(await pg.locator('#mj-statut-a').inputValue(),'maladie','motif conservé à la réouverture');
 assert.equal(await pg.locator('#mj-md').inputValue(),'08:00','heures conservées à la réouverture');
 await pg.evaluate(()=>essai.conflit=true);await pg.locator('#absence-motif').selectOption('accident');await pg.locator('#absence-appliquer').click();await pg.locator('#mj-save').click();
 await pg.waitForFunction(()=>document.getElementById('toast').textContent.includes('changé'));
 assert(await pg.locator('#voile-jour').evaluate(e=>e.classList.contains('ouvert')),'conflit conserve formulaire');
 assert.equal(await pg.evaluate(()=>essai.p.apm_type),'maladie');
 await pg.evaluate(async()=>{fermerJour();essai.conflit=false;essai.p=null;await charger();ouvrirAbsence('E','2026-12-20');});
 await pg.locator('#absence-periode').selectOption('matin');await pg.locator('#absence-motif').selectOption('vacances');await pg.locator('#absence-appliquer').click();await pg.locator('#mj-save').click();
 await pg.waitForFunction(()=>essai.p?.jour==='2026-12-20'&&!document.getElementById('mj-save').disabled);
 const futur=await pg.evaluate(()=>essai.appels.filter(a=>a.fn==='admin_enregistrer_absence').at(-1).a);
 assert.equal(futur.p_matin_type,'vacances');assert.equal(futur.p_apm_type,'travail');assert.deepEqual(futur.p_evenements,[],'pas de travail fictif sur journée future');
 assert.deepEqual(await pg.locator('#absence-motif option').evaluateAll(es=>es.map(e=>e.value)),['vacances','maladie','accident','ferie','armee','ecole','conge_np','autre']);
 assert.deepEqual(erreurs,[]);console.log('Absences : accès avec/sans pointages, journée entière, demi-journée, secondes conservées, conflit et 320–1280 px : OK');
}finally{await nav.close();}
