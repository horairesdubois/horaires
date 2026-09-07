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

---

## 21. Journal des actions, et deux retouches d'interface

Migration `20260903080000_journal_actions.sql`, **appliquée en production le
03.09.2026**, plus trois changements dans `app/index.html`.

### 21.1 Il n'existait aucun journal

Vérifié sur la base : les tables étaient `bulletins`, `employes`, `marque`,
`messages`, `parametres`, `pointages`, `sessions`, `tentatives`. Rien d'autre.
La seule trace était `employes.derniere_connexion`, `pointages.saisi_par` et
`modifie_le` — de quoi savoir *qui a écrit quoi*, jamais *qui est passé quand*.
Et la fiduciaire, elle, n'était tracée nulle part.

### 21.2 Des déclencheurs, pas des appels dans chaque fonction

Instrumenter les fonctions existantes voudrait dire les réécrire une à une — or
plusieurs ont dérivé du dépôt et la version qui tourne n'est pas celle qu'on
lit ici. Un déclencheur s'attache à la table sans toucher au code qui l'écrit.

Et la table sait déjà qui a agi : `saisi_par`, `approuve_par`, `auteur_id`.

| Ce qui est inscrit | D'où |
|---|---|
| Connexion | déclencheur sur `sessions` |
| Ouverture de l'application | déclencheur sur `employes.derniere_connexion`, au plus une par demi-heure |
| Saisie, modification, suppression d'une journée | déclencheur sur `pointages` |
| Validation, déverrouillage | idem |
| Message écrit, rappel automatique | déclencheur sur `messages` |
| **Consultation de la fiduciaire** | seule fonction réécrite : `compta_donnees` |

`compta_donnees` a été relevée sur la base avant d'être reprise à la ligne près,
augmentée d'un seul appel. Une consultation est une lecture : aucun déclencheur
ne pouvait la voir.

### 21.3 Réservé à la direction

`journal_lire` exige `role = 'admin'`. Vérifié : direction `ok: true`,
technicien `ok: false`, fiduciaire `ok: false` — y compris sur leurs propres
lignes. L'onglet est masqué pour la fiduciaire, et bascule sur « Feuilles de
temps » si elle tente d'y rester.

### 21.4 Deux défauts trouvés à l'exécution

**Le déclencheur exigeait `pointages.prerempli`**, colonne créée par une
migration non appliquée. Il aurait fait échouer *toute* saisie en production. Il
lit désormais la clé par le JSON de la ligne : absente, l'action reste
« saisie ».

**Le déverrouillage s'inscrivait « inconnu »** : la fonction remet
`approuve_par` à nul en déverrouillant, la ligne ne dit plus qui agit. Seule la
direction peut déverrouiller — c'est donc « Direction » qui est inscrit, et
celui qui avait validé reste dans le détail, où il est une information et non
une accusation.

### 21.5 Les deux retouches d'interface

**Le bandeau du panneau** ne répète plus le métier, le mois ni la CCT : le back
office vient de les choisir lui-même. Ne reste que ce qu'il ignore — « vu
aujourd'hui à 14:33 ». L'aide passe de deux lignes à une, avec la coche dessinée
comme celle de l'écran : **✓** valide un jour · un second appui le déverrouille.

**Les heures en plus sans un mot** portent désormais une mention discrète dans
la liste de la direction. C'est exactement ce qu'on cherche à comprendre trois
semaines plus tard, et qu'on ne retrouve plus.

---

## 22. Publication : la branche par défaut n'est pas celle-ci

Point qui a coûté un aller-retour : GitHub Pages sert
**`claude/employee-schedule-system-jekf2k`**, qui est la branche par défaut du
dépôt. Tout ce qui est écrit ici, sur
`claude/tech-stack-ai-automation-xumqe5`, n'est **pas publié**. C'est pour ça
que l'onglet Journal restait invisible alors que la base le servait déjà.

Diagnostic : la page en ligne pesait 163 762 octets, exactement le
`docs/index.html` de la branche par défaut, quand celui d'ici en pesait 169 854.

### 22.1 Ce qui a été poussé sur la branche publiée

Sur demande, **l'onglet Journal seul** — commit `405cf9d`. Deux fichiers,
158 lignes ajoutées, une supprimée (le garde-fou fiduciaire, remplacé par sa
version étendue). Vérifié qu'aucune autre retouche n'a fui : ni le bandeau
simplifié, ni la mention « heures en plus sans explication », ni rien de ce qui
dépend du pré-remplissage.

Publié et vérifié en ligne vingt secondes après le push.

### 22.2 Ce qui reste ici, non publié

Le bandeau simplifié du panneau, la mention des heures en plus sans explication,
le rattrapage des jours pré-remplis, et tout le module de facturation.

### 22.3 À retenir pour la suite

Une modification d'interface n'existe pour les utilisateurs qu'une fois sur
`claude/employee-schedule-system-jekf2k`. Les migrations, elles, ne dépendent
d'aucune branche : elles s'appliquent directement sur la base.

---

## 23. Journal : par personne, et la fiduciaire par sa fonction

Appliqué en production le 03.09.2026, et publié sur la branche par défaut.

### 23.1 Lire le journal d'une seule personne

Mélangé, le journal ne raconte qu'une suite d'événements ; c'est en le lisant
personne par personne qu'une habitude apparaît. `journal_lire` renvoie donc,
en plus des lignes, la liste des acteurs de la période avec leur nombre
d'actions, et accepte `p_acteur` pour n'en garder qu'un.

**La liste des acteurs ignore volontairement `p_acteur`.** Sans ça, choisir
quelqu'un ferait disparaître tous les autres boutons, et on ne pourrait plus
revenir en arrière qu'en rechargeant la page.

Elle ne contient que des gens qui ont *effectivement* agi sur la période :
proposer un filtre qui ne rendra rien est pire que ne pas le proposer.

### 23.2 « La fiduciaire », pas son prénom

Le journal affiche `La fiduciaire` pour tout acteur de rôle `compta`. Deux
raisons : c'est sa fonction qui intéresse la direction, pas son identité ; et
le compte peut changer de titulaire sans que l'historique devienne faux.

La substitution se fait **à la lecture**, dans `journal_lire`. La table, elle,
continue d'enregistrer le nom réel — une trace qui ment n'est plus une trace.

### 23.3 Une erreur de ma part, à noter

Dans un message précédent, j'ai illustré le rendu du journal avec un exemple
inventé mentionnant une « Nadia » à l'espace fiduciaire, tirée de mes données de
test. Présenté sous « ce que vous y verrez », cela laissait croire à un
enregistrement réel. Aucune Nadia n'existe dans ce système.

---

## 24. Soumis par qui, et quel horaire

Appliqué en production et publié le 03.09.2026.

### 24.1 La question à laquelle le journal ne répondait pas

Voir le passage d'un technicien ne dit pas s'il a soumis quelque chose. Et une
journée de 07:30–12:00 · 13:00–17:00 ne dit pas si elle a été *tapée* ou
simplement *acquittée* d'un appui sur le bouton.

Chaque écriture porte désormais deux mentions, calculées au moment où la ligne
est écrite :

| `detail.par` | quand |
|---|---|
| `technicien` | `saisi_par = employe_id` — l'intéressé lui-même |
| `back office` | un autre compte a posé la journée à sa place |
| `systeme` | aucun auteur : la génération automatique |

| `detail.horaire` | quand |
|---|---|
| `type` | les quatre heures égalent les valeurs par défaut de sa fiche |
| `modifie` | au moins une heure s'en écarte |
| *(absent)* | la journée n'est pas du travail — vacances, maladie, etc. |

**Le calcul se fait à l'écriture, jamais après.** L'horaire type d'un employé
peut changer ; relire la journée d'hier à l'aune du contrat d'aujourd'hui
produirait une réponse fausse et invérifiable.

### 24.2 Ce que ça donne à l'écran

- ✅ **Steve Carvalho a saisi le 02.09** · `horaire type`
- ✏️ **Steve Carvalho a saisi le 02.09** — 07:30-12:00 · 13:00-19:30 · `horaire modifié`
- ✏️ **Back Office a saisi le 02.09 de Steve** · `horaire type` `posée par le back office`
- 🤖 **Le système** journée du 02.09 posée automatiquement · `sans intervention du technicien`

Les heures ne sont plus répétées quand il s'agit de l'horaire type : la pastille
le dit, et la ligne reste lisible. Une journée sans auteur s'affiche « Le
système » et non « inconnu » — elle n'est pas inconnue, elle n'a simplement pas
d'auteur humain.

### 24.3 Deux limites à connaître

**Les lignes antérieures au 03.09 n'ont pas ces mentions.** Elles ont été
écrites avant que le déclencheur ne les calcule. Impossible de les reconstituer
sans risquer de mentir.

**Aucune ligne `systeme` n'existera tant que le pré-remplissage n'est pas
appliqué.** La migration `20260828090000` reste sur la branche : aujourd'hui,
toute journée de votre base a été posée par un humain.

---

## 25. Le total mensuel était faux de dix heures

Votre intuition était juste, et l'écart est important.

### 25.1 Deux règles pour une même question

L'application calculait les heures dues de **deux façons différentes** :

| | Règle appliquée | Août 2026 |
|---|---|---|
| Grille d'équipe et panneau détail | 8h00 par jour ouvré — **40 h/semaine** | 168h00 dues |
| Relevé Excel envoyé à la fiduciaire | 8h00 + 2h00 le premier jour ouvré de la semaine — **42 h/semaine** | 178h00 dues |

Le contrat est de 42 heures : **c'est l'écran qui avait tort**, et il affichait
dix heures de trop au crédit de chacun.

Mesuré sur vos données réelles d'août 2026 :

| | Total travaillé | Solde affiché | Solde réel | Écart |
|---|---|---|---|---|
| Alen | 165h00 | −3h00 | **−13h00** | 10h00 |
| Sami | 219h53 | +51h53 | **+41h53** | 10h00 |
| Steve | 222h15 | +54h15 | **+44h15** | 10h00 |

Dix heures par personne et par mois — sur trois techniciens, trente heures qui
n'existaient pas.

### 25.2 La correction

`heuresDues` partage désormais `dueDuJour` et `ABS_PAYEE` avec l'export : une
seule règle, un seul endroit où la corriger. Elle rend le **net** — ce qui est
dû moins ce qui est crédité — de sorte qu'une absence payée s'annule et qu'un
congé non payé reste dû, exactement comme dans le relevé.

Vérifié en exécutant le vrai code de l'application sur les données réelles :
les trois soldes tombent à la minute sur ceux du relevé.

### 25.3 Ce qui n'est pas corrigé

`heuresSupJour`, qui alimente la pastille « Heures sup » et le `+X:XX` de
chaque ligne, compte toujours 8h00 par jour sans le complément hebdomadaire.
C'est une autre notion — les heures au-delà d'une journée normale, utilisée
pour les majorations CCT — et non le solde du mois. Elle ne fausse pas le
total, mais les deux chiffres ne se déduisent pas l'un de l'autre. À trancher
si vous voulez qu'ils s'accordent.

---

## 26. Une question porte sur un jour

Migration `messages_jour_reference`, appliquée en production.

Votre dernière question à Sami disait « Lundi 31 août 2026 pourrais-tu me
donner plus de détails sur tes heures supplémentaires ». Écrite dans le texte,
la date oblige le technicien à la retrouver — Steve avait déjà répondu
« Le quel jour tu parle ? » à un rappel automatique.

La date devient une donnée : `messages.jour`. Le back office la choisit dans un
sélecteur borné au mois affiché, et la bulle affiche un bouton
**📅 lundi 31 août 2026** qui ouvre directement la journée concernée, des deux
côtés.

**Le paramètre a été ajouté sans interruption de service** : la fonction est
recréée avec `p_jour date default null` dans la même transaction que sa
suppression, si bien que l'application déjà publiée — qui n'envoie que cinq
arguments — continue de fonctionner pendant la mise à jour de l'écran.

Une date hors du mois du fil est refusée : le lien renverrait vers un écran que
le destinataire n'a pas sous les yeux.

### 26.1 Publié le 03.09.2026

Les deux changements sont en ligne sur la branche par défaut, commit `9625ad9`.
Contrôlé sur la page servie : plus aucune trace de l'ancien calcul (`baseMin`),
`dueDuJour` en place, le sélecteur de date et le bouton présents.

Le code réellement publié a été exécuté sur les données d'août 2026 : les trois
soldes tombent à la minute sur ceux du relevé — Alen −13h00, Sami +41h53,
Steve +44h15.

---

## 27. Le champ de saisie qui se dérobait

### 27.1 Ce qui se passait

Toutes les soixante secondes, la page se rafraîchit pour refléter ce que les
techniciens ont saisi entre-temps (`setInterval`, fin de fichier). Ce
rafraîchissement appelle `charger()` → `renderAdmin()` → `renderMessages()`,
qui reconstruit `ong-messages.innerHTML` **en entier, champ de saisie compris**.

Le brouillon survivait — il était relu et réinjecté — mais l'élément était
détruit et recréé : le curseur disparaissait au milieu d'une phrase, et il
fallait recliquer. Une fois par minute, exactement.

### 27.2 Deux corrections, l'une dans l'autre

**La cause** : tant que quelqu'un a le curseur dans un champ, le
rafraîchissement passe son tour. `enTrainDEcrire()` regarde simplement
`document.activeElement`.

**Le filet** : si un autre chemin reconstruit malgré tout l'onglet, la position
du curseur — début et fin de sélection — est notée avant et rétablie après.
Corriger la seule cause connue aurait laissé le défaut réapparaître au premier
appel qu'on ajouterait ailleurs.

---

## 28. Corriger un message

Migration `20260903120000_messages_modifiables.sql`, appliquée en production.

Un message se corrige depuis sa bulle : il revient dans le champ de saisie, au
même endroit qu'on l'a écrit la première fois, avec sa date liée. Le bouton
devient « Enregistrer la correction », et « Annuler » à côté.

### 28.1 Une trace plutôt qu'une interdiction

Un message déjà lu qu'on récrit en silence réécrit l'histoire : le destinataire
a répondu à une question qui n'existe plus. Interdire la correction n'aide pas
non plus — elle pousse à envoyer un second message qui contredit le premier.

La correction est donc permise, mais elle laisse une marque **« modifié »**
visible des deux côtés, et une ligne au journal portant l'avant et l'après.

### 28.2 Ce qui est refusé

- modifier le message d'un autre — seul l'auteur le peut ;
- modifier un rappel automatique — il n'a pas d'auteur au sens où on l'entend ;
- attacher une date hors du mois du fil.

Vérifié sur base jetable : les trois refus tombent, la marque se pose, et le
journal enregistre la correction avec les deux versions.

### 28.3 Côté technicien

Il voit la marque « modifié », mais ne peut pas encore corriger ses propres
messages depuis son écran — son champ de saisie est un élément fixe de la page,
pas reconstruit comme celui du back office. La fonction en base l'accepterait
déjà : c'est un raccordement d'écran, à faire si vous le voulez.

---

## 29. Le non-lu qu'on ne trouvait pas

Migration `20260907090000_non_lus_visibles.sql`, appliquée en production.

Un « 2 » en rouge dans Questions, et aucun message à l'écran. Deux causes
distinctes se cachaient derrière le même symptôme.

### 29.1 Ouvrir l'application n'est pas lire

`messages_lire` marquait lu avant de compter. Or le chargement des données
appelle cette lecture : côté technicien à chaque ouverture, côté back office
toutes les minutes depuis n'importe quel onglet. Un message arrivé le matin
était donc « lu » sans que personne ne l'ait eu sous les yeux, et la pastille
du mois affiché ne s'allumait jamais.

La lecture ne marque plus rien (`p_marquer` faux) ; le marquage devient un
geste à part, `messages_marquer_lus` :

- **côté technicien** — déclenché quand la carte des questions est réellement
  à l'écran (`IntersectionObserver`, seuil 0,4). Pas quand elle existe plus bas
  dans la page : quand on la regarde ;
- **côté back office et fiduciaire** — déclenché quand l'onglet Questions est
  affiché *et* que le fil concerné est celui qu'on lit. Choisir l'onglet est
  déjà un geste ; le rafraîchissement d'arrière-plan n'en est pas un.

### 29.2 Le compteur ignore le mois, la vue est filtrée dessus

C'est l'autre moitié du « 2 » en rouge : Sami avait répondu le 4 septembre
**dans le fil d'août**, et le back office regardait septembre. Le compteur
additionne tous les mois, l'écran n'en montre qu'un — d'où un chiffre sans
message.

`messages_lire` renvoie donc `autres_mois` : où sont les non-lus qu'on ne peut
pas atteindre depuis l'écran courant, les plus récents d'abord. Un bandeau les
nomme et y emmène d'un appui, des deux côtés.

Côté back office il faut un pas de plus : le bon mois ne suffit pas, il faut
aussi le bon fil. Après le saut, l'écran se pose sur le fil qui porte les
non-lus — sinon le bandeau mènerait exactement à l'écran vide qu'il répare.

Vérifié sur la base de production, en transaction annulée : deux messages
d'août rendus non lus, interrogés depuis septembre, renvoient bien
`non_lus: 2` et `autres_mois: [août 2026, 2]`, avec un fil de septembre vide.

---

## 30. Le journal, complet et réservé

Migration `20260907110000_journal_complet.sql`, appliquée en production.

Le journal voyait les écritures sur les pointages et les messages, les
connexions et les ouvertures. Il ignorait le reste.

### 30.1 Ce qu'il voit désormais

Déconnexions, bulletins déposés ou retirés, fiches modifiées, réglages
modifiés, et messages lus — avec qui les a lus. Tout passe par des
déclencheurs sur les tables : ils voient la ligne, donc l'action, et la table
porte souvent l'auteur (`saisi_par`, `auteur_id`, `depose_par`). Pour les
gestes que seule la direction peut accomplir, on inscrit « Direction » plutôt
que de deviner lequel des administrateurs.

**Aucun secret n'est recopié.** Le journal dit qu'un code PIN ou une clé
d'accès a changé, jamais sa valeur : la base écrit `« — modifié — »` à la
place. Une trace qui recopie les secrets devient la faille qu'elle surveille.

### 30.2 Le jour même veut dire depuis minuit

La fenêtre de lecture se comptait en tranches de vingt-quatre heures : à 16h,
« 1 jour » remontait à hier 16h. Elle se compte maintenant en jours civils
genevois, et un filtre **Aujourd'hui** s'ajoute à 7 jours, 30 jours et 3 mois.

### 30.3 Trois verrous, pas un

L'onglet ne doit s'ouvrir que depuis le back office — ni la fiduciaire, ni un
technicien, par aucun lien. Vérifié en production, rôle par rôle :

| Qui | `journal_accessible` |
|---|---|
| Back office (`admin`) | `true` |
| Fiduciaire (`compta`) | `false` — accès refusé |
| Technicien (`employe`) | `false` — accès refusé |

Les trois verrous sont indépendants : RLS sur `public.journal` **sans aucune
politique** (personne ne lit la table en direct), `journal_lire` qui exige
`role = 'admin'`, et l'onglet masqué côté écran. Cacher le bouton seul
n'aurait rien fermé.

---

## 31. Ce que l'audit du compteur a retenu

Le « 2 » en rouge sans message à l'écran ne venait pas d'un défaut mais de
quatre, empilés. Un audit adverse — plusieurs lecteurs indépendants, puis des
contradicteurs chargés de démolir chaque constat — en a écarté la moitié et
confirmé le reste.

### 31.1 Retenus et corrigés

| Constat | Gravité | État |
|---|---|---|
| Le rafraîchissement de 60 s marquait lu un fil que personne n'avait à l'écran | bloquant | corrigé (§ 29.1) |
| Le bandeau « autres mois » n'existait que côté technicien | bloquant | corrigé (§ 29.2) |
| Un collaborateur désactivé perdait son onglet, pas ses non-lus | bloquant | corrigé ci-dessous |
| Les pastilles par personne survivaient au changement de mois | mineur | corrigé ci-dessous |

**Le collaborateur parti.** `ongletsFils()` ne listait que les comptes actifs.
Le jour où quelqu'un s'en va avec un message non lu, ce message reste compté
dans la pastille et plus aucun bouton ne l'ouvre : le compteur ne peut plus
revenir à zéro, définitivement. Son fil se rouvre donc tant qu'il porte quelque
chose dans le mois affiché — `messages_lire` en donne déjà le nom, il n'y a
rien à deviner. Un seul compte est désactivé aujourd'hui (`ZTest`, sans
message) : le piège était armé pour le premier vrai départ.

**Les pastilles fantômes.** `moisNav` vidait les messages mais pas `S.fils` :
le temps du chargement, les compteurs par personne du mois précédent
s'affichaient sous le titre du nouveau.

### 31.2 Écartés, et pourquoi

- **« Les rappels automatiques gonflent la pastille »** — le mécanisme existe
  (ils s'insèrent `lu_direction = false`), mais ils sont coupés depuis
  `20260828100000` et la base n'en porte aucun non lu. Rien à corriger.
- **« La fiduciaire hérite d'un non-lu sur les fils privés des techniciens »** —
  elle a bel et bien accès à ces fils ; ce n'est pas une fuite, c'est le
  fonctionnement voulu.
- **« Deux comptes fiduciaire partagent un seul drapeau `lu_compta` »** — vrai
  en théorie, sans objet ici : il n'y a qu'un compte `compta`.

### 31.3 Laissé ouvert, à votre appréciation

Corriger un message ne réarme aucun drapeau de lecture : le destinataire a lu
l'ancienne version, voit la marque « modifié » s'il rouvre le fil, mais rien ne
le rappelle. On pourrait faire repasser le message en non lu quand le texte
change réellement. C'est un choix, pas un défaut : à dire si vous le voulez.

Second point, théorique aujourd'hui : les drapeaux de lecture sont posés par
camp (`lu_direction`, `lu_compta`, `lu_employe`), pas par personne. Le jour où
un second accès fiduciaire est créé, l'un soldera les non-lus de l'autre. Il
n'y a qu'un compte `compta` : rien à faire tant que cela reste vrai.

Chiffres de l'audit : 29 lecteurs et contradicteurs, 25 constats produits,
8 retenus après réfutation — les six premiers corrigés ici, les deux derniers
ci-dessus.

---

## 32. État réel de la base, au 7 septembre 2026

Relevé après l'audit, pour qu'aucun écart entre ce dépôt et la production ne
reste implicite.

| Élément | En base | Remarque |
|---|---|---|
| Tâches planifiées (`cron.job`) | **aucune** | dernier passage le 31 août |
| `rappels_automatiques` | `non` | conforme à la demande |
| `relancer_saisies()` | installée | plus appelée par personne |
| `generer_pointages_manquants()` | **absente** | le pré-remplissage n'a jamais été posé |
| Messages non lus | 0 | tous fils, tous mois, tous rôles |
| `journal`, `messages`, `parametres` | RLS active, 0 politique, 0 droit `anon` | lecture uniquement par fonction |

### 32.1 Le pré-remplissage est écarté

La question a été posée, la réponse est non :

> « Non, ne pré-remplis pas les journées de 8h. Laisse le bouton où il suffit
> qu'ils cliquent dessus pour pré-remplir 8h. »

Ce que le bouton fait déjà, sur l'écran du technicien : **« ✓ Compléter les N
jours manquants avec l'horaire normal »**, qui pose l'horaire type de la fiche
(08:00–12:00 · 13:00–17:00 par défaut) sur tous les jours ouvrés non saisis du
mois. Même horaire, même effet qu'une tâche de nuit — mais c'est lui qui
appuie, et c'est là toute la différence : personne n'atteste à sa place.

La migration et son test sont déplacés dans `supabase/non_retenu/`, qui n'est
jamais rejoué, avec la note qui explique pourquoi. Les laisser dans
`migrations/` aurait été un piège : `relancer_saisies()` est en base et appelle
`generer_pointages_manquants()` **dès qu'elle la trouve**. Reposer la migration
aurait donc rallumé le pré-remplissage en silence, à la première tâche
planifiée.

Le code d'écran qui l'accompagnait (`aTraiter`, la mention « pré-remplie » dans
l'export, la tolérance dans `nonConfirme`) est retiré avec elle.

### 32.2 Les deux branches avaient divergé

`claude/employee-schedule-system-jekf2k` (publiée) portait le renommage
« Back Office » que la branche de travail n'avait jamais reçu ; la branche de
travail portait le pré-remplissage, jamais publié. Un aller-retour entre les
deux produisait donc des conflits et risquait de republier d'anciens libellés.

L'écran repart de ce qui est en ligne, augmenté des deux seules améliorations
demandées qui restaient en attente : la modale de revue ne répète plus le
métier, le mois et la CCT, et une journée qui dépasse l'horaire normal **sans
une ligne d'explication** le signale.

---

## 33. Supprimer un message envoyé par erreur

Migration `20260907140000_message_supprimable.sql`, appliquée en production.

> « Si je fais une erreur, je dois pouvoir être en mesure de supprimer un
> message », et sans que l'autre partie le voie.

Le bouton **Supprimer** apparaît dans la bulle, à côté de *Modifier*.

### 33.1 Une suppression franche, pas un masquage

Pas de pierre tombale, pas de « message supprimé » dans le fil : la ligne s'en
va pour de bon. Un message seulement masqué resterait une ligne — il
continuerait de compter dans les non-lus et ressortirait au premier oubli de
filtre. La demande était de le faire disparaître ; il disparaît.

### 33.2 Qui peut supprimer quoi

Le back office, et **seulement ses propres messages**. Effacer les mots d'un
technicien ne serait plus corriger une erreur, ce serait récrire ce qu'il a
dit — et sur des heures de travail, c'est précisément ce qu'un registre est
censé empêcher. La fiduciaire et les techniciens sont refusés par la base, pas
seulement par l'écran.

### 33.3 Ce qui reste, et où

Une ligne au journal : le texte supprimé, le mois, l'heure d'écriture, et si le
destinataire l'avait déjà lu. Le journal ne s'ouvre que depuis le back office —
le technicien ne voit rien, ni le message, ni sa disparition.

Sans cette ligne, un accès administrateur pourrait effacer une conversation
sans laisser de trace nulle part, et le journal ne vaudrait plus rien.

### 33.4 Vérifications

Sur base jetable, neuf étapes : refus du technicien, refus de la fiduciaire,
refus sur le message d'autrui, suppression du sien, fil réduit de trois à deux
messages **sans pierre tombale**, ligne au journal complète, journal refusé aux
trois autres rôles, identifiant inconnu sans effet.

Puis sur la base réelle, en transaction annulée : mêmes refus, même
suppression, même ligne au journal — et rien qui subsiste après le retour
arrière.

---

## 34. Le dépôt sait de nouveau reconstruire la base

Le scénario ci-dessus a révélé autre chose : **`supabase/migrations/` ne
reconstruisait plus rien**. Rejouées sur une base vide, les migrations
s'arrêtaient trois fois.

| Ce qui manquait | Depuis | Conséquence au rejeu |
|---|---|---|
| `employes.cle_acces` | créée à la main en production | arrêt à `20260825070000` |
| `messages.jour` | créée à la main en production | arrêt à `20260903120000` |
| garde-fou « Alen » | écrit pour une base peuplée | arrêt à `20260826180000` |

Les deux colonnes sont rattachées, en `add column if not exists`, à la
migration qui les lit la première — sans effet en production, où elles
existent. Le garde-fou ne s'applique plus qu'à une base qui contient déjà des
collaborateurs : sur une base vide il n'y a personne à viser, et refuser
d'avancer n'y protégeait rien.

**Vérifié** : les 25 migrations passent d'affilée sur une base vide, sans une
seule retouche à la main, et les quatre scénarios de test (`journal`,
`relances`, `relances_devis`, `suppression_message`) passent sur la base ainsi
reconstruite.

### 34.1 Ce que le rejeu produit en plus, et pourquoi

Comparaison colonne par colonne avec la production : **rien de ce qu'elle
contient ne manque au rejeu**. L'inverse n'est pas vrai — le rejeu crée en plus
`clients`, `devis`, `factures`, `paiements`, `prestations`, `relances` et
`employes.notifications`, qui viennent de trois migrations écrites mais jamais
appliquées : la facturation (§ 13–16) et la notification de 9h00, abandonnée
avec les rappels.

Ce n'est pas une dérive à corriger : c'est du travail en attente de décision.
Rien de dangereux à les appliquer non plus — les rappels resteraient muets, le
paramètre `rappels_automatiques` valant `non`.

### 34.2 La base n'est pas qu'à nous

Le projet Supabase héberge aussi un schéma `bastion` (13 tables), qui appartient
à une autre application. Rien de ce dépôt n'y touche : tout ce qui précède vit
dans le schéma `public`.

---

## 35. La fiduciaire dans le journal

Migration `20260907160000_journal_fiduciaire.sql`, appliquée en production.

Le journal ne montrait aucune ligne pour la fiduciaire. La première explication
est la bonne, et elle est banale : **elle n'a pas ouvert l'application depuis le
27 août**, et le journal date du 1er septembre. Il n'y avait rien à montrer.

Mais en vérifiant, trois défauts sont apparus.

### 35.1 Une ligne par minute

`compta_donnees` écrivait une ligne « consultation » **à chaque appel** — et
l'écran se rafraîchit toutes les minutes. Une fiduciaire qui laisse son onglet
ouvert une journée aurait posé près de cinq cents lignes identiques : le
journal se serait noyé le jour même où il aurait enfin servi.

La consultation est désormais limitée à **une ligne par demi-heure et par mois
regardé**. Le mois fait partie de la clé, volontairement : rester deux heures
sur septembre n'apprend rien de plus, mais passer de septembre à juin est
précisément ce qu'on cherche à voir.

### 35.2 Le back office n'était pas tracé du tout

`admin_donnees` n'écrivait rien et ne touchait pas `derniere_connexion`. On
voyait ce que la direction faisait, jamais quand elle arrivait. Comparer des
habitudes suppose de regarder les deux côtés de la même façon : la direction
pose maintenant les mêmes lignes que la fiduciaire, et apparaît comme les
techniciens dans la colonne « dernière ouverture ».

### 35.3 « Message lu » n'avait pas d'auteur

Le déclencheur ne voit que la ligne, jamais l'appelant : il inscrivait
« Direction » ou « La fiduciaire » **sans identifiant**, et ces lignes
échappaient au classement par personne — celui-là même qui donne son sens au
journal.

Les fonctions qui marquent lu déposent donc leur identité dans un réglage de
transaction (`set_config(..., true)`, qui meurt avec la transaction), que le
déclencheur relit. Et la cible nomme l'auteur du message, pas le fil : sans
cela, la fiduciaire se lisait elle-même.

| Qui lit | Ce que le journal dit |
|---|---|
| Back office, fil partagé | a lu le message **de la fiduciaire** |
| Fiduciaire, fil partagé | a lu le message **de la direction** |
| Back office, fil d'un technicien | a lu le message **de Sami** |

### 35.4 L'export, enfin visible

C'est le geste central de la fiduciaire — ce qu'elle emporte, et quand — et la
base ne le voyait pas passer : le fichier Excel est fabriqué dans le navigateur.
L'écran le déclare désormais par `journal_noter`, dont **la liste des actions
acceptées est fermée**. Une fonction ouverte laisserait n'importe quel porteur
de la clé publique écrire ce qu'il veut dans le registre, et un registre qu'on
peut remplir à volonté ne prouve plus rien.

### 35.5 Ce que le back office verra d'elle

    👁  a ouvert l'espace fiduciaire sur septembre 2026
    📥  a exporté septembre 2026 — 3 collaborateurs
    👀  a lu le message de la direction
    💬  a écrit à tous
    🚪  s'est déconnectée

### 35.6 Vérifications

Sur base reconstruite depuis zéro : quatre rafraîchissements d'affilée ne
posent qu'une ligne, un changement de mois en pose une seconde, le back office
apparaît à son tour, les trois formulations de « message lu » sont exactes,
l'export est inscrit, une action hors liste est refusée, et le journal reste
fermé à la fiduciaire comme au technicien.

Puis sur la base réelle, en transaction annulée : mêmes résultats, et rien qui
subsiste — `derniere_connexion` de la fiduciaire est restée au 27 août.

Un déclencheur voisin méritait d'être vérifié : `_trg_journal_employe` ignore
explicitement `derniere_connexion`. Sans cela, toucher la présence toutes les
minutes aurait écrit « fiche modifiée » toutes les minutes.

---

## 36. Ce qu'un technicien peut atteindre — vérification complète

Demandée explicitement : « vérifie que les employés n'ont accès qu'à leur propre
information ». La réponse est **oui pour tout ce qui passe par une session**, et
**non pour une porte laissée ouverte à côté**.

### 36.1 La porte dérobée : `_save_jour`

`public._save_jour` est le cœur de l'écriture d'une journée. Elle ne demande
**aucun jeton** : elle prend l'employé en paramètre, accepte `p_admin` — qui
contourne le verrou des jours déjà validés — et `p_auteur`, qui décide de la
signature portée au journal. C'est voulu : ses deux appelants,
`enregistrer_jour` et `admin_enregistrer_jour`, ont déjà vérifié la session et
le rôle.

Elle était pourtant **accordée au rôle `anon`** — celui de la clé publique que
porte la page publiée, lisible par quiconque ouvre le code source. Vérifié en
conditions réelles, depuis Internet :

    POST /rest/v1/rpc/_save_jour   →   {"ok": false, "erreur": "Date invalide"}

La fonction *s'exécute*. Avec une date valide et l'identifiant d'un technicien —
que `messages_lire` rend d'ailleurs disponible à qui possède un lien — n'importe
qui pouvait écrire ou récrire une journée, passer outre une validation du back
office, et signer la ligne du nom d'un autre.

**Aucun essai d'écriture n'a été fait sur des données réelles.** La preuve a été
obtenue avec une date invalide, que la fonction rejette d'elle-même : il suffit
de la voir répondre.

**Correctif** : les fonctions internes (préfixe `_`) ne sont plus accordées
qu'à leur propriétaire. Les fonctions publiques sont `security definer` et
s'exécutent sous ce propriétaire — rien ne change pour l'application. La règle
est écrite **en boucle plutôt qu'en liste** : une fonction interne ajoutée
demain se refermerait toute seule, là où une liste l'aurait oubliée.

    POST /rest/v1/rpc/_save_jour   →   permission denied for function _save_jour

### 36.2 Le registre que ses sujets pouvaient garnir

`journal_noter` ne vérifiait que la session : un technicien pouvait y inscrire
de fausses lignes « a exporté ». Peu de dégâts, mais un registre que les
surveillés peuvent remplir ne prouve plus rien. Réservé au back office et à la
fiduciaire, dont c'est l'écran.

### 36.3 Tout le reste tient

Vérifié depuis une vraie session de technicien, sur la base réelle en
transaction annulée, puis rejoué comme scénario (`supabase/tests/acces_technicien.sql`) :

| Ce que le technicien tente | Résultat |
|---|---|
| Ouvrir l'écran du back office | refusé |
| Ouvrir l'écran de la fiduciaire | refusé |
| Ouvrir les logs | refusé |
| Valider ou supprimer le jour d'un autre | refusé |
| Régénérer la clé d'accès d'un autre | refusé |
| Modifier la fiche d'un autre, se nommer admin | refusé |
| Changer un réglage de l'entreprise | refusé |
| Écrire dans le registre | refusé |
| Lire le fil d'un autre (`p_employe` forcé) | **son propre fil** est rendu |
| Écrire dans le fil d'un autre | le message atterrit **dans le sien** |
| Lister ou télécharger le bulletin d'un autre | rien, « bulletin introuvable » |
| Lire ses pointages | **une seule personne** : lui |

Le point important est la troisième ligne du bas : forcer l'identifiant d'un
collègue dans l'appel ne produit pas une erreur, il produit **ses propres
données**. Le paramètre est ignoré pour un technicien — c'est plus sûr qu'un
refus, car il n'y a rien à contourner.

---

## 37. Trois écrans en moins de bruit

- **« Journal » devient « Logs »**, le mot demandé.
- **L'onglet « Bulletins de salaire » disparaît**, des deux côtés : l'onglet du
  back office et la carte « Mes bulletins » du technicien. Les fonctions en base
  restent — on retire un écran, on ne détruit ni données ni capacité. Le code
  d'écran devenu mort est retiré, lui : dépôt, téléchargement, suppression,
  styles.
- **« Export comptable » devient « Exporter »**, et le bouton de téléchargement
  porte partout le même libellé.
- **Le nom de l'entreprise disparaît de l'en-tête** : le logo le dit déjà. Il
  reste réglable dans l'onglet Exporter, où il sert au fichier Excel.

Un garde-fou accompagne le retrait : si l'application se souvient d'un onglet
qui n'existe plus, elle revient aux feuilles de temps plutôt que d'afficher un
écran vide.

---

## 38. Qui a décroché, sans écrire à personne

Migration `20260907200000_retards_saisie.sql`, appliquée en production.

Seule amélioration retenue parmi celles proposées.

### 38.1 Pourquoi ce n'est pas un rappel

Les rappels automatiques ont été coupés, et à raison : ils harcelaient les
techniciens tous les jours pour un oubli d'une demi-journée. Le suivi quotidien
reste pourtant nécessaire — savoir qui avance, et qui a décroché.

La réponse n'est donc pas un message de plus. C'est un **indicateur muet, dans
l'écran du back office et nulle part ailleurs** : le technicien ne le voit pas,
ne reçoit rien, et n'apprend même pas qu'il existe. C'est au back office de
décider s'il faut en parler, et comment.

La fiduciaire ne le voit pas non plus : la fonction exige le rôle `admin`.

### 38.2 Des jours ouvrés, jamais des jours civils

Sans cette précaution, tout le monde serait « en retard de deux jours » chaque
lundi matin. Sont écartés du décompte : samedis, dimanches, jours fériés
genevois — et **le jour même**, puisqu'un technicien saisit sa journée le soir.
La fenêtre est de trois semaines ; au-delà, ce n'est plus un oubli à rattraper
mais une absence dont le back office est déjà au courant.

Un technicien à jour n'apparaît pas du tout : pas de nouvelle, bonne nouvelle.

### 38.3 Ce que cela a montré tout de suite

Interrogé sur les données réelles le 7 septembre :

| Qui | Dernière saisie | Jours ouvrés manquants |
|---|---|---|
| Alen | 28 août | **5** |
| Steve | 3 septembre | 1 |
| Sami | à jour | — |

L'encart est cliquable : il ouvre le mois de l'intéressé, là où l'on peut
regarder ce qui manque.

### 38.4 Vérifications

Sur base reconstruite, avec trois techniciens fabriqués : celui qui a tout saisi
n'apparaît pas, celui qui s'est arrêté il y a trois jours ouvrés est compté à 3,
celui qui n'a jamais rien saisi est compté à 15 — le nombre exact de jours
ouvrés de la fenêtre. Technicien et fiduciaire reçoivent « Accès refusé ».

---

## 39. Les heures en plus s'expliquent au moment où l'on sait encore

Deux bouts d'un même problème, raccordés. Aucune migration : tout tient dans
l'écran et dans ce que la base sait déjà faire.

### 39.1 Le problème, mesuré

Sur août et septembre, **29 journées sur 33 dépassant l'horaire normal ne
portent aucune explication**. Depuis mars, 8 remarques pour 184 journées.

Et dans le fil des questions, la même phrase tapée à la main **trois fois en une
semaine** : « pourrais-tu me donner plus de détails sur tes heures
supplémentaires du 31 août ». La réponse de Sami — *« je me trompe de jour, je
suis allé à Chavannes-de-Bogis avec Steve le 31 août en rentrant de Pully »* —
dit à la fois d'où viennent les heures (les déplacements) et pourquoi elles ne
sont pas expliquées : il répond quatre jours plus tard, de mémoire.

### 39.2 Côté technicien : réclamé, jamais imposé

Choix de la direction, mot pour mot : *« le motif est réclamé mais il peut
l'écarter, c'est demandé uniquement lorsqu'il y a des heures supplémentaires
rajoutées ».*

- Pendant la saisie, dès que la journée dépasse la journée type et que la
  remarque est vide, une ligne apparaît sous le champ : **« ⚠ 2h00
  supplémentaires détectées, merci de les motiver dans la remarque. »** Elle
  suit la frappe et disparaît dès qu'il écrit.
- À l'enregistrement, une dernière question : *« 2h00 supplémentaires détectées,
  sans motif. Enregistrer quand même ? La journée sera signalée au back
  office. »* Il peut passer outre — un technicien pressé à 19h doit pouvoir
  enregistrer. Mais la journée part alors marquée, et cela se voit.

Pas de seuil : toute minute au-delà de la journée type déclenche la demande,
comme demandé.

### 39.3 Côté back office : la question en un bouton

Sur une journée signalée, la ligne porte désormais **« · Demander › »**. Un
appui montre le texte qui partira, puis l'envoie — rattaché au jour concerné.
La ligne devient alors *« Explication demandée · 07.09.2026 »*, pour ne pas
demander deux fois.

L'appui sur « Demander » **n'ouvre pas la journée** : la demande vit à
l'intérieur de la ligne, et sans cette coupure l'un déclencherait l'autre.

### 39.4 La réponse atterrit dans la journée, pas dans un fil

C'est le point qui fait la différence. Quand le technicien ouvre la journée
concernée, **la question du back office s'affiche juste au-dessus du champ de
remarque** — donc il répond là, et l'explication reste attachée au jour : elle
suit dans la grille, dans la revue, dans l'export Excel. Une réponse dans un fil
de discussion serait perdue trois semaines plus tard.

**Rien n'a été ajouté en base pour cela.** Une demande d'explication n'est qu'un
message rattaché à un jour — `messages.jour` existait déjà pour les questions
datées. On lit le fil déjà chargé : celui du technicien pour lui, celui du
collaborateur examiné pour le back office.

### 39.5 Vérifications

Logique pure, sur banc : six cas de calcul d'heures supplémentaires (journée
type, +30 min, +5 min, 10 heures, journée plus courte, samedi entier), tous
justes ; et la demande retrouvée dans le bon fil seulement — pas pour un autre
collaborateur, pas pour un autre jour, et **jamais confondue avec la réponse du
technicien**.

Puis dans un vrai navigateur, serveur simulé, sans toucher à la production
(`tests/motif-heures-sup.mjs`) — les neuf étapes passent : ligne signalée,
message envoyé avec le bon jour et le bon destinataire, ligne qui devient
« Explication demandée », journée qui **ne s'ouvre pas** par mégarde, question
visible sur la journée côté technicien, avertissement affiché puis disparu dès
qu'il écrit, question posée à l'enregistrement, et passage outre possible.

---

## 40. Un compte de démonstration, que le journal ne voit pas

Migration `20260907220000_compte_demonstration.sql`, appliquée en production.

### 40.1 Le problème

Ouvrir le lien d'un technicien pour vérifier un écran, c'est se faire passer
pour lui : la connexion, l'ouverture, la saisie — tout part au journal sous son
nom. On ne distingue plus ce qu'il a fait de ce qu'on a fait à sa place, et le
registre perd exactement ce qui en fait la valeur.

### 40.2 Le drapeau `demo`, et le silence dans les deux sens

Une colonne `employes.demo`. Le compte se connecte comme un technicien et a tous
ses écrans, mais **rien de ce qui le concerne n'est inscrit au journal** — ni ce
qu'il fait, ni ce qu'on fait sur lui. Sans cette seconde moitié, une question
posée à la démonstration laisserait une ligne « a écrit à Démo » au milieu des
vraies.

Le silence est posé à la source, dans `_journal`, donc pour tous les
déclencheurs qui passent par elle ; et à la main dans les trois qui écrivent en
direct — fiches, pointages, messages.

### 40.3 Tenu à l'écart de ce qui compte

| Où | La démonstration |
|---|---|
| Journal | **invisible**, dans les deux sens |
| Export comptable | ni proposée, ni fabriquée si l'on force la sélection |
| Vue de la fiduciaire | absente — employés comme pointages |
| Relevé des saisies en retard | ignorée |
| Onglet Employés (back office) | **visible**, étiquetée « démonstration », avec son lien |
| Feuilles de temps, Questions | visible : c'est là qu'on essaie |

Elle reste visible côté back office à dessein : c'est de là qu'on prend le lien,
et c'est là qu'on veut voir l'effet de ce qu'on essaie.

### 40.4 Ce que le compte porte

Trois journées de septembre, choisies pour que chaque écran ait quelque chose à
montrer : une journée normale, une journée longue **avec** explication, une
journée longue **sans** — de quoi essayer le bouton « Demander » — et le
3 septembre laissé vide, de quoi essayer « Compléter les jours manquants ».

### 40.5 Vérifications

Sur base reconstruite : le vrai technicien laisse ses traces habituelles ; la
démonstration fait exactement les mêmes gestes — connexion, saisie, message,
lecture — et le back office lui écrit, saisit pour elle et modifie sa fiche.
Résultat : **zéro ligne** au journal la nommant, de près ou de loin. Elle se
connecte bien par son lien, et voit ses propres écrans.

Puis sur la production, après création du compte : journal inchangé, aucune
ligne écrite par elle, aucune mention ; le relevé des retards ne réclame que
Alen et Steve ; la fiduciaire ne la voit pas ; le back office la voit marquée.

### 40.6 L'aperçu depuis le back office, sans se déconnecter

Le lien de démonstration est un bouton **« 👁 Ouvrir »** sur sa carte, dans
l'onglet Employés. Mais le poser là posait un problème que le lien seul n'avait
pas : ouvert dans le même navigateur, il aurait chassé la session du back
office. Deux corrections le règlent.

**La session de l'aperçu ne vit que dans son onglet.** Un compte marqué
`demo` s'installe dans `sessionStorage` — qui meurt avec l'onglet — là où les
vrais comptes s'installent dans `localStorage` et survivent à la fermeture. Se
déconnecter de l'aperçu ne vide que son propre tiroir : l'onglet d'à côté garde
sa session. Tous les accès au stockage sont enveloppés : un navigateur qui le
refuse ne doit pas empêcher l'application de s'ouvrir.

**Un lien dans l'adresse l'emporte désormais sur la session en cours.** Avant,
il était purement ignoré dès qu'une session existait — l'aperçu aurait affiché
le back office au lieu de l'écran demandé. Pour ne pas déloger quelqu'un par
mégarde, l'ouverture d'un lien **qui n'est pas l'aperçu** demande confirmation
quand une session back office est ouverte sur l'appareil. L'aperçu, lui, se
signale dans l'adresse (`&apercu=1`) et ne demande rien : il ne ferme rien.

**Vérifié dans un vrai navigateur, deux onglets ouverts**
(`tests/apercu-technicien.mjs`, serveur simulé) : le bouton ouvre l'aperçu qui
affiche bien l'écran technicien ; l'aperçu est en `sessionStorage`, le back
office reste en `localStorage` ; le back office rechargé est toujours lui-même ;
se déconnecter de l'aperçu ne lui retire rien ; le lien d'aperçu collé à la main
ne pose aucune question ; et le lien d'un **vrai** compte, lui, prévient avant
de fermer la session — refusée, on reste où l'on était.


---

## 41. Rallonger la journée sans ouvrir le sélecteur d'heure

Rallonger une journée à la main, sur un téléphone, c'est ouvrir un sélecteur
d'heure et faire défiler deux molettes. Deux appuis sur « +1 h » disent la même
chose, et c'est là que se joue la différence entre une saisie faite le soir même
et une saisie reconstruite de mémoire quatre jours plus tard.

Deux rangées de raccourcis dans la modale du jour :

| | |
|---|---|
| **Fini plus tard** | +15 min · +30 min · +1 h · −15 min |
| **Commencé plus tôt** | −15 min · −30 min · −1 h · +15 min |

Les deux sens sont offerts dans chaque rangée : on corrige un appui de trop sans
rouvrir le sélecteur.

### 41.1 Ce sur quoi ils agissent

La demi-journée qui compte, et elle seule : la fin de l'après-midi si l'on y
travaille, sinon celle du matin — et symétriquement pour le début. Une
demi-journée d'absence n'est jamais touchée, et si la journée entière est une
absence, les deux rangées disparaissent.

Un champ vide part de l'horaire type plutôt que de minuit, et rien ne déborde du
jour : on reste entre 00:00 et 23:59.

### 41.2 Vérifications

Dans un vrai navigateur, serveur simulé (`tests/raccourcis-heures.mjs`) : la
journée type à 8h00 sans avertissement ; « +1 h » → 18:00 et 9h00, avec
l'avertissement qui apparaît ; « +30 min » → 18:30 et 9h30 ; « −1 h » au début →
07:00 et 10h30 ; « −15 min » → 18:15 et 10h15 — l'avertissement suivant le total
à chaque fois. Puis l'après-midi mis en vacances : « +1 h » vise bien le matin.
Les deux demi-journées absentes : les rangées disparaissent. Et le texte exact,
à l'écran comme à l'enregistrement.

---

## 42. L'écran du technicien, refait autour d'une bande de jours

Demandé : la phrase de la carte du jour réduite au jour, mieux dire où l'on voit
les autres jours, montrer ce qui est confirmé et ce qui reste à confirmer,
polir l'interface — et si possible ne plus avoir à faire défiler.

### 42.1 Ce qui a servi de référence

Trois écrans réels plutôt qu'une intuition :

- [timespent](https://mobbin.com/screens/343de2e4-53d4-4c71-b16b-1f371cb24507) —
  une bande de jours où chacun porte sa marque : fait, pas fait.
- [Grab Driver](https://mobbin.com/screens/d44d707e-5028-49aa-827e-8462090b6a32)
  et [DoorDash Dasher](https://mobbin.com/screens/967b4dee-b5d7-4766-9876-53b33222dc0d) —
  la bande **est** la navigation : elle est visible d'emblée, on n'a rien à
  déplier pour comprendre qu'on peut aller ailleurs.
- [Fitbit](https://mobbin.com/screens/260cc0b3-2846-4d3f-ac4c-f09837a98310) —
  des lignes compactes, un chevron, rien de plus.

### 42.2 Ce que la bande remplace

La longue liste verticale des trente jours, qui obligeait à faire défiler pour
atteindre le bas de l'écran. Elle passe derrière **« Voir le détail du mois »**,
repliée par défaut, et la bande prend sa place : tout le mois sur une ligne, un
dégradé aux deux bords pour dire qu'elle se poursuit, et le jour choisi ramené
sous les yeux tout seul.

Un point sous chaque jour, et une légende de trois mots en dessous :

| Marque | Sens |
|---|---|
| ● vert | confirmé (ou validé par le back office) |
| ● orange | posé, **à confirmer** par le technicien |
| ○ cerclé | **à compléter** — rien de saisi |
| *(rien)* | week-end, jour férié, jour à venir |

### 42.3 La carte du jour ne parle plus que du jour

    Lundi 7 septembre                    [À enregistrer]
    Horaire normal : 08:00–12:00 · 13:00–17:00
    [ Enregistrer l'horaire normal ]
    Corriger l'horaire ou signaler une absence

Le reste de la phrase — « horaire différent ou absence ? Touchez le jour dans la
liste » — est devenu le lien du bas : ce qu'on peut faire n'a plus à s'expliquer,
il se touche.

Et la carte suit **le jour choisi dans la bande**, plus seulement aujourd'hui :
un technicien qui rattrape trois journées le vendredi soir enregistre chacune
d'un appui, au lieu d'ouvrir trois fois la fenêtre de saisie.

Sept états, sept phrases : *Validée · Confirmée · À confirmer · À compléter ·
À enregistrer · Jour férié · Week-end · À venir*. « À enregistrer » distingue
la journée du jour, qui court encore, de celle d'hier qu'on a oubliée.

### 42.4 Les questions ne prennent la place qu'une fois ouvertes

Repliées, elles tiennent en une ligne. Un message non lu ouvre la carte de
lui-même — il ne doit pas se cacher derrière un repli — et le marquage « lu »
observe désormais le fil, pas la carte : une carte repliée peut être à l'écran
sans qu'on ait rien lu.

### 42.5 Vérifications

Dans un vrai navigateur, au format d'un téléphone (390 × 844), serveur simulé
(`tests/ecran-technicien.mjs`) :

- **hauteur de page 844 pour une fenêtre de 844 — aucun défilement** ;
- le jour du jour est choisi d'office et la bande s'y positionne ;
- appuyer sur une journée posée → « À confirmer » et le bouton *Confirmer cette
  journée · 07:00–12:00 · 13:00–18:00 · 10h00* ;
- appuyer sur une journée vide du passé → « À compléter » et *Enregistrer
  l'horaire normal* ;
- appuyer sur un dimanche → « Week-end », aucun bouton ;
- le détail du mois, déplié, rend bien ses trente lignes.

Un message non lu ouvre la carte des questions ; la page défile alors de 237 px,
ce qui est le prix d'un message à lire.


---

## 43. La couleur qui dit juste, et une hiérarchie qui se voit

Deux reproches, tous deux fondés.

### 43.1 « Confirmé, tu mets vert — pourquoi je vois une autre couleur ? »

Parce que le point portait `--bleu`, le vert de marque **#01a76b**, qui tire sur
le bleu-vert : sur huit pixels, il ne se lit pas comme du vert. Pire, la
pastille du jour **choisi** repeignait son point en blanc — un jour confirmé
perdait sa couleur au moment même où on le regardait.

Trois couleurs, désormais, qu'on ne confond pas :

| État | Couleur | Sur la pastille sombre |
|---|---|---|
| confirmé | vert franc `#16a34a` | vert clair `#4ade80` |
| à confirmer | ambre `#f59e0b` | ambre clair `#fbbf24` |
| à compléter | gris `#94a3b8` | gris clair |

Le gris est celui demandé : un jour vide n'est pas une alarme, c'est un vide.
L'urgence est dite en toutes lettres dans le résumé du mois.

### 43.2 « Je ne vois pas tes améliorations en UI/UX »

Reproche mérité. Le premier passage était **structurel** — une bande de jours à
la place d'une liste — mais visuellement, l'écran restait trois cartes de même
poids, tout en gras, sur le même fond. Trois choses qui se disputent l'attention,
c'est aucune chose qu'on regarde.

Ce que les références montraient et que je n'avais pas pris :
[The Outsiders](https://mobbin.com/screens/7a8b4054-0cfa-4a24-8b38-fe6c351105ba)
et [Starling](https://mobbin.com/screens/e4ec49d3-8ef9-4463-be4a-f2e542a8df82)
posent **un** chiffre énorme et font taire le reste ;
[Wispr Flow](https://mobbin.com/screens/3e1fc6f0-7d95-4408-af57-210e0a400d55)
teinte la seule carte qui compte et laisse les autres blanches.

Quatre changements, dans cet ordre d'importance :

**Un héros, un seul.** La carte du jour porte les heures en 40 px, l'excédent en
vert à côté, et se teinte de son état — vert quand c'est fait, ambre quand il
reste un geste. C'est la seule couleur de fond de l'écran.

**Le reste se tait.** Les autres cartes perdent leur ombre pour un filet gris.
Le résumé du mois n'est plus une boîte jaune qui rivalise avec le héros, mais une
ligne : `⚠ 1 jour à compléter · +2h30 sup · [Tout compléter]`.

**Le bas devient un relevé** — le motif exact de la capture d'écran transmise :
un point d'état, la date, l'amplitude de la journée, le total, un chevron. Il
remplit l'espace vide par de l'information plutôt que par du blanc, et répond à
la question qu'on se pose en ouvrant l'application : *qu'ai-je fait cette
semaine ?*

**Deux lignes au lieu de deux boutons.** « Détail du mois » et « Questions »
deviennent deux lignes d'une même carte, avec chevron. Le pointillé du premier
faisait brouillon.

### 43.3 Vérifications

Au format téléphone, serveur simulé : **hauteur de page 844 pour une fenêtre de
844 — toujours aucun défilement**, malgré la liste ajoutée. Journée confirmée →
carte verte, chiffre `10h00 +2h00 sup`, pastille CONFIRMÉE. Journée du jour non
saisie → carte ambre, bouton d'enregistrement. Et les couleurs des points
relevées une à une dans le navigateur : vert `rgb(22,163,74)` pour les journées
confirmées, gris `rgb(148,163,184)` pour celle qui manque.

Les quatre suites d'essais passent.

---

## 44. Ce que le technicien a envoyé, et ce qui reste à approuver

Le mot manquait. L'écran disait « Confirmée » pour une journée que le technicien
venait d'envoyer et « Validée » pour une journée que le back office avait
approuvée — deux mots proches, **la même couleur verte**, et donc aucun moyen de
savoir ce qui restait en attente.

### 44.1 Quatre états, dans l'ordre où il les vit

| Ce qu'il voit | Le point | Ce que ça veut dire |
|---|---|---|
| **À saisir** | gris plein | rien n'est enregistré |
| **À confirmer** | ambre plein | le back office a posé la journée : à vérifier, puis confirmer |
| **À approuver** | **cerclé de vert** | il l'a envoyée ; le back office ne l'a pas encore approuvée |
| **Approuvée** | vert plein | c'est fini, la journée ne bouge plus |

Le cercle vert est le signe qui manquait : parti, mais pas encore arrivé. Un
plein et un cerclé se distinguent à huit pixels, deux verts non.

### 44.2 Et la couleur ne suffit pas

Sous le chiffre, une phrase dit l'état en toutes lettres — un point de couleur
se devine, une phrase se lit :

- *« Envoyée. Le back office ne l'a pas encore approuvée. »*
- *« Approuvée par le back office — elle ne bouge plus. »*
- *« Posée par le back office : vérifiez l'horaire, puis confirmez-le. »*

Le résumé du mois compte lui aussi : **« 2 journées envoyées, en attente
d'approbation »**, et « ✓ Tout est approuvé » quand il n'en reste plus. La
modale de saisie parle la même langue : « Approuvé par le back office —
modification impossible ».

Un seul mot par chose, partout : *à saisir* remplace « à compléter »,
*approuvé* remplace « validé ».

### 44.3 Retiré

« Posez votre question sur septembre 2026 — le back office vous répondra ici. »
Le champ de saisie porte déjà son invite ; la phrase ne disait rien de plus.

### 44.4 Vérifications

La phrase d'état coûtait 78 px : trois lignes de relevé au lieu de quatre, un peu
d'air retiré là où il ne manque à personne, et la marge basse de la vue ramenée
de 60 à 26 px — **hauteur 844 pour une fenêtre de 844, toujours aucun
défilement**, y compris avec la phrase affichée.

Les quatre états rendus et relevés un à un (`tests/etats-journee.mjs`), et les
six suites d'essais passent.
