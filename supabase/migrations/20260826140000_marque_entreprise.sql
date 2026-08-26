-- Identité visuelle de l'entreprise : logo et couleur de marque.
--
-- Les collaborateurs doivent reconnaître l'outil de leur employeur, pas une
-- application anonyme. Le logo est stocké en base comme les bulletins de
-- salaire : l'application n'utilise pas Supabase Auth, et les règles d'accès
-- de Storage ne sauraient pas identifier nos utilisateurs.
--
-- Il est servi par une fonction dédiée plutôt que glissé dans admin_donnees :
-- la grille de la direction se rafraîchit toutes les minutes, et retransmettre
-- une image à chaque cycle serait du gaspillage. L'interface la demande une
-- seule fois par ouverture.
--
-- L'écran de connexion reste neutre. Avec les liens personnels, personne ne le
-- voit jamais, et cette page est publique : la marque n'a pas à y figurer.

create table if not exists public.marque (
  id int primary key default 1 check (id = 1),
  logo bytea,
  logo_type text,
  couleur text,
  maj timestamptz not null default now()
);
alter table public.marque enable row level security;
revoke all on public.marque from anon, authenticated;
insert into public.marque (id) values (1) on conflict (id) do nothing;

create or replace function public.marque_lire(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_m public.marque; v_nom text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  select * into v_m from public.marque where id = 1;
  select valeur into v_nom from public.parametres where cle = 'entreprise';
  return jsonb_build_object('ok', true,
    'entreprise', coalesce(v_nom, ''),
    'couleur', v_m.couleur,
    'logo', case when v_m.logo is null then null
                 else 'data:' || v_m.logo_type || ';base64,' || encode(v_m.logo, 'base64') end);
end $$;
revoke execute on function public.marque_lire(uuid) from public, authenticated;
grant execute on function public.marque_lire(uuid) to anon;

create or replace function public.admin_marque(
  p_token uuid, p_base64 text, p_type text, p_couleur text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_bin bytea; v_type text; v_coul text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;

  v_coul := nullif(trim(coalesce(p_couleur, '')), '');
  if v_coul is not null and v_coul !~ '^#[0-9a-fA-F]{6}$' then
    return jsonb_build_object('ok', false, 'erreur', 'Couleur invalide (format #rrggbb)');
  end if;

  if p_base64 is not null and p_base64 <> '' then
    v_type := lower(nullif(trim(coalesce(p_type, '')), ''));
    if v_type not in ('image/png', 'image/jpeg', 'image/webp', 'image/svg+xml') then
      return jsonb_build_object('ok', false, 'erreur', 'Format accepté : PNG, JPEG, WebP ou SVG');
    end if;
    begin
      v_bin := decode(p_base64, 'base64');
    exception when others then
      return jsonb_build_object('ok', false, 'erreur', 'Fichier illisible');
    end;
    if length(v_bin) > 512000 then
      return jsonb_build_object('ok', false, 'erreur', 'Logo trop lourd (500 Ko maximum)');
    end if;
    -- Le type annoncé doit correspondre au contenu réel : on ne se fie ni à
    -- l'extension, ni à ce que déclare le navigateur.
    if v_type = 'image/png'  and substring(v_bin from 1 for 8) <> '\x89504e470d0a1a0a'::bytea then
      return jsonb_build_object('ok', false, 'erreur', 'Ce fichier n''est pas un PNG');
    end if;
    if v_type = 'image/jpeg' and substring(v_bin from 1 for 3) <> '\xffd8ff'::bytea then
      return jsonb_build_object('ok', false, 'erreur', 'Ce fichier n''est pas un JPEG');
    end if;
    if v_type = 'image/webp' and (substring(v_bin from 1 for 4) <> '\x52494646'::bytea
                                or substring(v_bin from 9 for 4) <> '\x57454250'::bytea) then
      return jsonb_build_object('ok', false, 'erreur', 'Ce fichier n''est pas un WebP');
    end if;
    if v_type = 'image/svg+xml' and position('<svg' in lower(convert_from(substring(v_bin from 1 for 2048), 'UTF8'))) = 0 then
      return jsonb_build_object('ok', false, 'erreur', 'Ce fichier n''est pas un SVG');
    end if;
    update public.marque set logo = v_bin, logo_type = v_type, maj = now() where id = 1;
  end if;

  if v_coul is not null then
    update public.marque set couleur = v_coul, maj = now() where id = 1;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_marque(uuid, text, text, text) from public, authenticated;
grant execute on function public.admin_marque(uuid, text, text, text) to anon;

create or replace function public.admin_marque_effacer(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  update public.marque set logo = null, logo_type = null, maj = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_marque_effacer(uuid) from public, authenticated;
grant execute on function public.admin_marque_effacer(uuid) to anon;
