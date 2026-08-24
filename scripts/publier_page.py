#!/usr/bin/env python3
"""Publie app/index.html vers la table `pages` de Supabase.

Usage :
  DEPLOY_SECRET=... python3 scripts/publier_page.py
Le secret est stocké dans la table `parametres` (clé deploy_secret),
visible dans le tableau de bord Supabase.
"""
import json, os, sys, urllib.request

URL = "https://ijfkttmezryvbjsuysbl.supabase.co"
ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlqZmt0dG1lenJ5dmJqc3V5c2JsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc1NTQ1MTQsImV4cCI6MjEwMzEzMDUxNH0.5g98kpzqLyXtRZT1TObi2LwiRwNltobk1OIPTeBDWpg"

secret = os.environ.get("DEPLOY_SECRET")
if not secret:
    sys.exit("Définissez DEPLOY_SECRET (voir table parametres dans Supabase)")

html = open(os.path.join(os.path.dirname(__file__), "..", "app", "index.html"), encoding="utf-8").read()
html = html.replace("__SUPABASE_URL__", URL).replace("__ANON_KEY__", ANON)

req = urllib.request.Request(
    URL + "/rest/v1/rpc/_maj_page",
    data=json.dumps({"p_secret": secret, "p_nom": "app", "p_html": html}).encode(),
    headers={"Content-Type": "application/json", "apikey": ANON, "Authorization": "Bearer " + ANON},
)
with urllib.request.urlopen(req) as r:
    print(r.status, r.read().decode())
