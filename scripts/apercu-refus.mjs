// Aperçu autonome sur données fictives. Aucun appel vers Supabase.
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
const dir=new URL('../work/apercu-refus/',import.meta.url);mkdirSync(dir,{recursive:true});
const bootstrap=`
const roleEssai=new URLSearchParams(location.search).get('role')||'admin';
const adminEssai={id:'A1',prenom:'Back Office',nom:'',role:'admin',actif:true};
const techEssai={id:'E1',prenom:'Steve',nom:'Essai',role:'employe',actif:true,metier:'Dépannage',matin_debut_def:'08:00',matin_fin_def:'12:00',apm_debut_def:'13:00',apm_fin_def:'17:00'};
const moiEssai=roleEssai==='employe'?techEssai:roleEssai==='compta'?{id:'C1',prenom:'Fiduciaire',role:'compta',actif:true}:adminEssai;
let pointageEssai=JSON.parse(localStorage.getItem('refus_fixture')||'null')||{employe_id:'E1',jour:'2026-09-14',matin_type:'travail',matin_debut:'08:00',matin_fin:'12:00',apm_type:'travail',apm_debut:'13:00',apm_fin:'19:00',remarque:'Dépannages de la journée',approuve:false,confirme:true,minutes_refusees:0,motif_refus:null,version_decision:'1'};
localStorage.setItem('hor_token','essai-'+roleEssai);localStorage.setItem('hor_moi',JSON.stringify(moiEssai));
window.fetch=async(url,opt)=>{
 const nom=String(url).split('/rpc/')[1],a=JSON.parse(opt?.body||'{}'); let r={ok:true};
 if(['mes_pointages','admin_donnees','compta_donnees'].includes(nom)) r={ok:true,employe:techEssai,moi:moiEssai,employes:[adminEssai,techEssai],pointages:[pointageEssai],entreprise:'Aperçu fictif · horaires',msg_non_lus:0,tracabilite_depuis:'2026-01-01',aujourdhui:'2026-09-15'};
 else if(nom==='messages_lire') r={ok:true,messages:[],non_lus:0,fils:[],fil:null,autres_mois:[]};
 else if(nom==='retards_saisie') r={ok:true,retards:[],aujourdhui:'2026-09-15'};
 else if(nom==='admin_decider_heures') {
   if(roleEssai!=='admin') r={ok:false,erreur:'session'};
   else if(a.p_version!==pointageEssai.version_decision) r={ok:false,erreur:'Version périmée'};
   else {Object.assign(pointageEssai,{approuve:true,minutes_refusees:600-a.p_minutes_approuvees,motif_refus:600-a.p_minutes_approuvees?a.p_motif:null,approuve_le:'15.09.2026',version_decision:String(Number(pointageEssai.version_decision)+1)});localStorage.setItem('refus_fixture',JSON.stringify(pointageEssai));}
 } else if(nom==='admin_approuver') {pointageEssai.approuve=a.p_approuve; if(!a.p_approuve)Object.assign(pointageEssai,{confirme:false,minutes_refusees:0,motif_refus:null}); localStorage.setItem('refus_fixture',JSON.stringify(pointageEssai));}
 else if(nom==='demande_modification') {pointageEssai.demande_etat='attente';pointageEssai.demande_motif=a.p_motif;localStorage.setItem('refus_fixture',JSON.stringify(pointageEssai));}
 else if(!['marque_lire','journal_noter','messages_marquer_lus'].includes(nom)) throw Error('RPC non simulée : '+nom);
 return new Response(JSON.stringify(r),{status:200,headers:{'Content-Type':'application/json'}});
};
`;
let html=readFileSync(new URL('../app/index.html',import.meta.url),'utf8');
html=html.replace('<head>','<head><meta http-equiv="Content-Security-Policy" content="default-src \'self\' data: \'unsafe-inline\'; connect-src \'none\'">');
html=html.replace('<script>','<script>'+bootstrap+'\n');
html=html.replace('</body>',`<script>
setTimeout(async()=>{S.annee=2026;S.mois=9;S.auj='2026-09-15';await charger();if(roleEssai!=='compta')ouvrirJour('E1','2026-09-14');},200);
</script></body>`);
writeFileSync(new URL('index.html',dir),html);
console.log('Aperçu fictif généré dans work/apercu-refus');
