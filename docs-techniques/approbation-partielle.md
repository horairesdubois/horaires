# Approbation partielle des journées

La saisie originale reste intacte. `approuve` signifie que le contrôle est terminé ;
`minutes_refusees` précise la part refusée, et `motif_refus` est facultatif.
La durée approuvée est la durée saisie moins la durée refusée. Un refus total
est possible ; les absences ne sont pas transformées en heures travaillées.

## Garanties

- RPC `admin_decider_heures` réservée au back office et authentifiée via `_auth`.
- Verrou transactionnel partagé avec les autres écritures de pointages.
- Version de la journée contrôlée avant décision pour empêcher une fenêtre
  périmée de remplacer un contrôle concurrent.
- Les heures approuvées restent verrouillées pour l’employé, y compris en cas
  de refus partiel ou total. La demande de réouverture suit le circuit existant.
- Un changement des plages horaires ou des types d’absence déjà approuvés
  retire le contrôle actif et impose une nouvelle confirmation de l’employé.
- Réouverture : la décision active est effacée, mais son historique reste au journal.
- L’approbation du mois conserve les refus des journées déjà contrôlées.
- RLS, absence de grants directs et accès réservé au journal conservés.

## Export

Le récapitulatif possède deux colonnes supplémentaires : heures approuvées et
heures refusées. L’onglet « Décisions sur les heures » donne le détail par jour
et les motifs. Les calculs historiques d’horaires et de majorations restent
calculés sur la saisie originale : refuser une durée ne permet pas de déduire
arbitrairement quel créneau ou quelle majoration a été refusé. L’export les
identifie explicitement comme heures saisies et distingue le contrôle.

## Vérification locale

- `supabase/tests/approbation_partielle.sql` : montants, rôles, motif facultatif,
  refus total, conflit de version, conservation de la saisie, lot, réouverture,
  correction et journal ; transaction annulée, comptes synthétiques.
- `supabase/tests/verrouillage_confirmation.sql` : non-régression du cycle existant.
- `tests/circuit-approbation.mjs` : refus partiel et visibilité employé, verrouillage,
  motif échappé contre l’injection HTML, en plus des scénarios précédents.
- `tests/calculs-decisions.mjs` : totaux et export distincts, refus total, échappement.
- `node scripts/apercu-refus.mjs` construit un aperçu sans aucun accès réseau,
  dans `work/apercu-refus`. Servir ce dossier en local puis ouvrir
  `?role=admin`, `?role=employe` ou `?role=compta`. Les décisions sont fictives
  et conservées uniquement dans le localStorage de cet aperçu.

## Publication

1. Appliquer `20260915120000_approbation_partielle.sql` à la base horaires.
   Migration compatible avec l’ancienne interface. Ne pas toucher à la base GPS.
2. Générer `docs/index.html` avec `python3 scripts/publier_page.py`.
3. Suivre la procédure de publication des branches décrite dans AGENTS.md.
4. Vérifier la version servie et le circuit avec des comptes synthétiques en transaction annulée.

L’aperçu local et les tests ne constituent pas une publication de la version
utilisée par les employés. Sans migration, le nouveau contrôle affiche une
explication et n’effectue pas une fausse approbation.

Migration appliquée le 15 septembre 2026 après autorisation du propriétaire.
Les 201 journées dont 88 approuvées ont la même empreinte avant et après.
Le scénario SQL synthétique a réussi en production et a été annulé intégralement.
La migration vérifie aussi cette conservation dans sa propre transaction.
