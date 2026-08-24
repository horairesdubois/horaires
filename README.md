# ⏱️ Horaires — pointage des heures & feuilles de temps

Application de pointage maison (style Jibble) pour l'entreprise : les techniciens
saisissent leurs heures depuis leur téléphone, la direction contrôle, **valide**
les feuilles de temps, puis exporte un fichier Excel complet pour la comptable.
100 % gratuite : hébergée sur le plan gratuit de Supabase, aucun serveur à payer.

## Accès

- **Application** : https://horairesdubois.github.io/horaires/
  (l'ancienne adresse `…supabase.co/functions/v1/horaires` redirige automatiquement ici)
- Chaque personne se connecte avec son **code PIN personnel** (communiqué en privé).
- L'accès « Direction » ouvre l'interface d'administration ; les autres accès
  ouvrent l'interface de saisie de l'employé.

> Pourquoi GitHub Pages ? Supabase bloque le rendu HTML sur son domaine
> `*.supabase.co` (protection anti-hameçonnage ; la page s'affiche en texte
> brut). Supabase héberge donc la base et l'API, GitHub Pages la page web.
> Pages exige que le dépôt soit public (ou un compte GitHub payant) —
> le dépôt ne contient aucun secret : pas de PIN, pas de données, et la clé
> `anon` est publique par conception.

## Ce que fait l'application

### Côté employé (mobile)
- Bouton **« Journée type »** : un appui enregistre la journée standard du
  jour même (08:00–12:00 · 13:00–17:00, réglable par employé dans l'admin).
- **Aujourd'hui toujours affiché en avant** ; les jours précédents/suivants
  du mois se déplient à la demande.
- Saisie par demi-journée : heures de travail **ou** absence
  (vacances, maladie, accident, jour férié, armée/PC, formation, autre) ;
  les champs d'heure vides se pré-remplissent au toucher.
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
| Base de données | Supabase (projet `horaires`, région Zurich) | tables `employes`, `pointages`, `sessions`, `parametres` |
| API | Fonctions SQL RPC (`supabase/migrations/`) | authentification par PIN + jeton, règles métier, validation direction |
| Interface | `app/index.html` → construit dans `docs/` | servi par GitHub Pages (branche du projet, dossier `/docs`) |
| Ancienne adresse | Fonction Edge `horaires` | simple redirection 302 vers GitHub Pages |
| Excel | xlsx-js-style (CDN, dans le navigateur) | génération du fichier pour la comptable |

Sécurité : RLS activé **sans policy** sur toutes les tables → aucune lecture ni
écriture directe possible avec la clé publique. Tout passe par des fonctions
`SECURITY DEFINER` qui exigent un PIN valide puis un jeton de session. Les PIN
sont stockés hachés (bcrypt). Anti-force-brute : 20 tentatives/minute par
adresse IP (plafond global 200/minute).

## Mettre à jour l'interface

1. Modifier `app/index.html` (les valeurs `__SUPABASE_URL__` / `__ANON_KEY__`
   sont remplacées à la construction).
2. Reconstruire : `python3 scripts/publier_page.py` (écrit `docs/index.html`).
3. Committer et pousser : GitHub Pages republie automatiquement en ~1 minute.

## Activer GitHub Pages (une seule fois)

1. GitHub → dépôt `horairesdubois/horaires` → **Settings** → **General** → « Danger Zone » →
   **Change visibility** → *Public* (inutile avec un compte GitHub payant).
2. **Settings** → **Pages** → « Build and deployment » → Source :
   *Deploy from a branch* → Branch : `claude/employee-schedule-system-jekf2k`,
   dossier `/docs` → **Save**.
3. Après ~1-2 minutes, l'application est en ligne sur
   https://horairesdubois.github.io/horaires/

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
