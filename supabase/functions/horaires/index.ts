// Supabase neutralise le rendu HTML sur *.supabase.co (anti-hameçonnage) :
// l'application est donc hébergée sur GitHub Pages. Cette fonction ne sert
// plus qu'à rediriger l'ancienne adresse vers la nouvelle.
const CIBLE = "https://oneadrien.github.io/horaires/";

Deno.serve((_req: Request) => {
  return new Response(null, {
    status: 302,
    headers: { location: CIBLE, "cache-control": "no-store" },
  });
});
