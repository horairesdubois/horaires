// Mesure la fenêtre de saisie dans la hauteur que Safari laisse réellement
// sur un iPhone (390×664). Lancer : npm i playwright && node tests/fenetre-saisie.mjs
import { chromium } from 'playwright';
const E={id:'E1',prenom:'Sami',nom:'F',metier:'Ferblantier',role:'employe',actif:true,demo:false,
  matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const PTG=[{id:'p',employe_id:'E1',jour:'2026-09-02',matin_type:'travail',matin_debut:'07:00',
  matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:'18:00',remarque:'',
  approuve:false,confirme:true,saisi_par:'E1'}];
const nav=await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined});
// Hauteur réellement visible dans Safari sur iPhone 13 : barre d'adresse et
// barre d'outils déduites.
const ctx=await nav.newContext({viewport:{width:390,height:664},deviceScaleFactor:3,isMobile:true,hasTouch:true});
const pg=await ctx.newPage();
await pg.addInitScript(({E,PTG})=>{
 localStorage.setItem('hor_token','tok');localStorage.setItem('hor_moi',JSON.stringify(E));
 const rep=o=>new Response(JSON.stringify(o),{status:200,headers:{'Content-Type':'application/json'}});
 window.fetch=async u=>{const n=String(u).split('/rpc/')[1];
  if(n==='mes_pointages')return rep({ok:true,employe:E,pointages:PTG});
  if(n==='messages_lire')return rep({ok:true,messages:[],non_lus:0,fils:[],fil:null,autres_mois:[]});
  return rep({ok:true});};},{E,PTG});
await pg.goto('file:///home/user/horaires/docs/index.html');
await pg.waitForTimeout(1000);
await pg.evaluate(()=>{S.annee=2026;S.mois=9;S.auj='2026-09-07';S.jourSel='2026-09-02';renderEmp();
  ouvrirJour(S.moi.id,'2026-09-02');});
await pg.waitForTimeout(500);
const m = await pg.evaluate(() => {
  const el = document.querySelector('#voile-jour .modale');
  const parts = [];
  for (const c of el.children) {
    if (c.hidden || getComputedStyle(c).display === 'none') continue;
    const r = c.getBoundingClientRect();
    const cs = getComputedStyle(c);
    parts.push((c.id || c.className || c.tagName) + ' : ' + Math.round(r.height) + 'px' +
      ' (marges ' + cs.marginTop + '/' + cs.marginBottom + ')');
  }
  return { contenu: el.scrollHeight, visible: el.clientHeight, fenetre: innerHeight,
    doitDefiler: el.scrollHeight - el.clientHeight, parts };
});
console.log('hauteur du contenu :', m.contenu, 'px · visible :', m.visible, 'px · fenêtre :', m.fenetre);
console.log(m.doitDefiler > 0 ? '→ IL FAUT DÉFILER de ' + m.doitDefiler + ' px' : '→ tient sans défiler');
console.log('\ndétail des blocs :'); m.parts.forEach(p=>console.log('  ' + p));
await pg.screenshot({ path:'/tmp/claude-0/-home-user-horaires/4c57d827-a9fc-5130-ad81-4346fd29ca84/scratchpad/modale-apres.png' });
// Le cas le plus chargé : back office, journée à valider, question posée, alerte
await pg.evaluate(()=>{S.moi.role='admin';S.employes=[S.moi,{id:'E1',prenom:'Sami',nom:'F',role:'employe',actif:true}];
  S.detEmp='E1';S.detMsgs=[{id:'M',role:'admin',jour:'2026-09-02',texte:'Peux-tu préciser la raison des 2h00 de plus ?',quand:'07.09.2026 08:00'}];
  ouvrirJour('E1','2026-09-02');});
await pg.waitForTimeout(400);
const m2 = await pg.evaluate(()=>{const el=document.querySelector('#voile-jour .modale');
  return {c:el.scrollHeight,v:el.clientHeight,d:el.scrollHeight-el.clientHeight,
   corps:document.querySelector('.mj-corps').scrollHeight-document.querySelector('.mj-corps').clientHeight};});
console.log('\ncas le plus chargé (back office + question + alerte) :');
console.log('  fenêtre :', m2.c, 'px ·', m2.d>0?('déborde de '+m2.d+' px'):'tient',
            '| le corps défile de', m2.corps, 'px');
await pg.screenshot({ path:'/tmp/claude-0/-home-user-horaires/4c57d827-a9fc-5130-ad81-4346fd29ca84/scratchpad/modale-charge.png' });
await nav.close();
