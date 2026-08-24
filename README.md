# ⏱️ Horaires — pointage des heures & feuilles de temps

Application de pointage maison (style Jibble) pour l'entreprise : les techniciens
saisissent leurs heures depuis leur téléphone, la direction contrôle, **valide**
les feuilles de temps, puis exporte un fichier Excel complet pour la comptable.
100 % gratuite : hébergée sur le plan gratuit de Supabase, aucun serveur à payer.

## Accès

- **Application** : https://ijfkttmezryvbjsuysbl.supabase.co/functions/v1/horaires
- Chaque personne se connecte avec son **code PIN personnel** (communiqué en privé).
- L'accès « Direction » ouvre l'interface d'administration ; les autres accès
  ouvrent l'interface de saisie de l'employé.

## Ce que fait l'application

### Côté employé (mobile)
- Bouton **« Pointer »** : un geste enregistre l'heure actuelle dans la bonne
  case (début matin → fin matin → début après-midi → fin après-midi).
- Saisie par demi-journée : heures de travail **ou** absence
  (vacances, maladie, accident, jour férié, armée/PC, formation, autre).
- Bouton **« Journée type »** : remplit la journée standard (modifiable par
  employé dans l'admin).
- Total du mois et compteurs d'absences en direct. Navigation par mois.
- Un jour **validé par la direction est verrouillé** (plus modifiable).

### Côté direction
- **Feuilles de temps** : tableau façon Jibble (une ligne par employé, une
  colonne par jour), total du mois, statut « En attente / Validé »,
  bouton **Valider le mois** (ou déverrouiller), correction possible de
  n'importe quelle case.
- **Employés** : ajouter/modifier (nom, métier, journée type, code PIN,
  activer/désactiver).
- **Export comptable** : fichier **Excel (.xlsx)** du mois — un onglet
  récapitulatif (heures, vacances, maladie, accident… par employé) + un onglet
  détaillé par employé (jour par jour, totaux, mention de validation,
  lignes de signature). Prêt à envoyer à la comptable.

## Architecture (tout est gratuit)

| Élément | Où | Rôle |
|---|---|---|
| Base de données | Supabase (projet `horaires`, région Zurich) | tables `employes`, `pointages`, `sessions`, `parametres`, `pages` |
| API | Fonctions SQL RPC (`supabase/migrations/`) | authentification par PIN + jeton, règles métier, validation direction |
| Interface | `app/index.html` (une seule page) | servie par la fonction Edge `horaires` depuis la table `pages` |
| Excel | xlsx-js-style (CDN, dans le navigateur) | génération du fichier pour la comptable |

Sécurité : RLS activé **sans policy** sur toutes les tables → aucune lecture ni
écriture directe possible avec la clé publique. Tout passe par des fonctions
`SECURITY DEFINER` qui exigent un PIN valide puis un jeton de session. Les PIN
sont stockés hachés (bcrypt). Anti-force-brute : 20 tentatives/minute maximum.

## Mettre à jour l'interface

1. Modifier `app/index.html` (les valeurs `__SUPABASE_URL__` / `__ANON_KEY__`
   sont remplacées à la publication).
2. Publier : `DEPLOY_SECRET=... python3 scripts/publier_page.py`
   (le secret est dans la table `parametres`, clé `deploy_secret`,
   visible dans le tableau de bord Supabase → Table Editor).

Pas besoin de redéployer la fonction Edge : elle relit la page toutes les 60 s.

## Maintien en éveil (important, plan gratuit)

Supabase met en pause un projet gratuit après ~1 semaine sans requête
(p. ex. pendant les vacances de l'entreprise). Le workflow GitHub
`.github/workflows/keepalive.yml` envoie un ping tous les 3 jours pour
l'empêcher. Si le projet est quand même en pause un jour : tableau de bord
Supabase → projet `horaires` → « Restore ».

## Codes PIN oubliés

La direction peut changer le PIN de n'importe qui dans l'onglet **Employés**.
Si le PIN de la direction est perdu : tableau de bord Supabase → SQL Editor →

```sql
update employes
   set pin_hash = extensions.crypt('NOUVEAU_PIN', extensions.gen_salt('bf', 8))
 where role = 'admin';
```

## Bon à savoir

- Les employés (avec leurs PIN) ont été créés directement en base — aucun PIN
  n'est stocké dans ce dépôt. Pour promouvoir quelqu'un admin :
  `update employes set role = 'admin' where prenom = '...';` (SQL Editor).
- « Valider le mois » verrouille **toutes** les saisies existantes du mois,
  y compris la journée en cours : à faire de préférence en fin de mois
  (sinon déverrouiller le jour concerné depuis la case du tableau).
- Un employé désactivé ne peut plus se connecter, mais ses heures déjà
  saisies restent visibles dans les feuilles de temps et exportables.
