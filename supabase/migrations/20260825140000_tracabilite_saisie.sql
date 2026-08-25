-- Savoir QUI a saisi une journée, et quand chacun s'est connecté.
--
-- Le contrôle du soir vérifiait qu'une ligne existait pour chaque jour ouvré.
-- Insuffisant : une journée saisie par la direction pour un technicien passait
-- pour une présence confirmée. Ce qui compte est que le technicien soit
-- lui-même passé valider sa journée — même sans rien changer à l'horaire
-- pré-rempli. On enregistre donc l'auteur de chaque saisie et la dernière
-- connexion de chacun.
--
-- La traçabilité ne vaut qu'à partir de la date stockée dans le paramètre
-- « tracabilite_depuis » : les journées chargées auparavant (reprise de
-- l'historique) n'ont pas d'auteur et ne doivent pas déclencher d'alerte.

alter table public.pointages add column if not exists saisi_par uuid references public.employes(id);
alter table public.employes  add column if not exists derniere_connexion timestamptz;
create index if not exists pointages_saisi_par_idx on public.pointages (saisi_par);

insert into public.parametres (cle, valeur) values ('tracabilite_depuis', current_date::text)
on conflict (cle) do nothing;

-- L'ancienne signature à dix arguments n'écrivait pas l'auteur : la laisser
-- vivre à côté de la nouvelle exposerait à l'appeler par mégarde.
drop function if exists public._save_jour(uuid, date, text, text, text, text, text, text, text, boolean);

create or replace function public._save_jour(
  p_employe uuid, p_jour date, p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text, p_remarque text, p_admin boolean,
  p_auteur uuid default null)
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
  if v_mt not in ('travail','vacances','maladie','accident','ferie','armee','ecole','conge_np','autre')
     or v_at not in ('travail','vacances','maladie','accident','ferie','armee','ecole','conge_np','autre') then
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

  if v_mt = 'travail' and v_at = 'travail'
     and v_md is null and v_mf is null and v_ad is null and v_af is null and v_rem = '' then
    delete from public.pointages where employe_id = p_employe and jour = p_jour;
    return jsonb_build_object('ok', true, 'supprime', true);
  end if;

  insert into public.pointages
    (employe_id, jour, matin_type, matin_debut, matin_fin, apm_type, apm_debut, apm_fin, remarque, saisi_par)
  values
    (p_employe, p_jour, v_mt, v_md, v_mf, v_at, v_ad, v_af, v_rem, p_auteur)
  on conflict (employe_id, jour) do update set
    matin_type = excluded.matin_type, matin_debut = excluded.matin_debut, matin_fin = excluded.matin_fin,
    apm_type = excluded.apm_type, apm_debut = excluded.apm_debut, apm_fin = excluded.apm_fin,
    remarque = excluded.remarque, saisi_par = excluded.saisi_par, modifie_le = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.enregistrer_jour(
  p_token uuid, p_jour date, p_matin_type text, p_matin_debut text, p_matin_fin text,
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
    p_matin_type, p_matin_debut, p_matin_fin, p_apm_type, p_apm_debut, p_apm_fin, p_remarque,
    false, v_emp.id);
end $$;

create or replace function public.admin_enregistrer_jour(
  p_token uuid, p_employe uuid, p_jour date, p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text, p_remarque text)
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
    p_matin_type, p_matin_debut, p_matin_fin, p_apm_type, p_apm_debut, p_apm_fin, p_remarque,
    true, v_emp.id);
end $$;

-- Horodatage de la connexion, quelle que soit la voie d'entrée.
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
  update public.employes set derniere_connexion = now() where id = v_emp.id;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $$;

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
   where e.actif and e.pin_actif and e.pin_hash = extensions.crypt(p_pin, e.pin_hash)
   limit 1;
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Code PIN incorrect');
  end if;
  delete from public.sessions where expire_le < now();
  insert into public.sessions (employe_id) values (v_emp.id) returning token into v_token;
  update public.employes set derniere_connexion = now() where id = v_emp.id;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $$;

-- Le contrôle du soir distingue : aucune saisie / saisie non confirmée par
-- l'intéressé / tout confirmé, et rapporte la dernière connexion.
create or replace function public.controle_saisies(p_secret text, p_relancer boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_attendu text; v_admin uuid; v_lignes jsonb; v_relances jsonb;
  v_an int; v_mo int; v_depuis date;
begin
  select valeur into v_attendu from public.parametres where cle = 'controle_secret';
  if v_attendu is null or v_attendu = '' or p_secret is distinct from v_attendu then
    return jsonb_build_object('ok', false, 'erreur', 'secret');
  end if;

  v_an := extract(year from current_date)::int;
  v_mo := extract(month from current_date)::int;
  select coalesce((select valeur::date from public.parametres where cle = 'tracabilite_depuis'),
                  current_date) into v_depuis;
  select id into v_admin from public.employes where role = 'admin' and actif limit 1;

  with jours as (
    select d::date as jour
    from generate_series(date_trunc('month', current_date), current_date, '1 day') d
    where extract(dow from d) between 1 and 5
      and not exists (select 1 from public.feries_ge(extract(year from d)::int) f where f = d::date)
  ),
  techs as (select id, prenom, derniere_connexion from public.employes where role = 'employe' and actif),
  etat as (
    select t.id, j.jour, p.id is null as vide,
           (p.id is not null and j.jour >= v_depuis
            and (p.saisi_par is null or p.saisi_par <> t.id)) as non_confirme
    from techs t cross join jours j
    left join public.pointages p on p.employe_id = t.id and p.jour = j.jour
  )
  select coalesce(jsonb_agg(x order by x->>'prenom'), '[]'::jsonb) into v_lignes from (
    select jsonb_build_object(
      'employe_id', t.id, 'prenom', t.prenom,
      'sans_saisie',   (select count(*) from etat e where e.id = t.id and e.vide),
      'jours_vides',   coalesce((select jsonb_agg(to_char(e.jour,'DD.MM') order by e.jour desc)
                                   from etat e where e.id = t.id and e.vide), '[]'::jsonb),
      'non_confirmes', (select count(*) from etat e where e.id = t.id and e.non_confirme),
      'jours_non_confirmes', coalesce((select jsonb_agg(to_char(e.jour,'DD.MM') order by e.jour desc)
                                   from etat e where e.id = t.id and e.non_confirme), '[]'::jsonb),
      'aujourdhui_confirme', exists (
          select 1 from public.pointages p
           where p.employe_id = t.id and p.jour = current_date and p.saisi_par = t.id),
      'derniere_connexion', coalesce(
          to_char(t.derniere_connexion at time zone 'Europe/Zurich', 'DD.MM HH24:MI'), 'jamais')
    ) as x
    from techs t
  ) s;

  v_relances := '[]'::jsonb;
  if p_relancer and v_admin is not null then
    with cible as (
      select (e->>'employe_id')::uuid as id, e->>'prenom' as prenom,
             (e->>'sans_saisie')::int + (e->>'non_confirmes')::int as n
      from jsonb_array_elements(v_lignes) e
      where (e->>'sans_saisie')::int + (e->>'non_confirmes')::int > 0
        and not exists (
          select 1 from public.messages m
           where m.employe_id = (e->>'employe_id')::uuid
             and m.automatique and m.cree_le >= date_trunc('day', now()))
    ), pose as (
      insert into public.messages (annee, mois, auteur_id, texte, employe_id,
                                   lu_direction, lu_compta, lu_employe, automatique)
      select v_an, v_mo, v_admin,
             'Bonjour ' || c.prenom || ', il reste ' || c.n || ' jour' ||
             case when c.n > 1 then 's' else '' end || ' à confirmer dans ta feuille d''heures. ' ||
             'Ouvre l''application : si tu as fait ton horaire normal, un appui sur ' ||
             '« Enregistrer ma journée d''aujourd''hui » suffit. Sinon, touche le jour pour corriger. Merci !',
             c.id, false, false, false, true
      from cible c
      returning employe_id
    )
    select coalesce(jsonb_agg(employe_id), '[]'::jsonb) into v_relances from pose;
  end if;

  return jsonb_build_object('ok', true, 'date', to_char(current_date, 'DD.MM.YYYY'),
    'tracabilite_depuis', to_char(v_depuis, 'DD.MM.YYYY'),
    'techniciens', v_lignes, 'relances_posees', v_relances);
end $$;
revoke execute on function public.controle_saisies(text, boolean) from public, authenticated;
grant execute on function public.controle_saisies(text, boolean) to anon;
