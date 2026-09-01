# Socle technique — dépannage, 3 techniciens, automatisation par IA

Document de décision. Objectif : arrêter de perdre du temps sur les demandes
clients, les devis, les factures, les relances et le suivi quotidien des
techniciens, en restant à un coût mensuel de l'ordre du prix d'un abonnement
téléphonique — et avec les données en Suisse.

---

## 1. Le vrai problème n'est pas l'outillage, c'est l'absence d'objet « intervention »

Aujourd'hui la demande d'un client existe sous cinq formes qui ne se parlent
pas : un appel Ringover, un e-mail Google Workspace, un message WhatsApp, une
phrase dite au technicien sur place, et une ligne griffonnée. Rien ne relie
« M. Duval a appelé mardi » à « Marc y est allé jeudi » à « facture 2026-118
impayée depuis 45 jours ».

Tant que cet objet n'existe pas en base, aucune IA ne peut aider : elle n'a
rien à lire, rien à surveiller, rien à relancer. **Toute la pile ci-dessous
n'a qu'un but : faire exister une ligne `intervention` et l'alimenter
automatiquement depuis les canaux existants.**

C'est exactement ce qui a fait marcher le pointage : l'objet `pointages` existe,
donc le contrôle du soir et la relance sont devenus possibles et automatiques.
On refait le même geste, un cran plus haut.

---

## 2. La pile recommandée

| Brique | Choix | Pourquoi | Coût/mois |
|---|---|---|---|
| Serveur | **Infomaniak Public Cloud** (Genève/Winterthur) ou **Exoscale** (CH-GVA-2) | Datacenters suisses, facturation en CHF, ISO 27001 | CHF 10–25 |
| Base | **PostgreSQL 17** + **PostgREST**, en Docker | Continuité totale avec l'existant : mêmes fonctions RPC, mêmes `security definer`, même client | inclus |
| Application terrain + back office | **PWA mono-fichier**, comme `app/index.html` | Zéro store, zéro build, déjà adoptée par les techniciens | inclus |
| Fichiers (photos, PDF) | **MinIO** sur la même VM, ou Infomaniak Swiss Backup | Photos d'intervention = preuve en cas de litige | CHF 5–10 |
| IA | **Infomaniak AI Tools** (API compatible OpenAI, modèles hébergés en Suisse) | Dès CHF 0.05 / million de tokens en entrée. Whisper inclus pour la transcription | CHF 5–20 |
| Téléphonie | **Ringover** (déjà en place) + ses webhooks | Chaque appel devient une ligne en base, gratuitement | existant |
| E-mails | **Google Workspace** (déjà en place) + Apps Script | Pas de serveur OAuth à maintenir | existant |
| Devis / factures / TVA / rappels | **bexio** via son API REST | Voir §5 — c'est le seul poste payant que je garde | CHF 45–79 |
| Orchestration | **`pg_cron` en base**, comme aujourd'hui | Vous avez déjà appris que les routines externes se font bloquer | inclus |

**Total nouveau : CHF 65–135/mois**, dont plus de la moitié pour bexio.
Sans bexio (facturation maison, §5 variante B) : **CHF 20–56/mois**.

À comparer : un logiciel de gestion d'interventions du marché coûte CHF 35–60
par utilisateur et par mois — soit CHF 175–300/mois à 5 comptes — et ne fera
pas le management IA que vous cherchez.

---

## 3. Hébergement en Suisse : à faire, mais sachez pourquoi

**Point juridique, pour éviter un malentendu coûteux :** la nLPD n'impose
*aucune* obligation générale d'héberger en Suisse. Un datacenter allemand ou
irlandais est parfaitement licite, l'UE bénéficiant d'une décision d'adéquation.
Votre projet Supabase actuel (Francfort) n'est donc pas hors-la-loi.

Héberger en Suisse est un choix **commercial et de confiance** — surtout si vous
visez des régies, des gérances ou des mandats publics, où « données en Suisse »
se met dans une offre. Et à CHF 10–25/mois, l'argument coûte moins cher que la
discussion.

Conséquence pratique : **Supabase managé n'a pas de région suisse.** Vous ne
pouvez pas simplement déplacer le projet. Deux options :

- **A — Une VM suisse, Docker Compose** : `postgres` + `postgrest` + `caddy`
  (+ `minio`). Vous gardez 100 % de votre SQL existant, vous perdez le Studio et
  l'hébergement managé. Sauvegarde : `pg_dump` nocturne vers Swiss Backup.
  *C'est ma recommandation.* La surface est minuscule et vous n'utilisez déjà pas
  GoTrue (votre authentification PIN + jeton est écrite en SQL).
- **B — Rester sur Supabase Francfort** et n'installer en Suisse que le
  travailleur IA. Moins d'ops, mais l'argument « données en Suisse » tombe, et
  vous gardez le bricolage `keepalive.yml` contre la mise en veille du plan
  gratuit.

Ne migrez pas le pointage tout de suite : montez le nouveau système sur la VM
suisse, laissez `horaires` où il est, et rapatriez-le une fois la VM éprouvée.
Ça supprimera au passage le keepalive.

---

## 4. Faire entrer les demandes toutes seules

### 4.1 Ringover — chaque appel devient une ligne

Ringover envoie des webhooks sur appel entrant, appel manqué, appel répondu et
message vocal (avec transcription). Un point d'entrée HTTP sur la VM, et :

- appel entrant d'un numéro inconnu → `demande` en état `à_qualifier` ;
- appel manqué → tâche de rappel, avec relance si personne n'a rappelé à 2 h ;
- appel terminé → l'enregistrement est récupéré, transcrit, résumé, et le
  résumé atterrit dans la `demande` (adresse, nature de la panne, urgence).

**Ne prenez pas l'option Empower à USD 39/utilisateur/mois.** Vous n'avez besoin
que de la transcription : Whisper chez Infomaniak vous la donne pour quelques
centimes par heure d'audio. Même chose pour l'agent vocal AIRO à €0.39/minute et
le module omnicanal à €29/licence : ce sont des surcouches qui refacturent cher
ce que votre base fera gratuitement une fois qu'elle existe.

### 4.2 Google Workspace — les leads par e-mail

Le plus robuste à votre taille n'est pas l'API Gmail avec Pub/Sub, c'est un
**Google Apps Script** avec déclencheur temporel : il tourne chez Google,
gratuitement, lit un libellé `Leads`, poste vers votre API, applique un libellé
`Traité`. Pas de serveur OAuth, pas de jeton à renouveler, pas de quota à
surveiller. Vingt lignes de code.

L'IA extrait ensuite : nom, adresse, téléphone, nature du dépannage, urgence
estimée, et si le client est déjà connu.

### 4.3 WhatsApp — le point qui va vous surprendre

WhatsApp gratuit ne s'automatise pas. Il faut la WhatsApp Business Platform,
facturée **au message depuis le 1er juillet 2025** ; et à partir du
**1er octobre 2026**, Meta facturera aussi les réponses de service et les
messages utilitaires envoyés dans la fenêtre de 24 h — la partie gratuite
disparaît donc bientôt.

**Ma recommandation : ne branchez pas WhatsApp maintenant.** Faites l'inverse —
sortez le travail de WhatsApp :

- **côté techniciens**, la coordination passe dans la PWA (vous savez déjà que
  ça prend : le pointage l'a prouvé). WhatsApp redevient ce qu'il aurait dû
  rester, un canal informel ;
- **côté clients**, la confirmation d'intervention et le rappel de rendez-vous
  partent en **SMS via Ringover**, que vous payez déjà.

Vous rebranchez WhatsApp Business plus tard, si et seulement si le volume de
messages clients entrants le justifie.

---

## 5. Devis, factures, relances impayés

C'est là que se joue votre trésorerie, et c'est là que je vous conseille de
**payer plutôt que de construire**.

### Variante A — bexio (recommandée)

CHF 45/mois (1 utilisateur), 52 (2), 79 (5), 129 (25). API REST documentée sur
`dev.bexio.com` : contacts, devis, factures, écritures, paiements, en OAuth2 ou
jeton personnel. QR-factures conformes. **Rappels automatiques paramétrables.**
*(Une promotion −40 % nouveaux clients circulait avec échéance au 28.08.2026 —
à vérifier directement chez eux avant de signer.)*

Ce que ça vous achète vraiment :

- la TVA et le plan comptable suisses maintenus par quelqu'un d'autre ;
- les **relances impayés résolues sans une ligne de code** : vous décidez du
  nombre de rappels et du délai, bexio envoie ;
- un accès direct pour votre fiduciaire — que vous outillez déjà pour les
  salaires ;
- le rapprochement bancaire avec les fichiers camt de votre banque.

Votre système reste le maître de l'opérationnel et pousse la facture par API
dès que l'intervention est clôturée. bexio reste le maître du grand livre.

### Variante B — tout maison

`swissqrbill` (npm, libre, PDF et SVG, factures en français) génère des
QR-factures conformes gratuitement. Le rapprochement se fait en important le
**camt.054** de votre banque, la relance devient un `pg_cron` de plus.

Économie : ~CHF 660/an. Ce que vous achetez en échange : la responsabilité de
la conformité TVA et comptable, et l'accord de votre fiduciaire. À ne choisir
que si votre fiduciaire confirme qu'un export CSV lui suffit — comme pour les
salaires. **Vérifiez au passage que votre banque fournit le camt.054 sans
supplément.**

### Le devis assisté, dans les deux cas

Le technicien dicte son rapport dans la PWA → Whisper (Suisse) → texte →
l'IA propose les lignes de devis à partir de votre catalogue de prestations et
des tarifs déjà pratiqués sur des interventions comparables. **L'IA propose, le
back office valide en un geste.** Jamais d'envoi automatique d'un prix à un
client : c'est le seul endroit où une hallucination vous coûte de l'argent réel.

---

## 6. Le management des techniciens par l'IA

C'est le cœur de votre demande, et vous avez déjà écrit la moitié de la réponse
dans ce dépôt.

### Le cycle de vie qui produit la donnée

L'IA ne peut surveiller que ce que le terrain émet naturellement. L'intervention
passe par : `planifiée → acceptée → en route → sur place → terminée`, chaque
transition étant un bouton unique dans la PWA. Plus un rapport dicté et deux
photos. Rien à saisir, rien à taper.

### Le contrôle continu

Un `pg_cron` compare en permanence l'attendu au réel, et interpelle :

- rendez-vous à 9 h, toujours pas `en route` à 9 h 10 → question au technicien ;
- `sur place` depuis 3 h sur un dépannage estimé à 1 h → question au technicien,
  et signalement à la direction si sans réponse ;
- intervention `terminée` sans rapport ni photo à 18 h → relance ;
- intervention terminée depuis 48 h et pas facturée → relance au back office ;
- devis envoyé il y a 7 jours sans réponse → proposition de relance client.

### Les deux synthèses quotidiennes pour la direction

- **7 h 30** — ce qui est à risque aujourd'hui : sous-effectif, trajets
  incohérents, urgence non attribuée, client déjà mécontent.
- **19 h** — ce qui n'est pas clos : rapports manquants, interventions non
  facturées, impayés franchis dans la journée.

Un message chacune, pas un tableau de bord à aller consulter.

### Deux règles de ton, que vous avez déjà apprises à vos dépens

1. **Les relances automatiques sont signées « Back office », jamais
   « Direction ».** C'est écrit dans la migration
   `20260825150000_confirmation_et_relance_autonome.sql` et c'est juste : un
   technicien qui croit que son patron l'écrit personnellement à chaque oubli
   finit par détester l'outil.
2. **Le texte du rappel reste neutre** (commit `949e6da`). L'IA rédige, mais
   dans un gabarit borné — elle ne choisit pas le ton toute seule.

C'est ce qui a fait accepter le pointage. Ne le perdez pas en montant en
puissance : l'IA doit ressembler à un assistant de back office consciencieux,
pas à un contremaître.

---

## 7. Le modèle de données, en une esquisse

```
clients        (particulier | régie | gérance, adresse de facturation, conditions)
demandes       (source: ringover|email|whatsapp|formulaire, brut, transcription,
                résumé_ia, urgence, adresse, client_id?, état)
interventions  (demande_id, employe_id, créneau, état, rapport, durée_réelle)
photos         (intervention_id, objet_minio, prise_le)
devis          (intervention_id, lignes, montant, envoyé_le, accepté_le)
factures       (intervention_id, ref_bexio, montant, échéance, payée_le)
relances       (facture_id | devis_id, niveau, envoyée_le)
employes       (existant)
pointages      (existant)
```

Le lien `pointages` ↔ `interventions` est le gain caché : vous saurez enfin ce
qu'une intervention coûte réellement en heures, donc si vos prix tiennent.

---

## 8. Ce que je ne recommande pas, et pourquoi

| Écarté | Raison |
|---|---|
| WhatsApp Business Platform (maintenant) | Facturation au message, et la gratuité des réponses de service disparaît au 01.10.2026. Sortez le travail de WhatsApp plutôt que d'y payer l'entrée. |
| Ringover Empower (USD 39/util./mois) | Vous ne voulez que la transcription. Whisper en Suisse la fait pour des centimes. |
| Zapier / Make en plan payant | Facturé à la tâche ; vos volumes exploseraient le forfait. `pg_cron` fait déjà le travail chez vous. |
| n8n auto-hébergé | Gratuit et sans limite d'exécution, mais c'est une brique de plus à maintenir. **À garder en réserve** : le jour où le back office voudra modifier une automatisation sans développeur, il devient pertinent. |
| Un ERP complet (Odoo, Abacus) | Poids de paramétrage sans commune mesure avec 3 techniciens. |
| Une app mobile native | Store, comptes développeur, cycles de publication. La PWA a déjà fait ses preuves chez vous. |

---

## 9. Ordre de mise en œuvre

L'ordre est dicté par la trésorerie et par le risque de perte d'information.

**Étape 1 — Ne plus rien perdre.** VM suisse, base, objets `demande` et
`intervention`, webhook Ringover, Apps Script Gmail, PWA terrain avec le cycle
de vie et le rapport dicté. À la fin de cette étape, WhatsApp ne sert plus à
attribuer une intervention.

**Étape 2 — Encaisser plus vite.** Ouverture bexio, facturation poussée par API
à la clôture d'intervention, **et activation des rappels automatiques bexio** —
c'est le meilleur rapport effet/effort de tout le projet : les relances impayés
sont réglées par un écran de configuration, pas par du code.

**Étape 3 — Devis assistés.** Catalogue de prestations, proposition IA depuis le
rapport dicté, validation en un geste par le back office.

**Étape 4 — Management IA.** Contrôle continu, synthèses de 7 h 30 et 19 h.
En dernier volontairement : ces règles ne valent que si les données des étapes
1 à 3 sont fiables. Une IA qui relance sur des données fausses détruit en une
semaine la confiance que le pointage a mis des mois à construire.

**Étape 5 — Consolidation.** Rapatriement du pointage sur la VM suisse,
suppression du keepalive, lien heures ↔ interventions.

---

## 10. Ce qu'il reste à trancher

1. **bexio ou facturation maison ?** Question à poser à votre fiduciaire, pas à
   un développeur. Sa réponse décide de CHF 660/an et du périmètre de l'étape 2.
2. **Migration du pointage : maintenant ou à l'étape 5 ?** Je recommande
   l'étape 5 — pas de valeur nouvelle, et un risque sur un outil qui marche.
3. **Votre banque fournit-elle le camt.054 sans supplément ?** Détermine la
   faisabilité de la variante B et le rapprochement automatique dans les deux cas.
4. **Combien de demandes par jour, réellement ?** En dessous de ~30, tout ce
   document tient sur une seule VM à CHF 15/mois, et les coûts IA restent sous
   CHF 20/mois. Au-delà, seul le poste IA bouge, et lentement.

---

## 11. Claude : quelle porte d'entrée, et combien ça coûte

### 11.1 Amazon propose deux choses différentes — et aucune ne met Claude en Suisse

| Route | Qui l'exploite | Où tourne l'inférence | Identifiants de modèle |
|---|---|---|---|
| **API Anthropic directe** | Anthropic | `us` ou `global` — pas d'option européenne | `claude-opus-5` |
| **Claude Platform on AWS** | Anthropic, via AWS (IAM, facturation Marketplace) | idem API directe | `claude-opus-5` |
| **Amazon Bedrock** | AWS (partenaire) | **la région AWS que vous choisissez** | `anthropic.claude-opus-5` |

Le point qui compte pour vous : **Claude ne tourne nulle part en Suisse.** La région AWS
Europe (Zurich) `eu-central-2` existe, mais tous les modèles Claude récents n'y sont
accessibles que par *profil d'inférence inter-régions* — servis par la région du profil
qui a de la capacité, pas forcément Zurich. Et le profil européen ne comprend que des
régions UE : Francfort, Irlande, Paris, Stockholm, Milan, Espagne. La Suisse n'en fait
pas partie, puisqu'elle n'est pas dans l'UE.

**Ce n'est pas bloquant.** Un traitement en UE est un transfert vers un pays à protection
adéquate : c'est propre sous nLPD, sans paperasse supplémentaire. Et Anthropic
n'entraîne pas ses modèles sur les données commerciales.

### 11.2 L'architecture qui règle vraiment la question suisse

C'est le découpage, pas le fournisseur, qui protège vos clients :

- **l'enregistrement audio de l'appel — la donnée la plus sensible — reste en Suisse**,
  transcrit par Whisper chez Infomaniak ;
- **seul le texte part chez Claude** pour être compris, résumé, transformé en devis.

Claude ne prend d'ailleurs pas d'audio en entrée : la transcription devait de toute façon
se faire ailleurs. Autant que ce soit à Genève.

### 11.3 Les prix, au million de jetons

| Modèle | API directe | Bedrock | À quoi vous vous en servez |
|---|---|---|---|
| Claude Haiku 4.5 | 1.00 $ / 5.00 $ | 1.00 $ / 5.00 $ | qualification des demandes, contrôles, mise en forme des rapports |
| Claude Sonnet 5 | 2.00 $ / 10.00 $ | **3.00 $ / 15.00 $** | — |
| Claude Opus 5 | 5.00 $ / 25.00 $ | 5.00 $ / 25.00 $ | devis, synthèses à la direction, relances rédigées |

Opus et Haiku coûtent la même chose par les deux routes ; seul Sonnet 5 est 50 % plus
cher chez Bedrock. Pas d'abonnement, pas de minimum : on paie à l'usage.

### 11.4 Ce que ça donne à votre volume

Hypothèse, par jour ouvré : 20 demandes qualifiées, 12 interventions suivies,
8 devis rédigés, 12 contrôles automatiques, 2 synthèses à la direction. Soit 22 jours.

| Modèle | Entrée / mois | Sortie / mois | Coût |
|---|---|---|---|
| Haiku 4.5 — le volume mécanique | 1.50 M | 0.29 M | 2.95 $ |
| Opus 5 — le jugement | 1.98 M | 0.26 M | 16.28 $ |
| **Sous-total sans optimisation** | | | **19.23 $** |
| Avec cache de contexte sur le préfixe stable | | | **≈ 14 $** |

Le préfixe stable, c'est votre catalogue de prestations, vos consignes et votre
historique tarifaire : identiques à chaque appel, donc relus depuis le cache à
un dixième du prix.

**Comptez CHF 12–20 par mois. Budgétez CHF 25 pour avoir de la marge.**
Même en triplant votre activité, vous restez sous CHF 60.

### 11.5 Le piège à éviter

**L'API et l'abonnement Claude sont deux choses distinctes.** Un siège Claude Team
coûte 25 $ par mois avec un minimum de 5 sièges — soit environ CHF 100 par mois pour
une interface de discussion dont votre automatisation n'a aucun besoin, puisqu'elle
passe par l'API. Ne prenez des sièges que si le back office veut *en plus* discuter
avec Claude à la main.

### 11.6 Par quelle route commencer

**Commencez par l'API Anthropic directe.** Elle est plus simple (une clé, pas de compte
AWS), et elle donne accès à deux choses que Bedrock n'a pas et qui font baisser la
facture : le cache automatique de contexte, et l'API Batch à moitié prix pour tout ce
qui n'est pas urgent — typiquement la synthèse du soir.

**Passez à Bedrock, profil européen, le jour où un client l'exige par contrat** — une
régie, une gérance, un mandat public. Le basculement coûte une ligne : on remplace le
client `Anthropic()` par `AnthropicBedrockMantle(aws_region=...)`, et on préfixe les
identifiants de modèle par `anthropic.`. Le reste du code ne bouge pas. Ne montez pas
un compte AWS aujourd'hui pour une exigence que personne ne vous a encore posée.

---

## 12. Le budget complet

| Poste | CHF / mois | Remarque |
|---|---|---|
| Serveur — Infomaniak Public Cloud ou Exoscale, Genève | 15 | données applicatives en Suisse |
| Stockage photos + sauvegardes | 8 | |
| Transcription Whisper — Infomaniak | 5 | l'audio ne quitte pas la Suisse |
| **Claude — Haiku 4.5 + Opus 5** | **25** | consommation réelle 12–20 |
| Nom de domaine | 1 | |
| bexio Advanced, 2 utilisateurs | 52 | TVA, QR-factures, rappels automatiques |
| **Total** | **106** | **≈ CHF 1 270 par an** |

Inchangés : Ringover et Google Workspace, que vous payez déjà.

**Variantes :**

- **sans bexio** (facturation maison, `swissqrbill` + camt.054) : **CHF 54/mois**, environ
  CHF 650 par an ;
- **activité triplée** (60 demandes par jour) : seul le poste Claude bouge, vers CHF 60 —
  total **CHF 141/mois** ;
- **avec des sièges Claude Team** pour le back office : + CHF 100/mois environ. À ne
  prendre que si quelqu'un veut vraiment l'interface de discussion.

Aucun frais de mise en service : le compte AWS est gratuit, l'API Anthropic est
à l'usage sans minimum, et les CHF 300 de crédits d'essai d'Infomaniak couvrent
les premiers mois de serveur.

**Le poste qui domine reste bexio, pas l'IA.** Sur CHF 106, l'intelligence artificielle
en représente 25 — moins qu'un quart, et moins que ce que vous coûte une heure de
technicien à ne pas facturer.

---

## 13. Devis, QR-factures et relances : c'est fait, et c'est gratuit

Réponse courte à « est-ce possible gratuitement par API » : **oui, et il n'y a
même pas d'API à appeler.** `swissqrbill` est une bibliothèque sous licence MIT
qui tourne chez vous. Pas d'abonnement, pas de coût par facture, pas de compte
tiers — et surtout aucune donnée client qui sort de votre serveur pour aller
chercher un QR code ailleurs.

Le module est dans `facturation/`, la base dans
`supabase/migrations/20260826160000_devis_factures_relances.sql`, et le scénario
de bout en bout dans `supabase/tests/relances.sql`. Tout a été exécuté, pas
seulement écrit.

### 13.1 Ce qui est en place

| Brique | Où | État |
|---|---|---|
| Référence de paiement QRR et SCOR | `facturation/reference.mjs` | testée contre la base |
| Facture A4 conforme art. 26 LTVA, avec section QR | `facturation/facture.mjs` | PDF généré, une page |
| Rappel et mise en demeure, même référence | idem, paramètre `niveau` | PDF généré, une page |
| Intérêt moratoire 5 % (art. 104 al. 1 CO) | `_interet_moratoire()` | à la mise en demeure seulement |
| Escalade J+7 / J+21 / J+35 | `poser_relances()`, pg_cron | scénario passé |
| Rapprochement camt.054 | `enregistrer_paiement()` | scénario passé |
| Blocage d'une facture contestée | `bloquer_facture()` | scénario passé |

### 13.2 Les trois règles qui portent le module

**La référence ne change jamais.** Elle est calculée à l'émission et reprise
telle quelle sur le rappel et sur la mise en demeure. C'est elle qui permet au
camt.054 de dire quelle facture a été payée. Une référence qui bouge, c'est un
client relancé après avoir payé — la faute qui coûte le plus cher en réputation.

**Le paiement éteint la relance dans la même transaction.** `enregistrer_paiement()`
solde la facture *puis* annule les relances en attente, sans fenêtre entre les
deux. L'ordre inverse laisse passer un rappel pour une facture encaissée le
matin même.

**Une facture contestée se bloque.** Un client qui a écrit et qu'on relance
quand même ne revient pas. `bloquer_facture()` sort la facture du cycle et
annule ce qui était en attente.

### 13.3 Ce que le rapprochement fait quand il ne sait pas

La référence lue fait foi, en comparant sur la forme nue — les banques rendent
la référence groupée par cinq depuis la droite, parfois avec des tirets. À
défaut, repli sur le solde exact d'une facture ouverte, **et seulement s'il n'y
en a qu'une**. Deux factures au même montant : l'écriture est conservée sans
facture et attend un humain. On ne devine pas.

### 13.4 Ce qu'il vous reste à faire, et qui ne dépend pas de moi

1. **Demander le QR-IBAN à votre banque.** Il est gratuit sur simple demande.
   Sans lui, on reste sur référence SCOR avec votre IBAN ordinaire — ça marche,
   c'est juste moins lisible sur un extrait. Le code gère les deux et choisit
   tout seul : un QR-IBAN impose une référence QRR, un IBAN ordinaire une SCOR,
   et la banque refuse la combinaison inverse.
2. **Vérifier que la banque livre le camt.054 sans supplément.** C'est ce
   fichier qui ferme la boucle. Sans lui, les relances tournent à l'aveugle.
3. **Écrire les frais de rappel dans vos conditions générales.** L'intérêt
   moratoire de 5 % est dû de plein droit ; les frais de rappel, eux, ne tiennent
   que s'ils sont prévus au contrat avec un montant identifiable.
4. **Valider un exemplaire sur le portail de validation QR-facture** avant le
   premier envoi réel.

### 13.5 Ce que ça change pour bexio

Vos trois priorités — QR-factures, devis, relances automatiques — sont couvertes
gratuitement. Ce que bexio vend encore, ce n'est donc plus la facturation :
c'est la TVA, le plan comptable et l'accès de votre fiduciaire. **La question
n'est plus « acheter ou construire », elle est devenue « votre fiduciaire
accepte-t-il un export ? ».** Posez-lui celle-là, et rien d'autre.

### 13.6 Deux choses trouvées en exécutant vos migrations

En rejouant l'historique du dépôt sur une base vierge, **quatre migrations sur
dix-sept échouent** : elles référencent une colonne `employes.cle_acces` qu'aucune
migration ne crée. Elle a été ajoutée à la main en production.

Ça n'a aucun effet aujourd'hui — mais ça veut dire que **votre schéma ne se
reconstruit pas depuis le dépôt**. Le jour où vous montez le serveur suisse, ou
le jour où vous devez restaurer, il manquera cette colonne et quatre migrations
refuseront de passer. Une migration de rattrapage de trois lignes suffit à
refermer le trou. À faire avant la migration, pas pendant.

---

## 14. La BCGE peut-elle donner un accès API à la Sàrl ?

**Réponse honnête : pas au sens où vous l'entendez, et il ne faut pas attendre
après elle pour démarrer.**

### 14.1 Ce que j'ai trouvé, et ce que ça vaut

| Piste | Ce que c'est | Verdict |
|---|---|---|
| `developer.bcgef.fr` | Portail développeur avec bac à sable | **BCGE France**, entité distincte, sous DSP2 européenne. Ne couvre pas un compte genevois. |
| Multibanking PME | Offre BCGE pour les PME | Mentionne **EBICS** — et uniquement EBICS. Demande un contrat spécifique, un compte BCGE, le Netbanking actif et un administrateur Multibanking désigné. |
| bLink (SIX) | Plateforme suisse d'open banking, plus de 30 banques | La BCGE n'apparaît pas dans les participants que j'ai pu vérifier. |

Autrement dit : **il n'existe pas d'API REST publique BCGE pour un compte
d'entreprise suisse.** La voie automatisée réelle en Suisse, pour une PME, c'est
EBICS — un protocole bancaire, pas une API web. C'est plus lourd à mettre en
place, et c'est ce que font tous les logiciels comptables suisses.

### 14.2 Les quatre questions à poser à votre conseiller

Pas « avez-vous une API » — on vous répondra non, et ce sera une réponse inutile.
Demandez ceci, dans cet ordre :

1. **Un contrat EBICS direct sur nos propres comptes BCGE** est-il possible pour
   une Sàrl, et à quel tarif ? (Le Multibanking sert à atteindre des banques
   tierces ; c'est l'accès à vos comptes BCGE qui vous intéresse.)
2. **La livraison quotidienne du camt.054** (avis de crédit détaillés) est-elle
   incluse ou facturée en supplément ?
3. **Le QR-IBAN** — gratuit, et sous quel délai ?
4. **Si EBICS n'est pas envisageable à notre taille** : le camt.054 est-il
   téléchargeable depuis le Netbanking, dans quel format et à quelle fréquence ?

### 14.3 Pourquoi ça ne bloque rien

`enregistrer_paiement()` se moque de savoir comment le fichier est arrivé. Un
camt.054 téléchargé à la main depuis le Netbanking une fois par jour, déposé
dans un dossier, produit exactement le même résultat qu'une livraison EBICS.

**Démarrez comme ça.** Deux minutes par jour au back office, et la boucle est
fermée dès la première semaine. EBICS devient une optimisation à faire quand le
reste tourne — pas une condition préalable qui repousse le projet d'un trimestre.

---

## 15. Le programme de facturation dirigé par l'IA

Votre exigence : **l'IA dirige le contenu, elle ne touche pas au format.** Le
module `facturation/ia.mjs` la tient par construction, pas par consigne.

### 15.1 La garantie, et pourquoi elle tient

Le modèle ne renvoie que **des codes de prestation et des quantités**. Le schéma
de sortie ne contient aucun champ de prix, aucun total, aucun élément de mise en
page. Ce qu'il ne peut pas exprimer, il ne peut pas le fausser.

Ensuite, dans notre code :

- le prix est relu **dans le catalogue en base**, jamais dans la réponse ;
- un code inventé est **refusé**, sans repêchage par ressemblance — c'est ainsi
  qu'on éviterait le pire, une prestation approchante facturée pour une autre ;
- une quantité aberrante est refusée ;
- une prestation absente du catalogue part **sans prix** dans une liste « à
  valider », et le document n'est pas envoyable tant qu'il en reste une ;
- la mise en page vient de `facture.mjs`, qui n'expose aucun paramètre que le
  modèle puisse atteindre.

Neuf tests dans `facturation/test-ia.mjs` vérifient tout ça sans réseau, en
injectant des réponses de modèle volontairement mauvaises. Le dernier compare
deux PDF — l'un composé à la main, l'autre depuis des lignes proposées par
l'IA — et vérifie qu'ils sont identiques à l'octet près.

### 15.2 Les relances aussi sont bridées

Le texte de la **mise en demeure est figé, mot pour mot** : il constitue le
débiteur en demeure au sens de l'art. 102 CO et fait courir l'intérêt moratoire.
L'IA n'est même pas appelée à ce niveau.

Aux niveaux 1 et 2 elle rédige deux phrases, mais **sans aucun chiffre, date ni
numéro** — ceux-là sont réinjectés par nous dans le PDF. Et si la réponse
contient malgré tout un chiffre, elle est écartée au profit d'un gabarit fixe.
Un montant halluciné ne peut pas partir chez un client.

### 15.3 Le catalogue est la pièce à remplir

`supabase/migrations/20260826170000_…` crée la table `prestations` avec sept
lignes de départ — main-d'œuvre ordinaire, samedi, nuit, déplacement, urgence,
diagnostic. **Les prix sont des ordres de grandeur, pas les vôtres.** C'est la
première chose à corriger : tant que le catalogue est faux, l'IA proposera des
devis faux avec une parfaite assurance.

---

## 16. Relances des devis

Un devis sans réponse n'est pas un refus, c'est un oubli — et c'est le poste où
une relance rapporte le plus, parce qu'elle ramène du chiffre d'affaires au lieu
d'aller le chercher.

- **J+5** puis **J+15** après l'envoi. Deux paliers, pas trois : au-delà,
  insister abîme la relation sans rien changer.
- Un devis dont la validité est passée **se classe en « expiré »** au lieu d'être
  relancé.
- Accepter ou refuser un devis **éteint la relance en attente dans la même
  transaction**, comme un paiement éteint le rappel d'une facture.
- `relances_a_envoyer()` rend désormais **une seule file** au back office, où
  chaque ligne dit si elle vise une facture ou un devis.

Scénario vérifié dans `supabase/tests/relances_devis.sql`.

### 16.1 Un défaut trouvé en exécutant, pas en relisant

La migration des devis remplaçait la contrainte d'unicité des relances par des
index partiels — et le `on conflict (facture_id, niveau)` de la migration
précédente ne savait plus les viser. Les relances de **factures** échouaient
alors à l'exécution, pas au déploiement : la migration passait, et le premier
cron du matin plantait.

Corrigé en répétant la condition de l'index dans l'inférence. Le genre de panne
qu'aucune relecture ne trouve et qu'un scénario rejoué trouve en trente secondes
— raison pour laquelle les deux scénarios sont versés au dépôt.

---

## 17. Pointage : rappel du lendemain 9h00, et cas Alen

Migration `20260826180000_notification_lendemain_9h.sql`. Première fois que je
touche au pointage — sur demande explicite.

### 17.1 Ce qui change

| | Avant | Après |
|---|---|---|
| Heure d'envoi | 18h00 UTC (20h00 à Genève l'été, 19h00 l'hiver) | **9h00 à Genève, toute l'année** |
| Période visée | la journée en cours | **les journées terminées, jusqu'à la veille** |
| Destinataires | tous les techniciens actifs | tous, sauf ceux dont `notifications` est coupé |

### 17.2 Trois détails qui n'étaient pas évidents

**Le texte devait changer avec l'horaire.** L'ancien message disait « un appui
sur *Enregistrer ma journée d'aujourd'hui* suffit ». Reçu le lendemain matin, ce
conseil ferait enregistrer le mauvais jour — le technicien croirait avoir
rattrapé son retard en créant une saisie fausse pour la journée qui commence. Le
message **nomme désormais les jours concernés** et renvoie vers eux.

**9h00 à Genève, pas 9h00 UTC.** pg_cron raisonne en UTC et Genève change
d'heure deux fois par an. Deux réveils sont posés, à 7h00 et 8h00 UTC, et la
fonction ne fait rien si l'heure locale n'est pas 9. Exactement un envoi par
jour ouvré, à la même heure en janvier comme en juillet.

**Le vendredi est rattrapé le lundi, pas le samedi.** Le lendemain d'un vendredi
est un samedi ; relancer quelqu'un sur sa feuille d'heures un samedi matin est
intrusif et ne fait rien gagner. La tâche reste du lundi au vendredi, et comme
la fenêtre couvre tous les jours ouvrés du mois jusqu'à la veille, un vendredi
manquant ressort le lundi.

### 17.3 Le cas Alen

`employes.notifications` passe à faux pour lui, et ses rappels automatiques sont
effacés de son fil. Deux précautions :

- **seuls les messages `automatique` sont supprimés.** Un mot écrit à la main
  par la direction reste, quoi qu'il arrive ;
- **si le prénom ne désigne pas exactement une personne, la migration s'arrête**
  au lieu de deviner. Mieux vaut la rejouer avec le bon prénom que de vider le
  fil de quelqu'un d'autre.

Alen **reste visible dans le contrôle de la direction** : on coupe la
notification, pas la surveillance. Remettre `notifications` à vrai le réintègre
immédiatement, sans autre manipulation.

### 17.4 Vérifié sur une base réelle, pas relu

Base jetable, dix-neuf migrations rejouées, données d'exemple : trois
techniciens, deux rappels automatiques et un message humain dans le fil d'Alen.

- fenêtre de relance jusqu'au 26.08, fenêtre de rapport jusqu'au 27.08 — la
  distinction voulue ;
- Alen : 0 rappel automatique restant, son message humain intact ;
- le rappel de Marc, lui, n'a pas bougé ;
- hors 9h locale, l'ordonnanceur renvoie −1 et n'écrit rien ;
- deuxième passage le même jour : aucun rappel reposé ;
- plus aucune occurrence du mot « aujourd'hui » dans les messages automatiques.

### 17.5 Deuxième dérive entre la base et le dépôt

Le rappel reçu par Steve le 27.08 à 20h00 disait : « touche le bouton vert en
haut : si l'horaire affiché est le bon, un appui suffit. Sinon, touche le jour
dans la liste pour le corriger. »

**Ce texte n'existe nulle part dans le dépôt.** Seul un commentaire de la
migration du 25.08 y fait allusion — « le texte du rappel reste donc neutre et
renvoie simplement au bouton vert ». La formulation elle-même a été posée
directement en production.

C'est la deuxième dérive après `employes.cle_acces`, et cette fois elle avait un
coût : ma migration remplace `controle_saisies`, donc elle aurait effacé cette
formulation-là sans que personne ne s'en aperçoive.

**Avant d'appliquer, capturez ce qui tourne :**

```sql
select prosrc from pg_proc
 where proname in ('controle_saisies', 'relancer_saisies', 'controle_rapport');
select jobname, schedule, command from cron.job order by jobname;
```

### 17.6 Pourquoi le bouton vert disparaît du message

Le bouton vert en haut de l'écran agit **toujours sur la journée du jour** —
« Enregistrer ma journée d'aujourd'hui », ou « Confirmer ma journée » quand elle
est déjà pré-remplie. Le rappel ne portant plus que sur des jours passés, ce
bouton n'est jamais la bonne action : un technicien qui le presse à 9h00 pour
rattraper la veille crée une saisie fausse pour la journée qui commence.

Le message reprend donc le geste que l'application propose déjà elle-même pour
un jour antérieur — « touche ce jour dans la liste » — et nomme les dates :

> Bonjour Steve, il reste 1 jour à confirmer dans ta feuille d'heures : 27.08.
> Ouvre l'application et touche ce jour dans la liste pour le confirmer. Merci !

### 17.7 À contrôler après application

La reprogrammation retire **toute** tâche appelant `relancer_saisies`, sans se
fier à son nom — un nom deviné et faux aurait laissé l'envoi du soir en place, et
les techniciens auraient reçu deux rappels par jour. Vérifiez quand même une
fois :

```sql
select jobname, schedule, command from cron.job order by jobname;
```

Vous devez voir exactement `relance-saisies-matin-a` (0 7 * * 1-5) et
`relance-saisies-matin-b` (0 8 * * 1-5), et plus rien du soir.

---

## 18. Pré-remplissage de la veille

Migration `20260828090000_preremplissage_veille.sql`, plus cinq retouches dans
`app/index.html`. Écrit après un audit du dépôt sur cinq dimensions de risque,
chaque constat soumis à un réfuteur : 23 constats tenaient, 15 ont été écartés.

### 18.1 Ce que l'audit a établi d'abord

**Votre application fait déjà ça, en un geste.** Le bouton « ✓ Compléter les N
jours manquants avec l'horaire normal » (`app/index.html`, `remplirManquants()`)
remplit tout le mois d'un coup — et il écrit `saisi_par = employe_id`, donc des
journées **confirmées**. C'est l'appui du technicien qui vaut attestation.

Automatiser ce geste ne lui épargne donc pas une saisie : il n'y en avait déjà
qu'une. Cela retire sa signature du dossier. D'où le choix retenu : la ligne est
posée, mais elle porte un marqueur `prerempli` et reste non confirmée. Le
technicien voit ses heures déjà écrites et correctes ; il lui reste le même
appui unique, qui atteste.

### 18.2 Les trois pannes qu'il a fallu fermer

**Le contrôle serait devenu aveugle.** `controle_saisies` distingue « vide »
(`p.id is null`, sans borne de date) et « non confirmé » (borné par
`tracabilite_depuis`). Créer la ligne fait sortir le jour de la première
catégorie sans le faire entrer dans la seconde dès qu'il est antérieur à cette
borne : le jour disparaissait du rappel, du rapport à la direction **et** de la
grille, sans qu'aucun canal ne le signale. Le marqueur rend le signal
indépendant de la date.

**L'application aurait menti.** `joursManquants()` mesurait le retard à
l'absence de ligne. Une fois la veille pré-remplie, le compteur tombait à zéro,
le bandeau basculait sur « ✓ Vos heures sont à jour » et le bouton de rattrapage
disparaissait — pendant que le message de 9h00 réclamait N confirmations, sans
que le technicien dispose du moindre moyen de les voir.

**Une absence serait devenue une journée travaillée.** Vacances, maladie,
accident, armée : un jour non saisi aurait été rempli en « travail », et
`feuilleEmploye()` ne lit jamais `confirme` — ces heures partaient à la
fiduciaire, sous une ligne « Signature employé ».

### 18.3 Ce que la génération ne fait jamais

- toucher une ligne existante : `on conflict do nothing`, sans exception ;
- écrire un week-end, un férié genevois, ou le jour en cours ;
- remonter avant `generation_depuis` (posé à la mise en service) ni avant
  `tracabilite_depuis` ;
- marquer la ligne comme confirmée : `saisi_par` reste nul.

Elle vit dans sa propre fonction, jamais accordée à `anon`, appelée par
`relancer_saisies()` **avant** la pose des rappels — pour que le message compte
les jours pré-remplis comme à confirmer, et non comme vides.

### 18.4 Vérifié sur base réelle

37 lignes posées pour 19 jours ouvrés écoulés × 2 techniciens moins la journée
déjà saisie ; 0 sur un week-end, 0 sur le jour en cours, 0 faussement attestée ;
la saisie humaine de Sofia intacte, heures et remarque comprises ; deuxième
passage : 0 ligne reposée ; le contrôle voit toujours 19 et 18 jours à
confirmer ; confirmer un jour fait tomber le marqueur ; un jour antérieur à la
borne reste vide. Scénario dans `supabase/tests/preremplissage.sql`.

### 18.5 Ce que je n'ai pas fait

**Les heures pré-remplies comptent toujours dans les totaux de l'export.** J'ai
ajouté un avertissement en rouge au-dessus du bloc de signature, qui nomme le
nombre de journées non attestées. Les sortir des totaux ou d'une colonne séparée
est une décision de fond sur votre relevé — elle vous revient.

**Le dernier jour ouvré de chaque mois n'entre dans aucune fenêtre de relance.**
La fenêtre part du 1er du mois courant : le 1er, elle est vide, et le dernier
jour ouvré du mois précédent n'est jamais réclamé. Défaut antérieur à ce
changement, non corrigé ici.

---

## 19. Arrêt des rappels automatiques

Migration `20260828100000_arret_rappels_automatiques.sql`.

### 19.1 L'arrêt immédiat, sans rien appliquer

Les messages partent encore chaque soir parce qu'aucune migration n'a été
appliquée. Pour que ça cesse tout de suite, une ligne dans l'éditeur SQL
Supabase :

```sql
select cron.unschedule(jobid) from cron.job where command ilike '%relancer_saisies%';
```

Rien d'autre ne s'arrête : le contrôle, la grille et l'application continuent.

### 19.2 L'interrupteur

Un paramètre, `rappels_automatiques`, posé à `non`. La coupure est dans
`relancer_saisies`, qui demande désormais un contrôle en lecture seule.

**`controle_saisies` n'est pas redéfinie** — c'est délibéré. Elle a divergé du
dépôt en production, et la remplacer effacerait la formulation que quelqu'un y a
écrite à la main. La coupure passe donc par l'appelant.

Ce qui continue de tourner : le pré-remplissage de la veille, s'il est installé.
Il ne parle à personne.

Ce qui reste possible : un appel direct à `controle_saisies(secret, true)` poste
encore. Seul le porteur du secret de contrôle peut le faire ; l'ordonnanceur ne
le demande plus.

### 19.3 Vérifié dans les deux sens

Migration appliquée **seule**, sur une base à l'état de la production
d'aujourd'hui : aucune erreur, aucun rappel posé. Sur la **pile complète** :
0 rappel, mais 6 journées pré-remplies posées au même réveil — les deux
mécanismes sont bien indépendants. Interrupteur remis à `oui` : 2 rappels
reparaissent, ce qui prouve que la coupure en était la cause, et non un effet de
bord. Recoupé : 0 à nouveau. Le contrôle de la direction remonte toujours les
deux techniciens et leurs jours en retard.

L'interrupteur par personne (`employes.notifications`) est laissé tel quel —
Alen reste à faux. Ils reprendront leur effet le jour où le paramètre global
repassera à `oui` :

```sql
update public.parametres set valeur = 'oui' where cle = 'rappels_automatiques';
```

---

## 20. Appliqué en production le 31.08.2026

Première fois que j'écris sur votre base. Les trois tours précédents produisaient
des fichiers que personne ne jouait, et les messages continuaient de partir tous
les soirs — c'est ce qui a motivé le geste.

### 20.1 Ce que j'ai fait, dans l'ordre

| Étape | Résultat |
|---|---|
| Lecture de `cron.job` | Une seule tâche : `relance-saisies-soir`, `0 18 * * 1-5`, active |
| Lecture de `public.messages` | 11 rappels automatiques, 2 messages humains |
| Empreinte des fonctions | `controle_saisies` contient bien le texte dérivé, absent du dépôt |
| Migration `arret_rappels_automatiques` | Appliquée |
| Suppression des rappels | 11 effacés, les 2 messages humains intacts |

Vérifié après coup : **0 tâche active**, interrupteur à `non`, **0 rappel
automatique**, 2 messages humains, et le texte de production de
`controle_saisies` toujours en place.

### 20.2 Ce que je n'ai PAS appliqué

Les migrations `20260826180000` (rappel du lendemain 9h00), `20260828090000`
(pré-remplissage) et celles de facturation restent sur la branche, non jouées.
La première remplacerait `controle_saisies` — donc le texte dérivé — et cela ne
se fait pas tant que la capture n'a pas servi de base.

### 20.3 La dérive, enfin conservée

`supabase/production/controle_saisies.sql` contient la définition réellement en
service, relevée par `pg_get_functiondef`. **Ce n'est pas une migration** et le
fichier vit hors de `supabase/migrations` : aucun rejeu ne peut le réappliquer
dans le mauvais ordre. Il est là pour qu'on ne perde plus ce texte, et pour
servir de référence à toute migration qui touchera cette fonction.

### 20.4 Correction : votre base est déjà en Suisse

Au §3 j'écrivais que Supabase n'avait pas de région suisse et qu'il faudrait
donc une machine chez Infomaniak ou Exoscale pour tenir l'argument « données en
Suisse ». C'est faux : votre projet tourne en **`eu-central-2`, c'est-à-dire
Zurich**. Les données applicatives sont déjà sur le territoire.

Ce que ça change : le poste « serveur » du budget (CHF 15/mois) n'a plus de
justification de conformité — seulement d'autonomie, si vous voulez sortir de
Supabase. L'argument commercial « données en Suisse », lui, est déjà acquis.
