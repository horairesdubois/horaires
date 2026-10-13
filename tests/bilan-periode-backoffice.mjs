import assert from 'node:assert/strict';
import {chromium} from 'playwright';
const nav=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined});
try{
 const pg=await nav.newPage({viewport:{width:1280,height:1000}}),erreurs=[];pg.on('pageerror',e=>erreurs.push(e.message));
 await pg.addInitScript(()=>{
  const admin={id:'A',prenom:'Bureau',role:'admin'},emp={id:'E',prenom:'Alex',nom:'Essai',role:'employe',actif:true},autre={id:'F',prenom:'Camille',nom:'Essai',role:'employe',actif:true};
  const jour=(jour,employe_id='E',fin='17:00')=>({employe_id,jour,matin_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:fin,approuve:true,confirme:true});
  const data=[jour('2026-08-20','E','23:00'),jour('2026-08-21','E','19:00'),jour('2026-09-01'),jour('2026-09-20'),jour('2026-09-21','E','23:00'),jour('2026-09-01','F')];
  localStorage.setItem('hor_token','test');localStorage.setItem('hor_moi',JSON.stringify(admin));
  window.essai={appels:[],attendre:false,erreur:false};
  const rep=x=>new Response(JSON.stringify(x));
  window.fetch=async(u,o)=>{const fn=String(u).split('/rpc/')[1],a=JSON.parse(o?.body||'{}');essai.appels.push({fn,a});
   if(fn==='admin_donnees')return rep({ok:true,employes:[admin,emp,autre],pointages:data.filter(p=>p.jour.startsWith(a.p_annee+'-'+String(a.p_mois).padStart(2,'0'))),aujourdhui:'2026-10-13'});
   if(fn==='admin_bilan_periode'){
    if(essai.erreur)throw new Error('Réseau indisponible');
    const r={ok:true,pointages:data.filter(p=>p.employe_id===a.p_employe&&p.jour>=a.p_debut&&p.jour<=a.p_fin),aujourdhui:'2026-10-13'};
    if(essai.attendre){essai.attendre=false;return new Promise(resolve=>essai.repondre=()=>resolve(rep(r)));}
    return rep(r);
   }
   return rep({ok:true,messages:[],lignes:[],acteurs:[],retards:[]});
  };
 });
 await pg.goto(process.env.HORAIRES_TEST_URL||new URL('../app/index.html',import.meta.url).href);
 await pg.waitForSelector('#v-admin:not([hidden])');
 await pg.evaluate(async()=>{S.annee=2026;S.mois=9;await charger();ouvrirDetails('E');});
 assert.equal(await pg.locator('#det-periode').isVisible(),true);
 const mois=await pg.evaluate(()=>JSON.stringify([S.annee,S.mois,S.pointages]));
 await pg.locator('#bp-debut').fill('2026-08-21');await pg.locator('#bp-fin').fill('2026-09-20');await pg.locator('#bp-afficher').click();
 await pg.waitForFunction(()=>!document.getElementById('bp-resultat').hidden&&!document.getElementById('bp-afficher').disabled);
 assert.equal(await pg.locator('#bp-travail').innerText(),'26h00');assert.equal(await pg.locator('#bp-sup').innerText(),'10h00');
 assert.equal(await pg.locator('#bp-solde').innerText(),'−142h00');assert.match(await pg.locator('#bp-etat').innerText(),/sans saisie/);
 assert.equal(await pg.evaluate(()=>JSON.stringify([S.annee,S.mois,S.pointages])),mois,'mois et pointages courants préservés');
 assert.equal(await pg.locator('#bp-jours tr').count(),31);
 await pg.locator('#det-periode summary').click();assert.match(await pg.locator('#bp-jours').innerText(),/21.08.2026/);assert.match(await pg.locator('#bp-jours').innerText(),/20.09.2026/);
 await pg.locator('#det-periode summary').click();
 const appels=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_bilan_periode').length);
 await pg.locator('#bp-debut').fill('2026-09-25');await pg.locator('#bp-afficher').click();
 assert.equal(await pg.locator('#bp-resultat').isHidden(),true);assert.equal(await pg.locator('#bp-erreur').isVisible(),true);
 assert.equal(await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_bilan_periode').length),appels);
 await pg.locator('#bp-debut').fill('2026-08-21');
 await pg.evaluate(()=>essai.attendre=true);await pg.locator('#bp-afficher').click();await pg.waitForFunction(()=>!!essai.repondre);
 await pg.locator('#bp-employe').selectOption('F');await pg.waitForFunction(()=>document.getElementById('bp-travail').textContent==='8h00'&&!document.getElementById('bp-resultat').hidden);
 await pg.evaluate(()=>essai.repondre());
 assert.equal(await pg.locator('#bp-travail').innerText(),'8h00','ancienne réponse ne remplace pas le nouveau salarié');
 assert.match(await pg.locator('#det-titre').innerText(),/Camille/);
 await pg.evaluate(()=>essai.erreur=true);await pg.locator('#bp-afficher').click();await pg.waitForSelector('#bp-erreur:not([hidden])');
 assert.equal(await pg.locator('#bp-resultat').isHidden(),true,'échec sans ancien total trompeur');assert.equal(await pg.locator('#bp-afficher').isEnabled(),true);
 await pg.evaluate(()=>essai.erreur=false);await pg.locator('#bp-employe').selectOption('E');await pg.waitForFunction(()=>!document.getElementById('bp-resultat').hidden);
 await pg.screenshot({path:'work/essais/bilan-periode-desktop.png'});
 await pg.setViewportSize({width:390,height:664});
 assert.equal(await pg.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'mobile sans débordement');
 await pg.locator('#bp-solde').scrollIntoViewIfNeeded();assert.equal(await pg.locator('#bp-solde').isVisible(),true);
 await pg.locator('#det-fermer').scrollIntoViewIfNeeded();assert.equal(await pg.locator('#det-fermer').isVisible(),true);
 await pg.locator('#voile-det .modale').evaluate(e=>{e.scrollTop=0;return new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
 await pg.screenshot({path:'work/essais/bilan-periode-mobile.png'});
 const avant=await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_bilan_periode').length);
 for(const role of ['compta','employe']){
  await pg.evaluate(role=>{S.moi={id:'N',role};S.lecture=role==='compta';ouvrirDetails('E');return chargerBilanPeriode();},role);
  assert.equal(await pg.locator('#det-periode').isHidden(),true,'bilan réservé au bureau : '+role);
 }
 assert.equal(await pg.evaluate(()=>essai.appels.filter(x=>x.fn==='admin_bilan_periode').length),avant,'aucun appel hors admin');
 assert.deepEqual(erreurs,[]);
 console.log('✓ Bilan back-office : intervalle multi-mois, deux totaux, détail inclusif, mois préservé, changement de salarié, concurrence, erreur réseau, mobile et rôles');
}finally{await nav.close();}
