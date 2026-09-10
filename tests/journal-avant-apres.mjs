// Le journal doit dire CE QUI a changé, pas seulement qu'il y a eu un changement.
// Lancer : npm i playwright && node tests/journal-avant-apres.mjs
import { chromium } from 'playwright';

const A = { id:'A1', prenom:'Back Office', nom:'', role:'admin', actif:true, demo:false,
  matin_debut_def:'08:00', matin_fin_def:'12:00', apm_debut_def:'13:00', apm_fin_def:'17:00' };

// Les formes de `detail` que produit désormais _trg_journal_pointages.
const h = (m, a, min, rem = '') => ({ m, a, min, rem });
const JR = [
  { id:1, acteur_nom:'Steve Carvalho', acteur_role:'employe', action:'saisie', cible:'07.09.2026',
    detail:{ employe:'Steve', par:'technicien', horaire:'tapé',
             apres:h('08:00–12:00','13:00–17:00',480) },
    jour:'lundi 7 septembre', heure:'19:13' },

  // Le cas qui motive tout : des heures ajoutées après coup.
  { id:2, acteur_nom:'Steve Carvalho', acteur_role:'employe', action:'modification', cible:'07.09.2026',
    detail:{ employe:'Steve', par:'technicien', horaire:'tapé',
             avant:h('08:00–12:00','13:00–17:00',480),
             apres:h('08:00–12:00','13:00–18:30',570,'urgence chantier'),
             delta:90, champs:['après-midi','remarque'], etait_approuve:false },
    jour:'lundi 7 septembre', heure:'19:20' },

  // Le même, mais après validation : c'est l'alerte rouge.
  { id:3, acteur_nom:'Back Office', acteur_role:'admin', action:'modification', cible:'31.08.2026',
    detail:{ employe:'Steve', par:'back office', horaire:'tapé',
             avant:h('08:00–12:00','13:00–19:00',600,'déblocage'),
             apres:h('08:00–12:00','13:00–17:00',480,''),
             delta:-120, champs:['après-midi','remarque'], etait_approuve:true },
    jour:'lundi 7 septembre', heure:'19:30' },

  { id:4, acteur_nom:'Back Office', acteur_role:'admin', action:'validation', cible:'07.09.2026',
    detail:{ employe:'Steve', apres:h('08:00–12:00','13:00–18:30',570) },
    jour:'lundi 7 septembre', heure:'19:35' },

  { id:5, acteur_nom:'Steve Carvalho', acteur_role:'employe', action:'confirmation', cible:'04.09.2026',
    detail:{ employe:'Steve', apres:h('08:00–12:00','13:00–17:00',480) },
    jour:'lundi 7 septembre', heure:'19:40' },

  { id:6, acteur_nom:'Back Office', acteur_role:'admin', action:'validation_mois', cible:'09.2026',
    detail:{ employe:'Steve', n:18 }, jour:'lundi 7 septembre', heure:'19:45' },

  // Une demi-journée d'absence doit se lire en toutes lettres.
  { id:7, acteur_nom:'Back Office', acteur_role:'admin', action:'modification', cible:'02.09.2026',
    detail:{ employe:'Alen', par:'back office', horaire:'tapé',
             avant:h('08:00–12:00','13:00–17:00',480),
             apres:h('Maladie','13:00–17:00',240),
             delta:-240, champs:['matin'], etait_approuve:false },
    jour:'lundi 7 septembre', heure:'19:50' },

  { id:8, acteur_nom:'Back Office', acteur_role:'admin', action:'suppression', cible:'03.09.2026',
    detail:{ employe:'Alen', avant:h('08:00–12:00','13:00–17:00',480) },
    jour:'lundi 7 septembre', heure:'19:55' },

  // La chaîne complète d'une demande d'ouverture.
  { id:10, acteur_nom:'Steve Carvalho', acteur_role:'employe', action:'demande_modification',
    cible:'07.09.2026', detail:{ employe:'Steve', motif:'Oubli de 2h de dépannage le soir',
      appareil:'iPhone', etat:h('08:00–12:00','13:00–17:00',480) },
    jour:'lundi 7 septembre', heure:'20:05' },
  { id:11, acteur_nom:'Back Office', acteur_role:'admin', action:'deblocage_accorde',
    cible:'07.09.2026', detail:{ employe:'Steve', motif:'Oubli de 2h de dépannage le soir',
      reponse:'D’accord, corrige et je revalide' }, jour:'lundi 7 septembre', heure:'20:06' },
  { id:12, acteur_nom:'Back Office', acteur_role:'admin', action:'deblocage_refuse',
    cible:'01.09.2026', detail:{ employe:'Alen', motif:'je me suis trompé',
      reponse:'Mois déjà clôturé' }, jour:'lundi 7 septembre', heure:'20:07' },

  // Une saisie tardive, avec heures en plus, depuis un téléphone.
  { id:13, acteur_nom:'Alen Krasniqi', acteur_role:'employe', action:'saisie', cible:'28.08.2026',
    detail:{ employe:'Alen', par:'technicien', horaire:'tapé',
      apres:h('08:00–12:00','13:00–19:00',600), retard:9, sup:120, appareil:'Android' },
    jour:'lundi 7 septembre', heure:'20:08' },
  { id:14, acteur_nom:'Steve Carvalho', acteur_role:'employe', action:'saisie', cible:'09.09.2026',
    detail:{ employe:'Steve', par:'technicien', horaire:'tapé',
      apres:h('08:00–12:00','13:00–17:00',480), retard:0, sup:0, appareil:'iPhone' },
    jour:'lundi 7 septembre', heure:'20:09' },
  { id:15, acteur_nom:'inconnu', acteur_role:'', action:'connexion_echouee', cible:'',
    detail:{ n:14, appareil:'ordinateur' }, jour:'lundi 7 septembre', heure:'20:10' },

  // Une vieille ligne, d'avant la migration : elle ne doit pas casser l'affichage.
  { id:9, acteur_nom:'Sami Ferjani', acteur_role:'employe', action:'modification', cible:'08.09.2026',
    detail:{ par:'technicien', employe:'Sami', horaire:'tapé' },
    jour:'lundi 7 septembre', heure:'20:00' },
];

const nav = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
const ctx = await nav.newContext({ viewport:{ width:390, height:844 }, deviceScaleFactor:2,
  isMobile:true, hasTouch:true });
const pg = await ctx.newPage();
pg.on('pageerror', e => console.log('  !! ERREUR JS :', e.message));
await pg.addInitScript(({ A, JR }) => {
  localStorage.setItem('hor_token','tok'); localStorage.setItem('hor_moi', JSON.stringify(A));
  const rep = o => new Response(JSON.stringify(o), { status:200, headers:{ 'Content-Type':'application/json' } });
  window.fetch = async u => {
    const n = String(u).split('/rpc/')[1];
    if (n === 'admin_donnees') return rep({ ok:true, entreprise:'Essai', employes:[A],
      pointages:[], msg_non_lus:0, tracabilite_depuis:'2026-01-01', aujourdhui:'2026-09-07' });
    if (n === 'messages_lire') return rep({ ok:true, messages:[], non_lus:0, fils:[], fil:null, autres_mois:[] });
    if (n === 'retards_saisie') return rep({ ok:true, retards:[], aujourdhui:'2026-09-07' });
    if (n === 'journal_lire') return rep({ ok:true, lignes:JR, acteurs:[] });
    return rep({ ok:true });
  };
}, { A, JR });
await pg.goto(new URL('../app/index.html', import.meta.url).href);
await pg.waitForTimeout(1100);
await pg.evaluate(() => { S.annee = 2026; S.mois = 9; S.ongletAdmin = 'journal'; renderAdmin(); });
await pg.waitForTimeout(600);

const lignes = await pg.evaluate(() => [...document.querySelectorAll('#ong-journal .jr-l')].map(l => ({
  txt: l.querySelector('.jr-t').innerText.replace(/\n+/g, ' | '),
  delta: [...l.querySelectorAll('.jr-delta')].map(d => d.textContent).join(' + ') || '—',
})));
console.log('LIGNES DU JOURNAL\n');
for (const l of lignes) {
  console.log('  ' + l.txt);
  console.log('      écart : ' + l.delta + '\n');
}
const barre = await pg.evaluate(() =>
  [...document.querySelectorAll('#ong-journal .jr-diff .av')].map(e =>
    getComputedStyle(e).textDecorationLine).join(','));
console.log('l’état précédent est barré :', barre);
await pg.screenshot({ path: new URL('../work/essais/journal.png', import.meta.url).pathname, fullPage: true });
await nav.close();
