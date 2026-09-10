# ⏱️ Horaires

Feuilles de temps d'une entreprise de dépannage genevoise : les techniciens
saisissent leurs journées depuis leur téléphone, le back office les valide, la
fiduciaire exporte.

**En production** → <https://horairesdubois.github.io/horaires/>

## Où sont les choses

| Chemin | Rôle |
|---|---|
| `app/index.html` | la source de l'application — un seul fichier, sans dépendance |
| `docs/index.html` | le fichier servi par GitHub Pages (produit, ne pas éditer) |
| `scripts/publier_page.py` | produit `docs/` depuis `app/` |
| `supabase/migrations/` | le schéma et les fonctions SQL |
| `tests/` | essais d'écran Playwright |
| `PLAN-TECHNIQUE.md` | le journal de bord : chaque décision et son pourquoi |

## Démarrer

```bash
npm install          # playwright
npm run navigateur   # télécharge Chromium (ou exporte CHROMIUM_PATH)
npm test             # les 12 essais d'écran
npm run build        # app/index.html -> docs/index.html
```

## Avant de contribuer

👉 **Lis [`AGENTS.md`](AGENTS.md).** Il contient la procédure de publication en
deux branches, les invariants de sécurité à ne jamais casser, et les pièges déjà
rencontrés. Plusieurs de ces règles ne se devinent pas depuis les fichiers.
