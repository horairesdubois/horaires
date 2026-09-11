// La refonte doit reprendre la structure de la maquette tout en conservant
// les parcours réels. Données locales, requêtes externes bloquées.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const LOGO = 'data:image/svg+xml;base64,' + readFileSync(new URL('./fixtures/logo-hugo-dubois.svg', import.meta.url)).toString('base64');
const EMPLOYES = ['Alen', 'Sami', 'Steve'].map((prenom, i) => ({ id: 'E' + (i + 1), prenom,
  nom: 'Essai', metier: 'Dépannage', role: 'employe', actif: true, demo: false,
  matin_debut_def: '08:00', matin_fin_def: '12:00', apm_debut_def: '13:00', apm_fin_def: '17:00' }));
const ADMIN = { id: 'A1', prenom: 'Back Office', nom: '', role: 'admin', actif: true, demo: false };
const COMPTA = { id: 'C1', prenom: 'Fiduciaire', nom: '', role: 'compta', actif: true, demo: false };
const POINTAGES = EMPLOYES.flatMap((e, i) => ['2026-08-31', '2026-09-01', '2026-09-07', '2026-09-14', '2026-09-15'].map(jour => ({
  id: e.id + '-' + jour, employe_id: e.id, jour, matin_type: 'travail', matin_debut: '08:00', matin_fin: '12:00',
  apm_type: 'travail', apm_debut: '13:00', apm_fin: i === 1 ? '17:30' : '17:00',
  approuve: jour < '2026-09-14' || i === 2, confirme: jour < '2026-09-15', remarque: '', saisi_par: e.id
})));
const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
const contexts = [];
const erreurs = [];

async function ecran(role, largeur) {
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: largeur < 600 ? 664 : 900 },
    isMobile: largeur < 600, hasTouch: largeur < 600, serviceWorkers: 'block' });
  contexts.push(ctx);
  await ctx.route(/^https?:\/\//, route => route.abort('blockedbyclient'));
  const pg = await ctx.newPage();
  pg.on('pageerror', erreur => erreurs.push(erreur.message));
  pg.on('dialog', dialogue => dialogue.dismiss());
  await pg.clock.install({ time: new Date('2026-09-15T14:32:00+02:00') });
  await pg.addInitScript(({ role, ADMIN, COMPTA, EMPLOYES, POINTAGES, LOGO }) => {
    const moi = role === 'admin' ? ADMIN : role === 'compta' ? COMPTA : EMPLOYES[0];
    localStorage.setItem('hor_token', 'test-' + role);
    localStorage.setItem('hor_moi', JSON.stringify(moi));
    window.__appels = [];
    window.fetch = async (url, options) => {
      const nom = String(url).split('/rpc/')[1];
      if (!nom) throw new Error('Accès hors simulateur interdit');
      const args = JSON.parse(options?.body || '{}');
      window.__appels.push({ nom, args });
      const prefixe = args.p_annee + '-' + String(args.p_mois).padStart(2, '0');
      const pointages = POINTAGES.filter(p => p.jour.startsWith(prefixe));
      let resultat = { ok: true };
      if (nom === 'marque_lire') resultat = { ok: true, entreprise: 'Hugo Dubois', couleur: '#013384', logo: LOGO };
      if (nom === 'mes_pointages') resultat = { ok: true, employe: EMPLOYES[0], pointages: pointages.filter(p => p.employe_id === 'E1') };
      if (nom === 'admin_donnees' || nom === 'compta_donnees') resultat = { ok: true, entreprise: 'Hugo Dubois',
        employes: [ADMIN, ...EMPLOYES, COMPTA], pointages, moi, msg_non_lus: 0,
        tracabilite_depuis: '2026-01-01', aujourdhui: '2026-09-15' };
      if (nom === 'messages_lire') resultat = { ok: true, messages: [], non_lus: 0,
        fils: EMPLOYES.map(e => ({ employe_id: e.id, nom: e.prenom, non_lus: 0 })), fil: 'E1', autres_mois: [] };
      if (nom === 'retards_saisie') resultat = { ok: true, retards: [], aujourdhui: '2026-09-15' };
      if (nom === 'journal_lire') resultat = { ok: true, lignes: [], acteurs: [] };
      return new Response(JSON.stringify(resultat), { status: 200, headers: { 'Content-Type': 'application/json' } });
    };
  }, { role, ADMIN, COMPTA, EMPLOYES, POINTAGES, LOGO });
  await pg.goto(new URL('../app/index.html', import.meta.url).href);
  await pg.locator(role === 'employe' ? '#v-emp' : '#v-admin').waitFor({ state: 'visible' });
  await pg.waitForFunction(() => S.marqueChargee);
  return pg;
}
async function sansDebordement(pg, contexte) {
  const taille = await pg.evaluate(() => ({ page: document.documentElement.scrollWidth, fenetre: innerWidth }));
  if (taille.page > taille.fenetre + 1) {
    const conteneurs = await pg.evaluate(() => ['#v-admin', '.adm-sidebar', '.adm-espace', '.adm-entete', '.adm-compte', '.adm-contenu', '#ong-equipe', '.equipe-commandes', '.equipe-tableau', '.sr-seul'].map(sel => {
      const r = document.querySelector(sel)?.getBoundingClientRect();
      return { sel, gauche: r?.left, droite: r?.right, largeur: r?.width };
    }));
    console.log('Débordement', contexte, JSON.stringify({ ...taille, conteneurs }));
    await capture(pg, 'debordement-' + taille.fenetre);
  }
  assert(taille.page <= taille.fenetre + 1, contexte + ' : absence de défilement horizontal de la page');
}
async function atteignable(pg, selecteur, contexte) {
  const resultat = await pg.locator(selecteur).evaluate(el => {
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    const touche = document.elementFromPoint(x, y);
    return { largeur: r.width, hauteur: r.height,
      dansEcran: r.left >= 0 && r.right <= innerWidth + 1 && r.top >= 0 && r.bottom <= innerHeight + 1,
      recu: touche === el || el.contains(touche) };
  });
  assert(resultat.dansEcran && resultat.recu, contexte + ' : contrôle visible et atteignable');
  assert(resultat.hauteur >= 40, contexte + ' : cible tactile assez haute');
}
async function capture(pg, nom) {
  await pg.screenshot({ path: new URL('../work/essais/refonte-' + nom + '.png', import.meta.url).pathname });
}
async function afficherOngletBO(pg, nom, mobile) {
  if (mobile) {
    await pg.locator('#adm-menu').click();
    assert.equal(await pg.locator('#adm-menu').getAttribute('aria-expanded'), 'true');
  }
  await pg.locator('#adm-sidebar [data-ong="' + nom + '"]').click();
  await pg.locator('#ong-' + nom).waitFor({ state: 'visible' });
  if (mobile) assert.equal(await pg.locator('#adm-menu').getAttribute('aria-expanded'), 'false', 'Le menu se referme après navigation');
}
const nbJoursBO = pg => pg.locator('.equipe-tableau .grille tr').nth(1).locator('.cellule[data-jour]').count();

try {
  const employe = await ecran('employe', 390);
  assert(await employe.locator('#emp-logo').isVisible(), 'Identité Hugo Dubois visible chez le technicien');
  assert(await employe.locator('#emp-vue-jour').isVisible());
  assert.equal(await employe.locator('#js-heures .emp-demi').count(), 2, 'Matin et après-midi ont chacun leur bloc lisible');
  assert.equal(await employe.locator('#emp-bande button[data-j]').count(), 7, 'Une semaine contient exactement sept jours');
  for (const id of ['emp-nav-aujourdhui', 'btn-tout-mois', 'q-tete']) await atteignable(employe, '#' + id, 'Navigation basse ' + id);
  await sansDebordement(employe, 'Aujourd’hui');
  await capture(employe, 'employe-aujourdhui');
  const semaine = await employe.locator('#emp-bande button[data-j]').first().getAttribute('data-j');
  await employe.locator('#emp-semaine-prev').click();
  const precedente = await employe.locator('#emp-bande button[data-j]').first().getAttribute('data-j');
  assert.equal((new Date(semaine) - new Date(precedente)) / 86400000, 7, 'La flèche recule d’une semaine');
  await employe.locator('#emp-semaine-next').click();
  assert.equal(await employe.locator('#emp-bande button[data-j]').first().getAttribute('data-j'), semaine);
  await employe.locator('#btn-tout-mois').click();
  assert(await employe.locator('#emp-vue-mois').isVisible());
  assert(!(await employe.locator('#emp-vue-jour').isVisible()));
  assert.equal(await employe.locator('#emp-liste .jour-ligne').count(), 30, 'Mon mois conserve toutes les journées');
  assert.match(await employe.locator('#emp-liste').innerText(), /approuvée/i);
  assert.match(await employe.locator('#emp-liste').innerText(), /approbation/i);
  await capture(employe, 'employe-mois');
  await employe.locator('#emp-prev').click();
  await employe.waitForFunction(() => S.mois === 8 && S.pointages.some(p => p.jour === '2026-08-31'));
  assert.equal(await employe.locator('#emp-liste .jour-ligne').count(), 31, 'La navigation recharge le mois précédent');
  await employe.locator('#emp-next').click();
  await employe.waitForFunction(() => S.mois === 9 && S.pointages.some(p => p.jour === '2026-09-14'));
  await employe.locator('#emp-liste [data-jour="2026-09-14"]').click();
  await employe.locator('#voile-jour.ouvert').waitFor({ state: 'visible' });
  assert(await employe.locator('#mj-verrou').isVisible(), 'La refonte ne contourne pas le verrou du jour confirmé');
  await employe.locator('#mj-annuler').click();
  await employe.locator('#q-tete').click();
  assert(await employe.locator('#emp-vue-questions').isVisible());
  assert(!(await employe.locator('#emp-vue-mois').isVisible()));
  assert(await employe.locator('#emp-msg-texte').isVisible(), 'Le fil conserve la saisie de questions');
  await capture(employe, 'employe-questions');
  await employe.locator('#emp-nav-aujourdhui').click();
  assert(await employe.locator('#emp-vue-jour').isVisible());
  assert.equal(await employe.locator('#emp-bande button[data-j]').count(), 7);
  await sansDebordement(employe, 'Retour Aujourd’hui');
  // Une semaine chevauche deux mois : les dates voisines doivent charger
  // leurs données avant de recevoir un statut de pointage.
  await employe.evaluate(() => empChoisirJour('2026-09-01'));
  assert.match(await employe.locator('[data-j="2026-08-31"]').getAttribute('aria-label'), /afficher cette journée/i);
  await employe.locator('[data-j="2026-08-31"]').click();
  await employe.waitForFunction(() => S.mois === 8 && S.pointages.some(p => p.jour === '2026-08-31'));
  assert.match(await employe.locator('#js-etat').innerText(), /approuvée/i);
  await employe.locator('[data-j="2026-09-01"]').click();
  await employe.waitForFunction(() => S.mois === 9 && S.pointages.some(p => p.jour === '2026-09-01'));
  assert.match(await employe.locator('#js-date').innerText(), /1 septembre/i);
  await employe.locator('#emp-nav-aujourdhui').click();
  await employe.setViewportSize({ width: 320, height: 664 });
  await sansDebordement(employe, 'Employé à 320 px');
  for (const id of ['emp-nav-aujourdhui', 'btn-tout-mois', 'q-tete']) await atteignable(employe, '#' + id, 'Navigation à 320 px ' + id);
  assert(await employe.locator('#js-heures .emp-demi strong').evaluateAll(elements => elements.every(el => el.scrollWidth <= el.clientWidth + 1)),
    'Les deux horaires restent lisibles à 320 px');
  await employe.setViewportSize({ width: 390, height: 664 });
  console.log('✓ Employé : navigation basse atteignable, trois vraies vues, semaine navigable et mois complet, verrou conservé');

  const bureau = await ecran('admin', 1440);
  for (const [width,height] of [[1366,768],[1440,900],[1280,720]]) {
    await bureau.setViewportSize({width,height});
    assert(await bureau.evaluate(() => document.documentElement.scrollHeight <= innerHeight + 1), 'Semaine sans défilement vertical sur ' + width + '×' + height);
  }
  await bureau.setViewportSize({width:1440,height:900});

  assert(await bureau.locator('#adm-sidebar').isVisible(), 'Barre latérale visible sur ordinateur');
  assert(await bureau.evaluate(() => document.getElementById('adm-sidebar').getBoundingClientRect().right <=
    document.querySelector('.adm-espace').getBoundingClientRect().left + 1), 'Le menu occupe bien une colonne latérale');
  assert(await bureau.locator('#adm-logo').isVisible(), 'Identité Hugo Dubois visible au bureau');
  assert.equal(await bureau.locator('#adm-sidebar [data-ong]').count(), 5, 'Les cinq sections existantes sont conservées');
  assert(await bureau.locator('#equipe-indicateurs').isVisible(), 'Indicateurs de contrôle dans la vue de travail');
  assert.equal(await bureau.locator('#equipe-semaine').getAttribute('aria-pressed'), 'true', 'La semaine est la vue initiale');
  assert((await nbJoursBO(bureau)) >= 5 && (await nbJoursBO(bureau)) <= 7, 'Tableau hebdomadaire lisible');
  await sansDebordement(bureau, 'Bureau ordinateur');
  await capture(bureau, 'bureau-ordinateur-semaine');
  const periode = await bureau.locator('#equipe-periode').innerText();
  await bureau.locator('#equipe-prev').click();
  assert.notEqual(await bureau.locator('#equipe-periode').innerText(), periode);
  await bureau.locator('#equipe-suiv').click();
  assert.equal(await bureau.locator('#equipe-periode').innerText(), periode);
  await bureau.locator('#equipe-mois').click();
  assert.equal(await bureau.locator('#equipe-mois').getAttribute('aria-pressed'), 'true');
  assert.equal(await nbJoursBO(bureau), 30, 'Le mois complet reste accessible');
  await capture(bureau, 'bureau-ordinateur-mois');
  await bureau.locator('#adm-next').click();
  await bureau.waitForFunction(() => S.mois === 10 && document.querySelector('.equipe-tableau .cellule[data-jour^="2026-10"]'));
  assert.equal(await nbJoursBO(bureau), 31, 'Le mois suivant affiche toutes ses journées');
  await bureau.locator('#adm-prev').click();
  await bureau.waitForFunction(() => S.mois === 9 && document.querySelector('.equipe-tableau .cellule[data-jour^="2026-09"]'));
  for (const nom of ['employes', 'export', 'messages', 'journal', 'equipe']) await afficherOngletBO(bureau, nom, false);
  await bureau.locator('#equipe-semaine').click();
  await bureau.locator('.equipe-tableau .emp-lien').first().click();
  await bureau.locator('#voile-det.ouvert').waitFor({ state: 'visible' });
  assert.match(await bureau.locator('#det-sous').innerText(), /Revue du mois.*septembre 2026/i,
    'La revue annonce explicitement le mois complet depuis la vue semaine');
  assert.equal(await bureau.locator('#det-liste .jour-ligne').count(), 30, 'Le contrôle individuel conserve le détail mensuel');
  await bureau.locator('#det-fermer').click();
  await bureau.evaluate(() => { S.semaineEquipe = '2026-09-01'; S.vueEquipe = 'semaine'; renderEquipe(); });
  assert.equal(await nbJoursBO(bureau), 6, 'Au bord du mois la semaine affiche les six journées de septembre chargées');
  await bureau.locator('#equipe-prev').click();
  await bureau.waitForFunction(() => S.mois === 8 && document.querySelector('.equipe-tableau .cellule[data-jour="2026-08-31"]'));
  assert.equal(await nbJoursBO(bureau), 1, 'Le 31 août est chargé dans sa propre période');
  await bureau.locator('#equipe-suiv').click();
  await bureau.waitForFunction(() => S.mois === 9 && document.querySelector('.equipe-tableau .cellule[data-jour="2026-09-01"]'));
  assert.equal(await nbJoursBO(bureau), 6, 'Le retour en septembre ne fabrique pas de données pour août');
  for (const largeur of [800, 801]) {
    await bureau.setViewportSize({ width: largeur, height: 900 });
    await sansDebordement(bureau, 'Bureau au seuil ' + largeur + ' px');
    assert.equal(await bureau.locator('#adm-menu').isVisible(), largeur === 800, 'Seuil du menu mobile');
    assert.equal(await bureau.locator('.equipe-mobile').isVisible(), largeur === 800, 'Seuil des fiches mobiles');
    assert.equal(await bureau.locator('.equipe-tableau').isVisible(), largeur === 801, 'Seuil du tableau ordinateur');
  }
  await bureau.setViewportSize({ width: 1440, height: 900 });
  console.log('✓ Bureau ordinateur : sidebar, cinq sections, semaine par défaut, mois complet et revue conservés');

  const mobile = await ecran('admin', 390);
  assert.equal(await mobile.locator('#adm-menu').getAttribute('aria-expanded'), 'false');
  await atteignable(mobile, '#adm-menu', 'Menu du bureau mobile');
  assert(await mobile.locator('.equipe-mobile').isVisible());
  assert(!(await mobile.locator('.equipe-tableau').isVisible()));
  assert.equal(await mobile.locator('.equipe-mobile .equipe-fiche').count(), 3);
  await sansDebordement(mobile, 'Bureau mobile');
  await capture(mobile, 'bureau-mobile');
  await mobile.locator('#adm-menu').click();
  for (const nom of ['equipe', 'employes', 'export', 'messages', 'journal']) {
    await atteignable(mobile, '#adm-sidebar [data-ong="' + nom + '"]', 'Menu mobile ' + nom);
  }
  await capture(mobile, 'bureau-mobile-menu');
  await mobile.locator('#adm-menu').click();
  for (const nom of ['employes', 'export', 'messages', 'journal', 'equipe']) await afficherOngletBO(mobile, nom, true);
  await mobile.locator('.equipe-mobile .equipe-fiche').first().click();
  await mobile.locator('#voile-det.ouvert').waitFor({ state: 'visible' });
  await mobile.locator('#det-fermer').click();
  await mobile.setViewportSize({ width: 320, height: 664 });
  await mobile.evaluate(() => window.scrollTo(0, 0));
  await sansDebordement(mobile, 'Bureau à 320 px');
  await atteignable(mobile, '#adm-menu', 'Menu du bureau à 320 px');
  console.log('✓ Bureau mobile : menu tactile complet, fiches d’équipe et contrôle des journées accessibles');

  const compta = await ecran('compta', 1440);
  assert(!(await compta.locator('#ong-btn-journal').isVisible()), 'La refonte ne montre pas le journal à la fiduciaire');
  assert(!(await compta.locator('#mj-approuver').isVisible()), 'La fiduciaire reste en consultation');
  for (const ctx of contexts) for (const page of ctx.pages()) {
    const ecritures = await page.evaluate(() => window.__appels.filter(a => /^(enregistrer_jour|admin_enregistrer_jour|supprimer_jour|admin_supprimer_jour|admin_approuver)$/.test(a.nom)));
    assert.deepEqual(ecritures, [], 'Naviguer ne modifie aucune feuille de temps');
  }
  assert.deepEqual(erreurs, [], 'Aucune erreur JavaScript');
  console.log('✓ Navigation sans écriture d’horaires ni requête réelle ; rôles conservés');
} finally {
  for (const ctx of contexts) await ctx.close();
  await navigateur.close();
}
