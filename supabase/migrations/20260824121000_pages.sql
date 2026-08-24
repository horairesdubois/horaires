-- Stockage de la page HTML servie par la fonction Edge "horaires".
-- Mise à jour via la fonction _maj_page, protégée par un secret de déploiement
-- stocké dans parametres (clé 'deploy_secret'). Le secret n'est pas dans le
-- dépôt : il est inséré à la main (tableau de bord Supabase → SQL Editor) :
--   insert into parametres (cle, valeur) values ('deploy_secret', '<secret>')
--   on conflict (cle) do update set valeur = excluded.valeur;

create table public.pages (
  nom text primary key,
  html text not null,
  maj timestamptz not null default now()
);
alter table public.pages enable row level security;
revoke all on public.pages from anon, authenticated;

create or replace function public._maj_page(p_secret text, p_nom text, p_html text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_secret text;
begin
  select valeur into v_secret from public.parametres where cle = 'deploy_secret';
  if v_secret is null or v_secret = '' or p_secret is distinct from v_secret then
    return jsonb_build_object('ok', false, 'erreur', 'secret');
  end if;
  if p_nom is null or p_nom !~ '^[a-z_]{1,40}$' or p_html is null or length(p_html) > 2000000 then
    return jsonb_build_object('ok', false, 'erreur', 'invalide');
  end if;
  insert into public.pages (nom, html) values (p_nom, p_html)
  on conflict (nom) do update set html = excluded.html, maj = now();
  return jsonb_build_object('ok', true, 'taille', length(p_html));
end $$;

revoke execute on function public._maj_page(text, text, text) from public, authenticated;
grant execute on function public._maj_page(text, text, text) to anon;
