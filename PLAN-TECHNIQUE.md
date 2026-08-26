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
