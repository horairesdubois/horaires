-- Horaires — schéma initial
-- Toutes les tables sont protégées par RLS sans policy (aucun accès direct).
-- L'application passe exclusivement par les fonctions RPC ci-dessous,
-- authentifiées par code PIN puis par jeton de session.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables

create table public.parametres (
  cle text primary key,
  valeur text not null default ''
);

create table public.employes (
  id uuid primary key default gen_random_uuid(),
  prenom text not null,
  nom text not null default '',
  metier text not null default '',
  pin_hash text not null,
  role text not null default 'employe' check (role in ('employe','admin')),
  actif boolean not null default true,
  matin_debut_def time not null default '07:30',
  matin_fin_def time not null default '12:00',
  apm_debut_def time not null default '13:00',
  apm_fin_def time not null default '17:00',
  cree_le timestamptz not null default now()
);

create table public.pointages (
  id uuid primary key default gen_random_uuid(),
  employe_id uuid not null references public.employes(id) on delete cascade,
  jour date not null,
  matin_type text not null default 'travail'
    check (matin_type in ('travail','vacances','maladie','accident','ferie','armee','ecole','autre')),
  matin_debut time,
  matin_fin time,
  apm_type text not null default 'travail'
    check (apm_type in ('travail','vacances','maladie','accident','ferie','armee','ecole','autre')),
  apm_debut time,
  apm_fin time,
  remarque text not null default '',
  approuve boolean not null default false,
  approuve_le timestamptz,
  approuve_par uuid references public.employes(id),
  modifie_le timestamptz not null default now(),
  unique (employe_id, jour)
);
create index pointages_jour_idx on public.pointages (jour);

create table public.sessions (
  token uuid primary key default gen_random_uuid(),
  employe_id uuid not null references public.employes(id) on delete cascade,
  cree_le timestamptz not null default now(),
  expire_le timestamptz not null default now() + interval '90 days'
);
create index sessions_employe_idx on public.sessions (employe_id);

create table public.tentatives (
  id bigint generated always as identity primary key,
  quand timestamptz not null default now()
);

alter table public.parametres enable row level security;
alter table public.employes enable row level security;
alter table public.pointages enable row level security;
alter table public.sessions enable row level security;
alter table public.tentatives enable row level security;

revoke all on all tables in schema public from anon, authenticated;

-- ---------------------------------------------------------------- helpers internes

create or replace function public._auth(p_token uuid)
returns public.employes
language sql stable security definer set search_path = public, extensions
as $$
  select e.* from public.sessions s
  join public.employes e on e.id = s.employe_id
  where s.token = p_token and s.expire_le > now() and e.actif
$$;

create or replace function public._emp_json(e public.employes)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'id', e.id, 'prenom', e.prenom, 'nom', e.nom, 'metier', e.metier,
    'role', e.role, 'actif', e.actif,
    'matin_debut_def', to_char(e.matin_debut_def, 'HH24:MI'),
    'matin_fin_def',   to_char(e.matin_fin_def, 'HH24:MI'),
    'apm_debut_def',   to_char(e.apm_debut_def, 'HH24:MI'),
    'apm_fin_def',     to_char(e.apm_fin_def, 'HH24:MI'))
$$;

create or replace function public._ptg_json(p public.pointages)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'employe_id', p.employe_id,
    'jour', to_char(p.jour, 'YYYY-MM-DD'),
    'matin_type', p.matin_type,
    'matin_debut', to_char(p.matin_debut, 'HH24:MI'),
    'matin_fin',   to_char(p.matin_fin, 'HH24:MI'),
    'apm_type', p.apm_type,
    'apm_debut', to_char(p.apm_debut, 'HH24:MI'),
    'apm_fin',   to_char(p.apm_fin, 'HH24:MI'),
    'remarque', p.remarque,
    'approuve', p.approuve,
    'approuve_le', to_char(p.approuve_le, 'DD.MM.YYYY'))
$$;

-- Validation + enregistrement d'un jour (utilisé par employé et admin).
-- p_admin = true : la direction peut modifier même un jour déjà validé.
create or replace function public._save_jour(
  p_employe uuid, p_jour date,
  p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text,
  p_remarque text, p_admin boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_md time; v_mf time; v_ad time; v_af time;
  v_mt text; v_at text; v_rem text;
begin
  if p_jour is null or p_jour < date '2020-01-01' or p_jour > date '2100-12-31' then
    return jsonb_build_object('ok', false, 'erreur', 'Date invalide');
  end if;
  if not p_admin and exists (select 1 from public.pointages
      where employe_id = p_employe and jour = p_jour and approuve) then
    return jsonb_build_object('ok', false, 'erreur', 'Journée validée par la direction — modification impossible');
  end if;
  v_mt := coalesce(nullif(trim(p_matin_type), ''), 'travail');
  v_at := coalesce(nullif(trim(p_apm_type), ''), 'travail');
  if v_mt not in ('travail','vacances','maladie','accident','ferie','armee','ecole','autre')
     or v_at not in ('travail','vacances','maladie','accident','ferie','armee','ecole','autre') then
    return jsonb_build_object('ok', false, 'erreur', 'Type de journée invalide');
  end if;
  begin
    v_md := nullif(trim(coalesce(p_matin_debut, '')), '')::time;
    v_mf := nullif(trim(coalesce(p_matin_fin, '')), '')::time;
    v_ad := nullif(trim(coalesce(p_apm_debut, '')), '')::time;
    v_af := nullif(trim(coalesce(p_apm_fin, '')), '')::time;
  exception when others then
    return jsonb_build_object('ok', false, 'erreur', 'Heure invalide');
  end;
  if v_mt <> 'travail' then v_md := null; v_mf := null; end if;
  if v_at <> 'travail' then v_ad := null; v_af := null; end if;
  if v_md is not null and v_mf is not null and v_mf <= v_md then
    return jsonb_build_object('ok', false, 'erreur', 'Matin : l''heure de fin doit être après le début');
  end if;
  if v_ad is not null and v_af is not null and v_af <= v_ad then
    return jsonb_build_object('ok', false, 'erreur', 'Après-midi : l''heure de fin doit être après le début');
  end if;
  if v_mf is not null and v_ad is not null and v_ad < v_mf then
    return jsonb_build_object('ok', false, 'erreur', 'L''après-midi ne peut pas commencer avant la fin du matin');
  end if;
  v_rem := left(coalesce(trim(p_remarque), ''), 200);

  -- Tout vide → on supprime la ligne plutôt que de garder un jour fantôme.
  if v_mt = 'travail' and v_at = 'travail'
     and v_md is null and v_mf is null and v_ad is null and v_af is null and v_rem = '' then
    delete from public.pointages where employe_id = p_employe and jour = p_jour;
    return jsonb_build_object('ok', true, 'supprime', true);
  end if;

  insert into public.pointages
    (employe_id, jour, matin_type, matin_debut, matin_fin, apm_type, apm_debut, apm_fin, remarque)
  values
    (p_employe, p_jour, v_mt, v_md, v_mf, v_at, v_ad, v_af, v_rem)
  on conflict (employe_id, jour) do update set
    matin_type = excluded.matin_type, matin_debut = excluded.matin_debut, matin_fin = excluded.matin_fin,
    apm_type = excluded.apm_type, apm_debut = excluded.apm_debut, apm_fin = excluded.apm_fin,
    remarque = excluded.remarque, modifie_le = now();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- connexion

create or replace function public.connexion(p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_token uuid; v_recentes int;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok', false, 'erreur', 'Le code PIN doit comporter 4 à 8 chiffres');
  end if;
  select count(*) into v_recentes from public.tentatives where quand > now() - interval '1 minute';
  if v_recentes >= 20 then
    return jsonb_build_object('ok', false, 'erreur', 'Trop de tentatives. Réessayez dans une minute.');
  end if;
  insert into public.tentatives default values;
  delete from public.tentatives where quand < now() - interval '1 day';
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

create or replace function public.deconnexion(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
begin
  delete from public.sessions where token = p_token;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- employé

create or replace function public.mes_pointages(p_token uuid, p_annee int, p_mois int)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_ptgs jsonb;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb) into v_ptgs
    from public.pointages p
   where p.employe_id = v_emp.id and p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  return jsonb_build_object('ok', true, 'employe', public._emp_json(v_emp), 'pointages', v_ptgs);
end $$;

create or replace function public.enregistrer_jour(
  p_token uuid, p_jour date,
  p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text,
  p_remarque text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  return public._save_jour(v_emp.id, p_jour,
    p_matin_type, p_matin_debut, p_matin_fin, p_apm_type, p_apm_debut, p_apm_fin, p_remarque, false);
end $$;

create or replace function public.supprimer_jour(p_token uuid, p_jour date)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if exists (select 1 from public.pointages
      where employe_id = v_emp.id and jour = p_jour and approuve) then
    return jsonb_build_object('ok', false, 'erreur', 'Journée validée par la direction — suppression impossible');
  end if;
  delete from public.pointages where employe_id = v_emp.id and jour = p_jour;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- admin

create or replace function public.admin_donnees(p_token uuid, p_annee int, p_mois int)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb; v_entreprise text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._emp_json(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e;
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs);
end $$;

create or replace function public.admin_enregistrer_jour(
  p_token uuid, p_employe uuid, p_jour date,
  p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text,
  p_remarque text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if not exists (select 1 from public.employes where id = p_employe) then
    return jsonb_build_object('ok', false, 'erreur', 'Employé introuvable');
  end if;
  return public._save_jour(p_employe, p_jour,
    p_matin_type, p_matin_debut, p_matin_fin, p_apm_type, p_apm_debut, p_apm_fin, p_remarque, true);
end $$;

create or replace function public.admin_supprimer_jour(p_token uuid, p_employe uuid, p_jour date)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  delete from public.pointages where employe_id = p_employe and jour = p_jour;
  return jsonb_build_object('ok', true);
end $$;

-- Création / modification d'un employé. p_pin facultatif en modification.
create or replace function public.admin_employe(
  p_token uuid, p_id uuid,
  p_prenom text, p_nom text, p_metier text, p_actif boolean,
  p_md text, p_mf text, p_ad text, p_af text,
  p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_id uuid;
  v_md time; v_mf time; v_ad time; v_af time;
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
  begin
    v_md := coalesce(nullif(trim(coalesce(p_md, '')), '')::time, time '07:30');
    v_mf := coalesce(nullif(trim(coalesce(p_mf, '')), '')::time, time '12:00');
    v_ad := coalesce(nullif(trim(coalesce(p_ad, '')), '')::time, time '13:00');
    v_af := coalesce(nullif(trim(coalesce(p_af, '')), '')::time, time '17:00');
  exception when others then
    return jsonb_build_object('ok', false, 'erreur', 'Heure invalide dans la journée type');
  end;
  if p_pin is not null and p_pin <> '' then
    if p_pin !~ '^[0-9]{4,8}$' then
      return jsonb_build_object('ok', false, 'erreur', 'Le code PIN doit comporter 4 à 8 chiffres');
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
    insert into public.employes (prenom, nom, metier, actif, matin_debut_def, matin_fin_def, apm_debut_def, apm_fin_def, pin_hash)
    values (trim(p_prenom), coalesce(trim(p_nom), ''), coalesce(trim(p_metier), ''), coalesce(p_actif, true),
            v_md, v_mf, v_ad, v_af, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
    returning id into v_id;
  else
    update public.employes set
      prenom = trim(p_prenom), nom = coalesce(trim(p_nom), ''), metier = coalesce(trim(p_metier), ''),
      actif = coalesce(p_actif, true),
      matin_debut_def = v_md, matin_fin_def = v_mf, apm_debut_def = v_ad, apm_fin_def = v_af,
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

-- Validation par la direction : un jour précis (p_jour) ou tout le mois.
create or replace function public.admin_approuver(
  p_token uuid, p_employe uuid, p_annee int, p_mois int, p_jour date, p_approuve boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_n int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_jour is not null then
    update public.pointages set
      approuve = p_approuve,
      approuve_le = case when p_approuve then now() else null end,
      approuve_par = case when p_approuve then v_emp.id else null end
    where employe_id = p_employe and jour = p_jour;
  else
    if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
      return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
    end if;
    v_debut := make_date(p_annee, p_mois, 1);
    update public.pointages set
      approuve = p_approuve,
      approuve_le = case when p_approuve then now() else null end,
      approuve_par = case when p_approuve then v_emp.id else null end
    where employe_id = p_employe and jour >= v_debut and jour < v_debut + interval '1 month';
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'nombre', v_n);
end $$;

create or replace function public.admin_parametre(p_token uuid, p_cle text, p_valeur text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_cle not in ('entreprise') then
    return jsonb_build_object('ok', false, 'erreur', 'Paramètre inconnu');
  end if;
  insert into public.parametres (cle, valeur) values (p_cle, left(coalesce(p_valeur, ''), 200))
  on conflict (cle) do update set valeur = excluded.valeur;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- droits

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.connexion(text) to anon;
grant execute on function public.deconnexion(uuid) to anon;
grant execute on function public.mes_pointages(uuid, int, int) to anon;
grant execute on function public.enregistrer_jour(uuid, date, text, text, text, text, text, text, text) to anon;
grant execute on function public.supprimer_jour(uuid, date) to anon;
grant execute on function public.admin_donnees(uuid, int, int) to anon;
grant execute on function public.admin_enregistrer_jour(uuid, uuid, date, text, text, text, text, text, text, text) to anon;
grant execute on function public.admin_supprimer_jour(uuid, uuid, date) to anon;
grant execute on function public.admin_employe(uuid, uuid, text, text, text, boolean, text, text, text, text, text) to anon;
grant execute on function public.admin_approuver(uuid, uuid, int, int, date, boolean) to anon;
grant execute on function public.admin_parametre(uuid, text, text) to anon;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
