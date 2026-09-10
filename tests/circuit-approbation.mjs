// Circuit de confirmation, demande d'ouverture et approbation.
// Serveur intégralement simulé : aucune connexion aux API ni donnée réelle.
// Les assertions font échouer la suite en cas de régression du verrouillage.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const ADMIN = { id: 'A1', prenom: 'Back Office', nom: '', role: 'admin', actif: true, demo: false };
const EMPLOYE = { id: 'E1', prenom: 'Technicien', nom: 'Essai', role: 'employe', actif: true,
  demo: false, metier: 'Dépannage', matin_debut_def: '08:00', matin_fin_def: '12:00',
  apm_debut_def: '13:00', apm_fin_def: '17:00' };
const COMPTA = { id: 'C1', prenom: 'Fiduciaire', nom: '', role: 'compta', actif: true, demo: false };
const creerJour = (jour, extra = {}) => ({ id: jour, employe_id: EMPLOYE.id, jour,
  matin_type: 'travail', matin_debut: '08:00', matin_fin: '12:00',
  apm_type: 'travail', apm_debut: '13:00', apm_fin: '17:00', remarque: '',
  approuve: false, confirme: true, saisi_par: EMPLOYE.id,
  demande_etat: null, demande_motif: null, demande_reponse: null, ...extra });
const serveur = {
  pointages: [creerJour('2026-09-01', { approuve: true, approuve_le: '02.09.2026' }),
    creerJour('2026-09-02'), creerJour('2026-09-03', { confirme: false, saisi_par: ADMIN.id })],
  appels: [], inconnus: []
};
const jour = date => serveur.pointages.find(p => p.jour === date);
const appels = nom => serveur.appels.filter(a => a.nom === nom);

// Ce simulateur représente le contrat attendu par l'interface. La protection
// SQL est vérifiée séparément par les scénarios de supabase/tests/.
async function repondre(nom, args) {
  serveur.appels.push({ nom, args: structuredClone(args) });
  const p = jour(args.p_jour);
  switch (nom) {
    case 'mes_pointages':
      return { ok: true, employe: EMPLOYE, pointages: serveur.pointages };
    case 'admin_donnees':
    case 'compta_donnees':
      return { ok: true, entreprise: 'Entreprise de test', employes: [ADMIN, EMPLOYE, COMPTA],
        pointages: serveur.pointages, moi: nom === 'compta_donnees' ? COMPTA : ADMIN,
        msg_non_lus: 0, tracabilite_depuis: '2026-01-01', aujourdhui: '2026-09-10' };
    case 'messages_lire':
      return { ok: true, messages: [], non_lus: 0, fils: [], fil: null, autres_mois: [] };
    case 'retards_saisie':
      return { ok: true, retards: [], aujourdhui: '2026-09-10' };
    case 'marque_lire':
    case 'journal_noter':
    case 'messages_marquer_lus':
      return { ok: true };
    case 'demande_modification':
      assert(p && (p.approuve || p.confirme), 'Une demande concerne une journée verrouillée');
      assert.notEqual(p.demande_etat, 'attente', 'Pas de demande en double');
      Object.assign(p, { demande_etat: 'attente', demande_motif: args.p_motif,
        demande_le: '10.09.2026 09:00', demande_reponse: null });
      return { ok: true };
    case 'admin_repondre_demande':
      assert.equal(args.p_token, 'tok-admin');
      assert.equal(p.demande_etat, 'attente');
      Object.assign(p, { demande_etat: args.p_accorde ? 'accordee' : 'refusee',
        demande_reponse: args.p_reponse });
      if (args.p_accorde) Object.assign(p, { approuve: false, confirme: false, approuve_le: null });
      return { ok: true };
    case 'enregistrer_jour': {
      if (p && (p.confirme || p.approuve)) return { ok: false, erreur: 'Journée verrouillée' };
      const cible = p || creerJour(args.p_jour);
      for (const champ of ['matin_type', 'matin_debut', 'matin_fin', 'apm_type', 'apm_debut', 'apm_fin', 'remarque']) {
        cible[champ] = args['p_' + champ];
      }
      Object.assign(cible, { confirme: true, approuve: false, demande_etat: null, saisi_par: EMPLOYE.id });
      if (!p) serveur.pointages.push(cible);
      return { ok: true };
    }
    case 'admin_approuver':
      assert.equal(args.p_token, 'tok-admin');
      if (args.p_approuve && (!p?.confirme || p.demande_etat === 'attente')) {
        return { ok: false, erreur: 'Confirmation du technicien requise' };
      }
      if (p) Object.assign(p, { approuve: args.p_approuve,
        approuve_le: args.p_approuve ? '10.09.2026' : null });
      return { ok: true };
    default:
      serveur.inconnus.push(nom);
      throw new Error('RPC non simulée : ' + nom);
  }
}

const navigateur = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
const erreursJS = [];
let acceptation = true;
const dialogues = [];
const contexts = [];
async function ecran(role, largeur = 390) {
  const ctx = await navigateur.newContext({ viewport: { width: largeur, height: largeur < 600 ? 664 : 900 },
    isMobile: largeur < 600, hasTouch: largeur < 600, serviceWorkers: 'block' });
  contexts.push(ctx);
  // Même les polices, images ou requêtes accidentelles ne sortent pas du test.
  await ctx.route(/^https?:\/\//, route => route.abort('blockedbyclient'));
  const page = await ctx.newPage();
  page.on('pageerror', e => erreursJS.push(e.message));
  page.on('dialog', async d => {
    dialogues.push({ type: d.type(), message: d.message() });
    if (d.type() === 'confirm' && !acceptation) await d.dismiss(); else await d.accept();
  });
  await page.exposeFunction('__serveurEssai', repondre);
  await page.clock.install({ time: new Date('2026-09-10T09:00:00+02:00') });
  await page.addInitScript(({ moi, role }) => {
    localStorage.setItem('hor_token', 'tok-' + role);
    localStorage.setItem('hor_moi', JSON.stringify(moi));
    window.fetch = async (url, options) => {
      const nom = String(url).split('/rpc/')[1];
      if (!nom) throw new Error('Requête réseau hors simulateur interdite');
      const args = options?.body ? JSON.parse(options.body) : {};
      const resultat = await window.__serveurEssai(nom, args);
      return new Response(JSON.stringify(resultat), { status: 200,
        headers: { 'Content-Type': 'application/json' } });
    };
  }, { moi: role === 'admin' ? ADMIN : role === 'compta' ? COMPTA : EMPLOYE, role });
  await page.goto(new URL('../app/index.html', import.meta.url).href);
  await page.locator(role === 'employe' ? '#v-emp' : '#v-admin').waitFor({ state: 'visible' });
  await page.evaluate(async () => { S.annee = 2026; S.mois = 9; S.auj = '2026-09-10'; await charger(); });
  return page;
}
async function ouvrir(page, date) {
  await page.evaluate(j => ouvrirJour('E1', j), date);
  await page.locator('#voile-jour.ouvert').waitFor({ state: 'visible' });
}
async function verrouille(page, message) {
  for (const id of ['mj-md', 'mj-mf', 'mj-ad', 'mj-af', 'mj-rem', 'mj-statut-m', 'mj-statut-a']) {
    assert(await page.locator('#' + id).isDisabled(), message + ' : ' + id + ' verrouillé');
  }
  for (const id of ['mj-save', 'mj-suppr', 'mj-defaut']) {
    assert(!(await page.locator('#' + id).isVisible()), message + ' : ' + id + ' masqué');
  }
  assert(await page.locator('#mj-verrou').isVisible(), message + ' : explication visible');
  const avant = serveur.appels.length;
  // Vérifie aussi les gardes des gestionnaires, pas seulement les boutons.
  await page.evaluate(async () => { await sauverJour(); await supprimerJour(); });
  assert.equal(serveur.appels.length, avant, message + ' : aucune écriture déclenchée');
}
async function rafraichir(page) {
  await page.evaluate(async () => { fermerJour(); fermerDetails(); await charger(); });
}
async function demander(page, motif) {
  await page.locator('#mj-dem-ouvrir').click();
  await page.locator('#mj-dem-motif').fill(motif);
  await page.locator('#mj-dem-envoyer').click();
  await page.locator('#voile-jour.ouvert').waitFor({ state: 'hidden' });
}
async function etatJour(page, date, attendu) {
  await page.evaluate(j => { S.vueEmp = 'aujourdhui'; S.jourSel = j; renderEmp(); }, date);
  assert(await page.locator('#js-etat').isVisible(), 'La carte du jour est affichée');
  assert.match(await page.locator('#js-etat').innerText(), attendu, 'Statut lisible sur la carte du jour');
  assert.match(await page.locator('[data-j="' + date + '"]').getAttribute('aria-label'), attendu,
    'Statut également accessible sur la bande de la semaine');
}

try {
  const employe = await ecran('employe');
  await etatJour(employe, '2026-09-01', /approuvée/i);
  await etatJour(employe, '2026-09-02', /approbation/i);
  await etatJour(employe, '2026-09-03', /confirmer/i);
  await employe.locator('#btn-tout-mois').click();
  assert.match(await employe.locator('#emp-liste [data-jour="2026-09-01"]').innerText(), /approuvée/i);
  assert.match(await employe.locator('#emp-liste [data-jour="2026-09-02"]').innerText(), /approbation/i);
  assert.match(await employe.locator('#emp-liste [data-jour="2026-09-03"]').innerText(), /confirmer/i);
  assert.match(await employe.locator('#carte-mois').innerText(), /approuvée/i);
  assert.match(await employe.locator('#carte-mois').innerText(), /approbation/i);
  await employe.screenshot({ path: new URL('../work/essais/approbation-employe-mobile.png', import.meta.url).pathname,
    fullPage: true });
  console.log('✓ Statuts distincts sur la carte, la bande accessible, le détail et le résumé du mois');

  await ouvrir(employe, '2026-09-01');
  await verrouille(employe, 'Journée approuvée');
  await ouvrir(employe, '2026-09-02');
  await verrouille(employe, 'Journée confirmée, encore en approbation');
  assert(await employe.locator('#mj-dem-ouvrir').isVisible());
  const nbDemandes = appels('demande_modification').length;
  await employe.locator('#mj-dem-ouvrir').click();
  await employe.locator('#mj-dem-envoyer').click();
  assert.equal(appels('demande_modification').length, nbDemandes, 'Motif vide refusé localement');
  assert(dialogues.some(d => /expliquez/i.test(d.message)));
  await ouvrir(employe, '2026-09-02');
  await demander(employe, 'Dépannage terminé à 17 h 30, fin à corriger.');
  assert.equal(jour('2026-09-02').demande_etat, 'attente');
  await ouvrir(employe, '2026-09-02');
  await verrouille(employe, 'Demande en attente');
  assert(!(await employe.locator('#mj-dem-ouvrir').isVisible()), 'Pas de demande en double');
  assert.match(await employe.locator('#mj-dem-etat').innerText(), /en attente/i);
  console.log('✓ Confirmation et approbation verrouillent immédiatement ; la demande attend la réponse du bureau');

  const bureau = await ecran('admin');
  await bureau.locator('[data-dem="E1|2026-09-02"]').click();
  assert.match(await bureau.locator('#mj-dem-admin-txt').innerText(), /17 h 30/);
  assert(await bureau.locator('#mj-approuver').isDisabled() || !(await bureau.locator('#mj-approuver').isVisible()),
    'Le bureau traite la demande de correction avant de pouvoir approuver');
  await bureau.locator('#mj-dem-rep').fill('Merci de préciser la référence de l’intervention.');
  await bureau.locator('#mj-dem-refuser').click();
  await bureau.locator('#voile-jour.ouvert').waitFor({ state: 'hidden' });
  await rafraichir(employe);
  await ouvrir(employe, '2026-09-02');
  await verrouille(employe, 'Demande refusée');
  assert.match(await employe.locator('#mj-dem-etat').innerText(), /refusée/i);
  assert.match(await employe.locator('#mj-dem-etat').innerText(), /référence/i);
  await demander(employe, 'Intervention fictive HD-TEST, départ à 17 h 30.');
  await rafraichir(bureau);
  await bureau.locator('[data-dem="E1|2026-09-02"]').click();
  await bureau.locator('#mj-dem-rep').fill('Correction autorisée, merci de confirmer ensuite.');
  await bureau.locator('#mj-dem-accorder').click();
  await bureau.locator('#voile-jour.ouvert').waitFor({ state: 'hidden' });
  await rafraichir(employe);
  await ouvrir(employe, '2026-09-02');
  assert(!(await employe.locator('#mj-af').isDisabled()), 'Accord : heure modifiable');
  assert(await employe.locator('#mj-save').isVisible(), 'Accord : confirmation disponible');
  await employe.locator('#mj-af').fill('17:30');
  await employe.locator('#mj-rem').fill('Dépannage HD-TEST terminé à 17 h 30.');
  await employe.locator('#mj-save').click();
  await employe.locator('#voile-jour.ouvert').waitFor({ state: 'hidden' });
  const sauvegarde = appels('enregistrer_jour').at(-1);
  assert.equal(sauvegarde.args.p_apm_fin, '17:30');
  assert.equal(jour('2026-09-02').confirme, true);
  assert.equal(jour('2026-09-02').approuve, false);
  await etatJour(employe, '2026-09-02', /approbation/i);
  await ouvrir(employe, '2026-09-02');
  await verrouille(employe, 'Correction reconfirmée');
  console.log('✓ Refus expliqué sans déverrouiller ; accord puis correction reconfirmée et reverrouillée');

  await rafraichir(bureau);
  await ouvrir(bureau, '2026-09-03');
  assert(await bureau.locator('#mj-approuver').isDisabled() || !(await bureau.locator('#mj-approuver').isVisible()),
    'Le bureau ne valide pas une journée encore non confirmée par le technicien');
  await ouvrir(bureau, '2026-09-02');
  const nbApprobations = appels('admin_approuver').length;
  acceptation = false;
  await bureau.locator('#mj-approuver').click();
  assert.equal(appels('admin_approuver').length, nbApprobations, 'Annuler le contrôle ne valide rien');
  acceptation = true;
  await bureau.locator('#mj-approuver').click();
  await bureau.locator('#voile-jour.ouvert').waitFor({ state: 'hidden' });
  assert.equal(jour('2026-09-02').approuve, true, 'Le contrôle confirmé valide la correction');
  await rafraichir(employe);
  await etatJour(employe, '2026-09-02', /approuvée/i);
  await ouvrir(employe, '2026-09-02');
  await verrouille(employe, 'Correction approuvée par le bureau');
  console.log('✓ Approbation réservée aux jours confirmés, confirmation annulable, résultat visible chez l’employé');

  await rafraichir(bureau);
  assert(await bureau.locator('#ong-equipe .equipe-mobile').isVisible(), 'Fiches d’équipe visibles sur téléphone');
  assert(!(await bureau.locator('#ong-equipe .grille').isVisible()), 'Le tableau large est replié sur téléphone');
  const etapes = await bureau.locator('#ong-equipe .etapes-controle').innerText();
  assert.match(etapes, /confirm/i, 'Étape de confirmation du technicien expliquée');
  assert.match(etapes, /contrôl/i, 'Étape de contrôle du bureau expliquée');
  assert.match(etapes, /approuv|approbation/i, 'Étape d’approbation du bureau expliquée');
  assert(await bureau.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1),
    'Le bureau mobile ne déborde pas horizontalement');
  await bureau.locator('#ong-equipe .equipe-fiche').first().click();
  await bureau.locator('#voile-det.ouvert').waitFor({ state: 'visible' });
  assert.match(await bureau.locator('#det-liste').innerText(), /approuvée/i);
  await bureau.locator('#det-fermer').click();
  await bureau.screenshot({ path: new URL('../work/essais/approbation-bureau-mobile.png', import.meta.url).pathname,
    fullPage: true });
  const bureauOrdi = await ecran('admin', 1440);
  assert(await bureauOrdi.locator('#ong-equipe .grille').isVisible(), 'Tableau visible sur ordinateur');
  assert(!(await bureauOrdi.locator('#ong-equipe .equipe-mobile').isVisible()), 'Les fiches mobiles sont repliées sur ordinateur');
  await bureauOrdi.screenshot({ path: new URL('../work/essais/approbation-bureau-ordinateur.png', import.meta.url).pathname,
    fullPage: true });
  const compta = await ecran('compta', 1440);
  assert(!(await compta.locator('#mj-approuver').isVisible()), 'La fiduciaire reste en lecture seule');
  assert.deepEqual(erreursJS, [], 'Aucune erreur JavaScript');
  assert.deepEqual(serveur.inconnus, [], 'Tous les appels restent dans le simulateur');
  console.log('✓ Bureau ordinateur et fiduciaire ; aucune API réelle appelée, aucune erreur JavaScript');
} finally {
  for (const ctx of contexts) await ctx.close();
  await navigateur.close();
}
