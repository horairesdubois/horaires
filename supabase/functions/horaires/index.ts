// Sert l'application Horaires. Le HTML vit dans la table `pages` (nom = 'app'),
// mis à jour via scripts/publier_page.py — pas besoin de redéployer cette fonction.
const URL = Deno.env.get("SUPABASE_URL") ?? "";
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

let cache = { html: "", quand: 0 };

async function pageHtml(): Promise<string> {
  const now = Date.now();
  if (cache.html && now - cache.quand < 60_000) return cache.html;
  try {
    const r = await fetch(`${URL}/rest/v1/pages?nom=eq.app&select=html`, {
      headers: { apikey: KEY, Authorization: `Bearer ${KEY}` },
    });
    if (r.ok) {
      const rows = await r.json();
      const html = rows?.[0]?.html ?? "";
      if (html) cache = { html, quand: now };
    }
  } catch (_e) { /* on garde le cache existant */ }
  return cache.html;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Méthode non autorisée", { status: 405 });
  }
  const html = await pageHtml();
  if (!html) return new Response("Application momentanément indisponible", { status: 503 });
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
});
