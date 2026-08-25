-- 1. Branche CCT par employé (majorations d'heures supplémentaires).
--    Les taux proviennent du classeur de la fiduciaire (onglet Paramètres,
--    table de référence des CCT) : ferblanterie/sanitaire et chauffage relèvent
--    de la CCT « Métiers techniques du bâtiment GE », la vitrerie de la CCT
--    « Second-œuvre romand, avenant GE ». Le détail des taux est appliqué côté
--    interface (export Excel) ; la base ne stocke que la branche.
alter table public.employes
  add column if not exists cct text not null default 'ferblanterie';
alter table public.employes drop constraint if exists employes_cct_check;
alter table public.employes add constraint employes_cct_check
  check (cct in ('ferblanterie', 'chauffage', 'vitrerie'));

-- 2. Nouveau rôle « compta » : la fiduciaire consulte et exporte, sans rien modifier.
alter table public.employes drop constraint if exists employes_role_check;
alter table public.employes add constraint employes_role_check
  check (role in ('employe', 'admin', 'compta'));

-- 3. Messagerie mensuelle entre la direction et la fiduciaire.
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  annee int not null,
  mois int not null check (mois between 1 and 12),
  auteur_id uuid not null references public.employes(id) on delete cascade,
  texte text not null,
  cree_le timestamptz not null default now(),
  lu_direction boolean not null default false,
  lu_compta boolean not null default false
);
alter table public.messages enable row level security;
revoke all on public.messages from anon, authenticated;
create index if not exists messages_mois_idx on public.messages (annee, mois, cree_le);

create or replace function public._msg_json(m public.messages)
returns jsonb
language sql stable
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', m.id, 'annee', m.annee, 'mois', m.mois,
    'auteur', (select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom)
                 from public.employes e where e.id = m.auteur_id),
    'role', (select e.role from public.employes e where e.id = m.auteur_id),
    'texte', m.texte,
    'quand', to_char(m.cree_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'))
$$;
revoke execute on function public._msg_json(public.messages) from public, anon, authenticated;

-- Messages d'un mois + nombre de messages non lus (tous mois confondus) pour le
-- badge. Ouvrir un mois marque ses messages comme lus pour le rôle qui regarde.
create or replace function public.messages_lire(p_token uuid, p_annee int, p_mois int)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_msgs jsonb; v_nl int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  if v_emp.role = 'admin' then
    update public.messages set lu_direction = true
     where annee = p_annee and mois = p_mois and not lu_direction;
  else
    update public.messages set lu_compta = true
     where annee = p_annee and mois = p_mois and not lu_compta;
  end if;
  select coalesce(jsonb_agg(public._msg_json(m) order by m.cree_le), '[]'::jsonb)
    into v_msgs from public.messages m where m.annee = p_annee and m.mois = p_mois;
  select count(*) into v_nl from public.messages m
   where case when v_emp.role = 'admin' then not m.lu_direction else not m.lu_compta end;
  return jsonb_build_object('ok', true, 'messages', v_msgs, 'non_lus', v_nl);
end $$;

create or replace function public.message_ecrire(p_token uuid, p_annee int, p_mois int, p_texte text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_txt text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_txt := trim(coalesce(p_texte, ''));
  if v_txt = '' then return jsonb_build_object('ok', false, 'erreur', 'Message vide'); end if;
  if length(v_txt) > 2000 then
    return jsonb_build_object('ok', false, 'erreur', 'Message trop long (2000 caractères maximum)');
  end if;
  -- L'auteur a forcément lu son propre message.
  insert into public.messages (annee, mois, auteur_id, texte, lu_direction, lu_compta)
  values (p_annee, p_mois, v_emp.id, v_txt,
          v_emp.role = 'admin', v_emp.role = 'compta');
  return jsonb_build_object('ok', true);
end $$;

-- 4. Accès fiduciaire en lecture seule : mêmes données que la direction,
--    sans aucune fonction d'écriture sur les pointages.
create or replace function public.compta_donnees(p_token uuid, p_annee int, p_mois int)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb; v_entreprise text; v_nl int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'compta' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._emp_json(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e where e.role <> 'compta';
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_compta;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl, 'moi', public._emp_json(v_emp));
end $$;

-- 5. La branche CCT apparaît dans les données employé.
create or replace function public._emp_json(e public.employes)
returns jsonb
language sql stable
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', e.id, 'prenom', e.prenom, 'nom', e.nom, 'metier', e.metier,
    'role', e.role, 'actif', e.actif, 'cct', e.cct,
    'cle', e.cle_acces,
    'matin_debut_def', to_char(e.matin_debut_def, 'HH24:MI'),
    'matin_fin_def',   to_char(e.matin_fin_def, 'HH24:MI'),
    'apm_debut_def',   to_char(e.apm_debut_def, 'HH24:MI'),
    'apm_fin_def',     to_char(e.apm_fin_def, 'HH24:MI'))
$$;
revoke execute on function public._emp_json(public.employes) from public, anon, authenticated;

-- 6. Un compte fiduciaire ne saisit pas d'heures.
create or replace function public.enregistrer_jour(p_token uuid, p_jour date,
  p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text, p_remarque text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if v_emp.role = 'compta' then
    return jsonb_build_object('ok', false, 'erreur', 'Accès fiduciaire : consultation uniquement');
  end if;
  return public._save_jour(v_emp.id, p_jour,
    p_matin_type, p_matin_debut, p_matin_fin, p_apm_type, p_apm_debut, p_apm_fin, p_remarque, false);
end $$;

-- 7. La direction choisit la branche CCT et le rôle (employé ou fiduciaire).
drop function if exists public.admin_employe(uuid, uuid, text, text, text, boolean, text, text, text, text, text);
create function public.admin_employe(p_token uuid, p_id uuid, p_prenom text, p_nom text,
  p_metier text, p_actif boolean, p_md text, p_mf text, p_ad text, p_af text, p_pin text,
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
  -- On ne retire jamais son rôle à la direction depuis ce formulaire.
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

-- 8. La direction voit aussi le fil de discussion et son compteur de non-lus.
create or replace function public.admin_donnees(p_token uuid, p_annee int, p_mois int)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb; v_entreprise text; v_nl int;
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
  select count(*) into v_nl from public.messages m where not m.lu_direction;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl);
end $$;

grant execute on function public.messages_lire(uuid, int, int) to anon;
grant execute on function public.message_ecrire(uuid, int, int, text) to anon;
grant execute on function public.compta_donnees(uuid, int, int) to anon;
grant execute on function public.admin_employe(uuid, uuid, text, text, text, boolean, text, text, text, text, text, text, text) to anon;
