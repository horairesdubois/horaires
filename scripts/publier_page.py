#!/usr/bin/env python3
"""Construit docs/index.html (servi par GitHub Pages) depuis app/index.html.

Usage : python3 scripts/publier_page.py  puis  git add docs && git commit && git push
GitHub Pages republie automatiquement après le push.
"""
import os

URL = "https://ijfkttmezryvbjsuysbl.supabase.co"
ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlqZmt0dG1lenJ5dmJqc3V5c2JsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc1NTQ1MTQsImV4cCI6MjEwMzEzMDUxNH0.5g98kpzqLyXtRZT1TObi2LwiRwNltobk1OIPTeBDWpg"

racine = os.path.join(os.path.dirname(__file__), "..")
html = open(os.path.join(racine, "app", "index.html"), encoding="utf-8").read()
html = html.replace("__SUPABASE_URL__", URL).replace("__ANON_KEY__", ANON)
os.makedirs(os.path.join(racine, "docs"), exist_ok=True)
open(os.path.join(racine, "docs", "index.html"), "w", encoding="utf-8").write(html)
print("docs/index.html reconstruit —", len(html), "octets. Committez et poussez pour publier.")
