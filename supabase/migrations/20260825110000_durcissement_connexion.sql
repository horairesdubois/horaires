-- Durcissement de la connexion, maintenant que des bulletins de salaire sont
-- accessibles derrière l'authentification.
--
-- Constat. La clé « anon » est publique par conception : n'importe qui sur
-- Internet peut appeler connexion(p_pin). Or cette fonction compare le code
-- fourni à TOUS les comptes : l'attaquant ne vise personne en particulier,
-- n'importe quel PIN valide lui ouvre une porte. Avec quatre comptes à quatre
-- chiffres et un plafond de 200 essais/minute, l'espérance de réussite était
-- d'environ six minutes d'attaque soutenue.
--
-- Trois corrections :
--
-- 1. Compteurs séparés par type de tentative. Le compteur était commun au PIN
--    et au lien personnel : une attaque sur les PIN saturait le plafond global
--    et empêchait aussi les connexions légitimes par lien (déni de service).
--
-- 2. Plafond très strict sur le PIN (3/minute/IP, 10/minute au total). Le PIN
--    n'est plus qu'un secours — tout le monde se connecte par lien — donc un
--    plafond bas ne gêne personne, alors qu'il multiplie par vingt le temps
--    d'une attaque. Le lien conserve ses plafonds larges : 128 bits de clé
--    sont hors de portée d'une force brute, quel que soit le débit.
--
-- 3. Longueur minimale portée à six chiffres pour tout PIN créé ou modifié.
--    Les PIN existants continuent de fonctionner ; ils sont à renouveler.

alter table public.tentatives add column if not exists genre text not null default 'pin';
create index if not exists tentatives_genre_idx on public.tentatives (genre, quand);

-- Garde-fou commun aux deux voies d'entrée, paramétré par type.
create or replace function public._limiter(p_genre text, p_max_ip int, p_max_total int)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare v_ip text; v_ip_n int; v_tot int;
begin
  v_ip := coalesce((current_setting('request.headers', true))::json->>'x-forwarded-for', '');
  insert into public.tentatives (ip, genre) values (v_ip, p_genre);
  delete from public.tentatives where quand < now() - interval '1 day';
  select count(*) into v_ip_n from public.tentatives
   where genre = p_genre and quand > now() - interval '1 minute' and ip = v_ip;
  select count(*) into v_tot from public.tentatives
   where genre = p_genre and quand > now() - interval '1 minute';
  return v_ip_n > p_max_ip or v_tot > p_max_total;   -- true = à bloquer
end $$;
revoke execute on function public._limiter(text, int, int) from anon, authenticated, public;

create or replace function public.connexion(p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_token uuid;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,10}$' then
    return jsonb_build_object('ok', false, 'erreur', 'Le code PIN doit comporter 4 à 10 chiffres');
  end if;
  if public._limiter('pin', 3, 10) then
    return jsonb_build_object('ok', false, 'erreur', 'Trop de tentatives. Réessayez dans une minute.');
  end if;
  select e.* into v_emp from public.employes e
   where e.actif and e.pin_hash = extensions.crypt(p_pin, e.pin_hash)
   limit 1;
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Code PIN incorrect');
  end if;
  delete from public.sessions where expire_le < now();
  insert into public.sessions (employe_id) values (v_emp.id) returning token into v_token;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $$;

create or replace function public.connexion_cle(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_token uuid;
begin
  if p_cle is null or p_cle !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('ok', false, 'erreur', 'Lien invalide');
  end if;
  if public._limiter('lien', 20, 200) then
    return jsonb_build_object('ok', false, 'erreur', 'Trop de tentatives. Réessayez dans une minute.');
  end if;
  select e.* into v_emp from public.employes e
   where e.actif and e.cle_acces = p_cle limit 1;
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Lien invalide ou désactivé');
  end if;
  delete from public.sessions where expire_le < now();
  insert into public.sessions (employe_id) values (v_emp.id) returning token into v_token;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $$;

-- Tout nouveau code PIN fait au minimum six chiffres.
create or replace function public._pin_valide(p_pin text) returns boolean
language sql immutable set search_path = public
as $$ select p_pin ~ '^[0-9]{6,10}$' $$;

-- Ménage : la table pages et sa fonction de mise à jour servaient l'ancienne
-- fonction Edge, remplacée depuis par GitHub Pages. Du code mort exposé à anon.
drop function if exists public._maj_page(text, text, text);
drop table if exists public.pages;

-- Ces deux fonctions avaient conservé un droit d'exécution pour PUBLIC hérité
-- de leur création. Le contrôle de jeton les protège déjà, mais autant s'en tenir
-- au strict nécessaire.
revoke execute on function public.admin_employe(uuid, uuid, text, text, text, boolean, text, text, text, text, text, text, text) from public;
revoke execute on function public.compta_donnees(uuid, integer, integer) from public;

-- Longueur minimale des PIN portée à six chiffres à la création et au changement.
-- (Les PIN existants continuent de fonctionner à la connexion : ils sont à renouveler.)
create or replace function public.admin_employe(
  p_token uuid, p_id uuid, p_prenom text, p_nom text, p_metier text, p_actif boolean,
  p_md text, p_mf text, p_ad text, p_af text, p_pin text,
  p_cct text default null, p_role text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_id uuid;
  v_md time; v_mf time; v_ad time; v_af time; v_cct text; v_role text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if coalesce(trim(p_prenom), '') = '' then
    return jsonb_build_object('ok', false, 'erreur', 'Le prénom est obligatoire');
  end if;
  if p_id is not null and p_id = v_emp.id and not coalesce(p_actif, true) then
    return jsonb_build_object('ok', false, 'erreur', 'Impossible de désactiver votre propre compte');
  end if;
  v_cct := nullif(trim(coalesce(p_cct, '')), '');
  if v_cct is not null and v_cct not in ('ferblanterie', 'chauffage', 'vitrerie') then
    return jsonb_build_object('ok', false, 'erreur', 'Branche CCT inconnue');
  end if;
  v_role := nullif(trim(coalesce(p_role, '')), '');
  if v_role is not null and v_role not in ('employe', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'Rôle inconnu');
  end if;
  if p_id is not null and v_role is not null
     and exists (select 1 from public.employes e where e.id = p_id and e.role = 'admin') then
    v_role := null;
  end if;
  begin
    v_md := coalesce(nullif(trim(coalesce(p_md, '')), '')::time, time '08:00');
    v_mf := coalesce(nullif(trim(coalesce(p_mf, '')), '')::time, time '12:00');
    v_ad := coalesce(nullif(trim(coalesce(p_ad, '')), '')::time, time '13:00');
    v_af := coalesce(nullif(trim(coalesce(p_af, '')), '')::time, time '17:00');
  exception when others then
    return jsonb_build_object('ok', false, 'erreur', 'Heure invalide dans la journée type');
  end;
  if p_pin is not null and p_pin <> '' then
    if p_pin !~ '^[0-9]{6,10}$' then
      return jsonb_build_object('ok', false, 'erreur', 'Le code PIN doit comporter 6 à 10 chiffres');
    end if;
    if exists (select 1 from public.employes e
                where (p_id is null or e.id <> p_id)
                  and e.pin_hash = extensions.crypt(p_pin, e.pin_hash)) then
      return jsonb_build_object('ok', false, 'erreur', 'Ce code PIN est déjà utilisé par quelqu''un d''autre');
    end if;
  end if;
  if p_id is null then
    if p_pin is null or p_pin = '' then
      return jsonb_build_object('ok', false, 'erreur', 'Un code PIN est obligatoire pour un nouvel employé');
    end if;
    insert into public.employes (prenom, nom, metier, actif, matin_debut_def, matin_fin_def,
                                 apm_debut_def, apm_fin_def, pin_hash, cle_acces, cct, role)
    values (trim(p_prenom), coalesce(trim(p_nom), ''), coalesce(trim(p_metier), ''), coalesce(p_actif, true),
            v_md, v_mf, v_ad, v_af, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)),
            encode(extensions.gen_random_bytes(16), 'hex'),
            coalesce(v_cct, 'ferblanterie'), coalesce(v_role, 'employe'))
    returning id into v_id;
  else
    update public.employes set
      prenom = trim(p_prenom), nom = coalesce(trim(p_nom), ''), metier = coalesce(trim(p_metier), ''),
      actif = coalesce(p_actif, true),
      matin_debut_def = v_md, matin_fin_def = v_mf, apm_debut_def = v_ad, apm_fin_def = v_af,
      cct = coalesce(v_cct, cct),
      role = coalesce(v_role, role),
      pin_hash = case when p_pin is not null and p_pin <> ''
                      then extensions.crypt(p_pin, extensions.gen_salt('bf', 8))
                      else pin_hash end
    where id = p_id returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'erreur', 'Employé introuvable');
    end if;
    if not coalesce(p_actif, true) then
      delete from public.sessions where employe_id = p_id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke execute on function public.admin_employe(uuid, uuid, text, text, text, boolean, text, text, text, text, text, text, text) from public, authenticated;
grant execute on function public.admin_employe(uuid, uuid, text, text, text, boolean, text, text, text, text, text, text, text) to anon;
