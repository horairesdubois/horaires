# AGENTS.md — reprise du projet

Document de passation pour un agent qui arrive sans historique de conversation.
Lis-le en entier avant de toucher au code : plusieurs règles ici ne se devinent
pas depuis les fichiers, et deux d'entre elles ont déjà cassé la production.

Le dépôt est intégralement en français — code, commentaires, messages de
commit, interface. Continue en français.

---

## 1. Ce que c'est

Application de feuilles de temps d'une petite entreprise de dépannage à Genève
(ferblanterie, sanitaire, chauffage, vitrerie).

Cinq personnes, quatre rôles :

| Rôle | Qui | Peut |
|---|---|---|
| `admin` | le patron, « Back Office » | tout : valider, corriger, gérer les accès, **seul à voir le journal** |
| `compta` | la fiduciaire | **consultation et export seulement** |
| `employe` | 3 techniciens | saisir *ses* heures, *ses* messages, rien d'autre |
| `employe` + `demo=true` | compte de démonstration | comme un technicien, mais **invisible** du journal, de l'export et de la vue fiduciaire |

Les techniciens ouvrent l'app sur leur téléphone via un lien magique
(`?c=<32 hex>`) ou un code PIN. **Tout le design se juge sur un iPhone**
(390 × 664 utiles) : c'est le seul écran qui compte pour eux.

---

## 2. Où ça vit

- **Dépôt** : `github.com/horairesdubois/horaires`
- **Site en production** : <https://horairesdubois.github.io/horaires/>
- **Base** : Supabase, projet `ijfkttmezryvbjsuysbl`, région `eu-central-2` (Zurich)

| Chemin | Rôle |
|---|---|
| `app/index.html` | **la source de l'application** — un seul fichier, ~3200 lignes, HTML + CSS + JS sans dépendance ni étape de compilation. Contient les marqueurs `__SUPABASE_URL__` / `__ANON_KEY__`. |
| `docs/index.html` | **le fichier servi**, produit par `scripts/publier_page.py`. Ne jamais l'éditer à la main. |
| `scripts/publier_page.py` | la « compilation » : substitue l'URL et la clé anon dans `app/` → `docs/`. |
| `scripts/essais.mjs` | lanceur de toute la suite d'essais. |
| `supabase/migrations/` | l'historique complet du schéma et des fonctions SQL. |
| `supabase/tests/` | scénarios SQL joués dans une transaction annulée. |
| `supabase/non_retenu/` | écrit, testé, **volontairement pas déployé**. Ne pas rejouer. |
| `tests/` | essais d'écran Playwright. |
| `facturation/` | prototype de facturation/devis **jamais déployé** (voir §8). |
| `PLAN-TECHNIQUE.md` | le journal de bord, 48 sections. **La mémoire du projet** : chaque décision et son pourquoi. À lire quand tu te demandes « pourquoi est-ce fait comme ça ». |

### Les branches — la règle à ne pas manquer

Deux branches, deux rôles distincts :

- **`claude/tech-stack-ai-automation-xumqe5`** — branche de travail. C'est ici
  que tout se développe et se commite.
- **`claude/employee-schedule-system-jekf2k`** — **branche que GitHub Pages
  sert** (dossier `/docs`). En local elle s'appelle `pub`.

> **Un changement d'interface commité sur la branche de travail n'est PAS en
> ligne.** Les techniciens ne le voient pas. Il faut le porter sur `pub` et
> pousser vers `claude/employee-schedule-system-jekf2k`.

⚠️ **La branche par défaut du dépôt est la branche de publication**
(`claude/employee-schedule-system-jekf2k`) : un `git clone` y atterrit. Les deux
branches portent désormais le même arbre complet, donc tu ne manqueras rien —
mais **développe sur la branche de travail**, jamais directement sur celle que
Pages sert. Le propriétaire peut, s'il le souhaite, désigner
`claude/tech-stack-ai-automation-xumqe5` comme branche par défaut dans les
réglages GitHub : cela ne change rien à Pages, dont la source se configure
séparément.

La procédure complète de publication :

```bash
# 1. sur la branche de travail : coder, construire, tester, commiter, pousser
python3 scripts/publier_page.py
npm test
git add -A && git commit -m "..." && git push -u origin claude/tech-stack-ai-automation-xumqe5

# 2. porter sur la branche publiée
git checkout pub
git checkout claude/tech-stack-ai-automation-xumqe5 -- app/index.html
python3 scripts/publier_page.py
git add app/index.html docs/index.html && git commit -m "..."
git push -u origin pub:claude/employee-schedule-system-jekf2k
git checkout claude/tech-stack-ai-automation-xumqe5

# 3. vérifier que Pages a bien servi la nouvelle version (~30-60 s)
curl -s https://horairesdubois.github.io/horaires/ | grep -c '<un marqueur de ton changement>'
```

**N'ouvre pas de pull request** sauf demande explicite du propriétaire.

---

## 3. Installer et lancer

```bash
npm install                 # playwright
npm run navigateur          # télécharge Chromium (inutile si CHROMIUM_PATH est défini)
npm test                    # les 12 essais d'écran
npm test -- ecran-tech      # un seul, par filtre sur le nom
npm run build               # app/index.html -> docs/index.html
```

Si un Chromium est déjà présent sur la machine, exporte
`CHROMIUM_PATH=/chemin/vers/chrome` et saute `npm run navigateur`.

Les essais **impriment un compte rendu lisible** au lieu d'échouer sur des
assertions : c'est délibéré, on les relit. Le lanceur n'échoue que si un essai
plante ou déclenche une erreur JS dans la page.

> Deux faux négatifs connus dans `boutons-back-office.mjs` : « Copier le lien »
> (écrit dans le presse-papiers sans changer l'écran) et « Envoyer un message »
> (refuse à juste titre un message vide) ressortent en `MORT`.
> `boutons-back-office-details.mjs` les reprend isolément et les valide. Ne
> « corrige » pas ces deux-là.

### Vérifications à faire après toute modification de `app/index.html`

```bash
python3 - <<'PY'
import io, re
s = io.open('app/index.html', encoding='utf-8').read()
js = re.search(r'<script>(.*)</script>', s, re.S).group(1)
io.open('/tmp/a.js', 'w', encoding='utf-8').write(js)
ids = set(re.findall(r'\bid="([^"]+)"', s))
print('ids manquants :', sorted({m for m in re.findall(r"\$\('([^']+)'\)", js)} - ids) or 'aucun')
noms = re.findall(r'^function (\w+)', js, re.M) + re.findall(r'^async function (\w+)', js, re.M)
print('fonctions en double :', sorted({n for n in noms if noms.count(n) > 1}) or 'aucune')
PY
node --check /tmp/a.js
```

**Le contrôle des doublons n'est pas décoratif.** Un renommage a un jour créé
deux `function journeeType()` ; la seconde déclaration a écrasé la première et
le bouton « Enregistrer l'horaire normal » ne faisait plus rien, sans la
moindre erreur en console. Le fichier étant unique et sans modules, toute
collision de nom est silencieuse et fatale.

---

## 4. Le modèle de sécurité — invariants à ne jamais casser

La clé `anon` de Supabase est **publique par conception** : elle est dans ce
dépôt et livrée dans la page. Toute la sécurité tient donc sur ceci :

1. **RLS activé sur toutes les tables, avec ZÉRO policy**, et **aucun grant de
   table** à `anon`/`authenticated`. Un accès direct PostgREST renvoie `401`.
   → N'ajoute jamais de policy ni de grant de table pour contourner un souci.
2. **Tout passe par des fonctions `SECURITY DEFINER`** accordées à `anon`, qui
   vérifient elles-mêmes le jeton et le rôle. Le premier geste de chacune est
   `v_emp := public._auth(p_token)` puis un contrôle de rôle.
3. **Toute fonction `public._%` est révoquée de `anon`, `authenticated`,
   `public`.** Ce sont les rouages internes. Une nouvelle fonction Postgres est
   exécutable par `PUBLIC` **par défaut** : la révocation en boucle du
   2026-09-07 ne couvre pas ce que tu crées ensuite.
   → **Chaque nouveau helper `_xxx` doit porter son `revoke` dans sa migration.**
   Un audit a trouvé `_save_jour` joignable depuis Internet sans jeton ; c'est
   exactement ce trou que cette règle ferme.
4. **Le journal est réservé à `admin`.** `journal_lire` exige `role = 'admin'` —
   la fiduciaire en est exclue, c'est une exigence explicite du propriétaire.
   L'onglet est aussi caché côté client, mais **la garde qui compte est en SQL**.
5. **Le compte `demo=true` ne laisse aucune trace**, dans les deux sens :
   `_journal` s'arrête net sur un acteur démo, et chaque déclencheur teste aussi
   la cible (`_demo(employe_id)`, `_demo(auteur_id)`…). Il est également exclu
   de l'export et de la vue fiduciaire.
6. **Le schéma `bastion` n'est pas exposé** par PostgREST (seuls `public` et
   `graphql_public` le sont). C'est ce qui rend le prototype de facturation
   inatteignable. Ne l'expose pas.
7. **Aucun secret dans le dépôt** en dehors de la clé anon (publique). Le mot de
   passe de la base, le jeton d'accès Supabase et `parametres.controle_secret`
   n'y sont pas et n'ont rien à y faire.

### Côté client

Toute chaîne venant du serveur qui entre dans un `innerHTML` **doit** passer par
`esc()`. Les textes libres d'un technicien (remarque, message, motif de demande)
s'affichent dans le navigateur de l'admin, dont le jeton est en `localStorage` :
un `innerHTML` non échappé y serait une élévation de privilège. Un audit a
vérifié les 36 puits ; garde-les propres.

---

## 5. Les migrations SQL

- Un fichier par changement : `supabase/migrations/AAAAMMJJHHMMSS_nom.sql`.
- **Il n'y a pas de CLI Supabase liée** (pas de `config.toml`). Les migrations
  sont appliquées directement à la base de production — via le serveur MCP
  Supabase (`apply_migration`) ou l'éditeur SQL du tableau de bord.
- **Le fichier doit malgré tout être commité**, et le dépôt doit pouvoir
  reconstruire la base seul. Une colonne créée à la main sans migration a déjà
  rendu le dépôt incapable de repartir de zéro. Utilise
  `add column if not exists` et des gardes idempotents.
- Teste avant de valider, **sur les vraies données, dans une transaction
  annulée** :

  ```sql
  begin;
  do $$ ... $$;            -- joue le scénario
  select ... from public.journal where quand > now() - interval '1 minute';
  rollback;
  ```

  Puis vérifie que rien n'a fui (`select count(*) ... where jour = '...'`).

- **Ne réécris jamais le journal.** C'est une piste d'audit. Des lignes
  anciennes mal attribuées se laissent expliquer, pas corriger après coup.

### Deux limites connues du dossier `migrations/`

- Les horodatages des noms de fichiers **ne correspondent pas** au registre
  `supabase_migrations.schema_migrations` de la base : celui-ci enregistre
  l'heure d'application. Les noms de fichiers ne servent qu'à l'ordre de
  rejeu local ; les renommer est sans effet sur la base.
- Le schéma `bastion` (prototype de facturation) a été appliqué directement :
  ses migrations figurent dans le registre distant mais **pas dans ce dépôt**.
  Le dépôt reconstruit donc l'application *horaires*, pas `bastion`. Comme
  `bastion` n'est ni exposé ni utilisé, ce n'est pas bloquant — mais ne compte
  pas dessus.

### Deux réglages transactionnels à connaître

| Réglage | Rôle |
|---|---|
| `horaires.acteur` | l'identité **réelle** de celui qui écrit, posée par la fonction appelante et lue par les déclencheurs de journal. Sans lui, le déclencheur retombait sur `saisi_par` — qui appartient au technicien et survit aux écritures du back office — et **attribuait les validations du patron à son employé**. |
| `horaires.lot` | mis à `'1'`, fait taire la branche « approbation » du déclencheur, le temps d'une opération en lot (valider un mois = **une** ligne de journal, pas trente). |

Toute nouvelle fonction qui écrit dans `pointages` doit poser `horaires.acteur`.

---

## 6. Ce que le journal enregistre

Le propriétaire s'en sert pour contrôler. Les actions : `connexion`,
`connexion_echouee`, `ouverture`, `consultation`, `saisie`, `modification`,
`confirmation`, `validation`, `validation_mois`, `deverrouillage`,
`suppression`, `demande_modification`, `deblocage_accorde`, `deblocage_refuse`,
`message*`, `bulletin_*`, `fiche_modifiee`, `reglage_modifie`, `export`.

Une `modification` porte l'**avant**, l'**après**, l'écart en minutes, les champs
touchés et `etait_approuve`. Une `saisie` porte en plus le **retard** (l'écart en
jours entre la journée et son enregistrement — « le jour même » contre « 9 jours
après »), les **heures au-delà** de la journée normale, et l'**appareil**.

**Ligne à ne pas franchir** : l'adresse IP et la géolocalisation ont été
écartées volontairement. Consigner les écritures d'une feuille de temps, c'est
tenir un registre ; pister d'où quelqu'un se connecte, c'est un système de
surveillance du comportement, que l'art. 26 OLT 3 interdit en Suisse. N'ajoute
pas ce genre de champ sans une demande explicite et éclairée du propriétaire.

---

## 7. Pièges déjà rencontrés

- **`vh` sur iPhone** : Safari compte la barre d'adresse. La fenêtre de saisie
  utilise `max-height: 92dvh` avec repli `vh`. Mesure en **390 × 664**, pas 844.
- **Icône native des champs `time`** : masquée par
  `::-webkit-calendar-picker-indicator{display:none}`, sinon elle double la nôtre
  et fait déborder le champ.
- **Un rafraîchissement de fond marquait les messages comme lus** :
  `chargerMessages` passe `p_marquer:false` ; seul l'affichage de l'onglet
  Questions déclenche `marquerFilLu()`.
- **`compta_donnees` écrivait une ligne de journal à chaque appel** (60 s de
  rafraîchissement ≈ 500 lignes/jour). Limité à une par 30 min via `_presence`.
- **Le lien de démo** : la session vit en `sessionStorage` (portée à l'onglet)
  pour ne pas écraser la session back office du même navigateur, qui est en
  `localStorage`. Voir `COFFRE` dans `app/index.html`.

---

## 8. État actuel et décisions en attente

**Livré et en production.** Saisie et confirmation des journées, validation par
le back office, guichet de demande d'ouverture d'une journée validée, questions,
export Excel, journal complet, compte de démonstration.

**Écrit mais jamais déployé — ne pas activer sans demande** :
`facturation/` et le schéma `bastion` (devis, factures, relances),
`supabase/non_retenu/` (pré-remplissage de la veille).

**Correctifs de sécurité proposés, en attente du feu vert du propriétaire** —
issus d'un audit ; ne pas les appliquer d'autorité :

1. verrouillage par compte après N échecs (le limiteur actuel se fie à
   l'en-tête `X-Forwarded-For`, falsifiable ; seul le plafond global de 10/min
   borne réellement un brute-force) ;
2. aligner la regex de `connexion` sur `^[0-9]{6,10}$` (elle accepte encore
   4 chiffres alors que `admin_employe` impose 6 à l'écriture) ;
3. ne pas compter les tentatives déjà bloquées dans `_limiter` (un flood
   s'auto-alimente et prive toute l'entreprise de connexion) ;
4. ajouter à `supprimer_jour` le garde `compta` qu'a déjà `enregistrer_jour`.

**Question restée sans réponse** : le 2 septembre, un technicien a demandé
« comment j'accède à mes fiches de paie ? » — or l'onglet Bulletins a depuis été
retiré de l'interface.

---

## 9. Manière de travailler attendue

- Le propriétaire n'est pas développeur. Explique en français clair, en partant
  de ce qu'il voit à l'écran, pas de la structure du code.
- **Ne déploie rien qu'il n'ait demandé.** Il tranche ; propose, puis attends.
- Vérifie sur les vraies données quand c'est possible, et **dis-le** quand tu ne
  peux pas vérifier quelque chose.
- N'invente jamais un chiffre ou une cause : ce projet a déjà connu une
  affirmation fausse sur une couleur, et une ligne de journal mal attribuée qui
  accusait un employé. En cas de doute, va lire la base.
- Consigne les décisions importantes dans `PLAN-TECHNIQUE.md`, en expliquant le
  **pourquoi** — c'est ce qui rend le projet reprenable.
