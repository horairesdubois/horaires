# Ce qui a été écrit, puis écarté

Ce dossier n'est **pas** rejoué. Rien de ce qu'il contient n'est en base, et
rien ne doit y arriver par inadvertance : c'est la raison d'être du dossier.

Un fichier reste ici plutôt que d'être supprimé quand la décision peut se
retourner un jour. Le code est écrit et testé ; seule la décision manque.

---

## `20260828090000_preremplissage_veille.sql` — pré-remplissage de la veille

**Écarté le 7 septembre 2026, sur décision de la direction.**

> « Non, ne pré-remplis pas les journées de 8h. Laisse le bouton où il suffit
> qu'ils cliquent dessus pour pré-remplir 8h. »

Ce que la migration faisait : une tâche de 9h00 posait la journée type sur
chaque jour ouvré non saisi de la veille, marquée `prerempli`, à charge pour le
technicien de la confirmer.

Ce qui la remplace, et qui existe déjà : le bouton **« ✓ Compléter les N jours
manquants avec l'horaire normal »**, sur l'écran du technicien. Même horaire,
même effet — mais c'est lui qui appuie. Personne n'atteste à sa place.

**Ne pas la déplacer dans `migrations/` sans le dire.** Elle installe
`generer_pointages_manquants()`, que `relancer_saisies()` (elle, en base)
appelle si elle la trouve. La reposer suffirait donc à remettre le
pré-remplissage en service — silencieusement, à la première tâche planifiée.

`preremplissage.sql` est son scénario de test, gardé avec elle.
