-- Pré-remplissage automatique de la veille, sans fabriquer d'attestation.
--
-- LE PROBLÈME QUE POSE CE CHANGEMENT
-- Dans ce système, ce qui atteste le passage d'un technicien n'est pas la
-- présence d'une ligne, c'est le fait qu'il l'ait posée lui-même
-- (saisi_par = employe_id). Une ligne créée par la machine avec l'horaire type
-- ressemble en tout point à une journée travaillée : mêmes heures, mêmes
-- majorations, même remontée vers la fiduciaire par compta_donnees. Sans
-- marqueur, elle deviendrait une affirmation que personne n'a faite.
--
-- Trois conséquences ont été vérifiées dans le code avant d'écrire :
--
-- 1. ELLE ÉTEIGNAIT LE CONTRÔLE. controle_saisies distingue « vide »
--    (p.id is null, sans borne de date) et « non confirmé » (borné par
--    tracabilite_depuis). Créer la ligne fait sortir le jour de « vide » sans
--    le faire entrer dans « non confirmé » dès qu'il est antérieur à cette
--    borne : le jour disparaissait du rappel, du rapport et de la grille, sans
--    qu'aucun canal ne le signale. La colonne prerempli rend le signal
--    indépendant de la date.
--
-- 2. ELLE TRANSFORMAIT UNE ABSENCE EN JOURNÉE TRAVAILLÉE. Un technicien en
--    vacances ou malade qui n'a rien saisi verrait sa journée remplie en
--    « travail ». D'où le marqueur, que l'export doit voir, et le maintien du
--    rappel tant que l'intéressé n'a pas confirmé ou corrigé.
--
-- 3. ELLE N'A LE DROIT DE RIEN ÉCRASER. L'insertion est en « on conflict do
--    nothing » : une ligne posée par un humain, confirmée ou non, n'est jamais
--    touchée. La génération n'emprunte pas _save_jour, dont le « do update »
--    remplacerait les heures.

-- ---------------------------------------------------------------- marqueur

alter table public.pointages
  add column if not exists prerempli boolean not null default false;

comment on column public.pointages.prerempli is
  'Vrai : ligne créée par la génération automatique avec l''horaire type, que '
  'personne n''a encore confirmée. Ce ne sont pas des heures attestées.';

create index if not exists pointages_prerempli_idx on public.pointages (jour)
  where prerempli;

-- Ne jamais générer sur l'historique antérieur à la mise en service : les jours
-- laissés vides avant cette date l'ont peut-être été volontairement.
insert into public.parametres (cle, valeur)
values ('generation_depuis', current_date::text)
on conflict (cle) do nothing;

-- ---------------------------------------------------------------- exposition

-- Le marqueur doit remonter jusqu'à l'interface, sinon le technicien ne peut
-- pas distinguer sa propre saisie d'une ligne apparue toute seule.
create or replace function public._ptg_json(p public.pointages)
returns jsonb
language sql stable set search_path = public, extensions
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
    'approuve_le', to_char(p.approuve_le, 'DD.MM.YYYY'),
    'confirme', p.saisi_par is not null and p.saisi_par = p.employe_id,
    'prerempli', p.prerempli)
$$;

-- Toute écriture humaine lève le marqueur : la ligne cesse d'être une
-- supposition dès que quelqu'un la reprend à son compte.
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

  insert into public.pointages
    (employe_id, jour, matin_type, matin_debut, matin_fin, apm_type, apm_debut, apm_fin,
     remarque, saisi_par, prerempli)
  values
    (p_employe, p_jour, v_mt, v_md, v_mf, v_at, v_ad, v_af, v_rem, p_auteur, false)
  on conflict (employe_id, jour) do update set
    matin_type = excluded.matin_type, matin_debut = excluded.matin_debut, matin_fin = excluded.matin_fin,
    apm_type = excluded.apm_type, apm_debut = excluded.apm_debut, apm_fin = excluded.apm_fin,
    remarque = excluded.remarque, modifie_le = now(),
    prerempli = false,
    saisi_par = case
      when excluded.saisi_par = public.pointages.employe_id then excluded.saisi_par
      when public.pointages.saisi_par = public.pointages.employe_id then public.pointages.saisi_par
      else excluded.saisi_par
    end;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- génération

/**
 * Pose la journée type sur les jours ouvrés déjà terminés du mois qui n'ont
 * aucune ligne. Fonction dédiée, jamais accordée à anon : elle écrit, alors que
 * controle_saisies ne fait que lire et relancer.
 *
 * Ce qu'elle ne fait jamais :
 *   • toucher une ligne existante — « on conflict do nothing », sans exception ;
 *   • écrire un week-end, un férié genevois, ou le jour en cours ;
 *   • remonter avant generation_depuis ni avant tracabilite_depuis ;
 *   • marquer la ligne comme confirmée : saisi_par reste nul, prerempli est vrai.
 */
create or replace function public.generer_pointages_manquants()
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_depuis date; v_gen date; v_borne date; v_poses jsonb;
begin
  select coalesce((select valeur::date from public.parametres where cle = 'tracabilite_depuis'),
                  current_date) into v_depuis;
  select coalesce((select valeur::date from public.parametres where cle = 'generation_depuis'),
                  current_date) into v_gen;
  v_borne := greatest(v_depuis, v_gen);

  with jours as (
    -- Même énumération que controle_saisies : lundi-vendredi, hors fériés
    -- genevois, jusqu'à la veille. Toute divergence ici créerait des lignes que
    -- le contrôle ne réclamerait jamais.
    select d::date as jour
    from generate_series(date_trunc('month', current_date), current_date - 1, '1 day') d
    where extract(dow from d) between 1 and 5
      and not exists (select 1 from public.feries_ge(extract(year from d)::int) f where f = d::date)
      and d::date >= v_borne
  ),
  techs as (select id, matin_debut_def, matin_fin_def, apm_debut_def, apm_fin_def, prenom
              from public.employes where role = 'employe' and actif),
  pose as (
    insert into public.pointages
      (employe_id, jour, matin_type, matin_debut, matin_fin,
       apm_type, apm_debut, apm_fin, remarque, saisi_par, prerempli)
    select t.id, j.jour, 'travail', t.matin_debut_def, t.matin_fin_def,
           'travail', t.apm_debut_def, t.apm_fin_def, '', null, true
      from techs t cross join jours j
     where not exists (select 1 from public.pointages p
                        where p.employe_id = t.id and p.jour = j.jour)
    on conflict (employe_id, jour) do nothing
    returning employe_id, jour
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'prenom', (select prenom from public.employes e where e.id = pose.employe_id),
           'jour', to_char(pose.jour, 'DD.MM.YYYY'))
         order by pose.jour), '[]'::jsonb)
    into v_poses from pose;

  return jsonb_build_object('ok', true, 'depuis', to_char(v_borne, 'DD.MM.YYYY'),
    'posees', v_poses, 'nombre', jsonb_array_length(v_poses));
end $$;
revoke execute on function public.generer_pointages_manquants() from anon, authenticated, public;

-- ------------------------------------------------ contrôle et rapport

-- Les deux fonctions sont reprises intégralement pour ne changer qu'une chose :
-- une ligne pré-remplie compte comme non confirmée sans condition de date.

create or replace function public.controle_saisies(p_secret text, p_relancer boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_attendu text; v_admin uuid; v_lignes jsonb; v_relances jsonb;
  v_an int; v_mo int; v_depuis date; v_fin date;
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

  -- Une relance ne porte que sur des journées terminées ; un rapport montre
  -- aussi le jour en cours. La fenêtre suit donc l'usage qu'on fait de l'appel.
  v_fin := case when p_relancer then current_date - 1 else current_date end;

  with jours as (
    select d::date as jour
    from generate_series(date_trunc('month', current_date), v_fin, '1 day') d
    where extract(dow from d) between 1 and 5
      and not exists (select 1 from public.feries_ge(extract(year from d)::int) f where f = d::date)
  ),
  techs as (select id, prenom, derniere_connexion, notifications
              from public.employes where role = 'employe' and actif),
  etat as (
    -- Une ligne pré-remplie est « non confirmée » quelle que soit la date :
    -- sinon, la générer sur un jour antérieur à tracabilite_depuis la ferait
    -- sortir de « vide » sans la faire entrer ici, et le jour disparaîtrait de
    -- tous les canaux à la fois.
    select t.id, j.jour, p.id is null as vide,
           (p.id is not null
            and (p.prerempli or j.jour >= v_depuis)
            and (p.saisi_par is null or p.saisi_par <> t.id)) as non_confirme
    from techs t cross join jours j
    left join public.pointages p on p.employe_id = t.id and p.jour = j.jour
  )
  select coalesce(jsonb_agg(x order by x->>'prenom'), '[]'::jsonb) into v_lignes from (
    select jsonb_build_object(
      'employe_id', t.id, 'prenom', t.prenom,
      'notifications', t.notifications,
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
    with liste as (
      -- Les jours à nommer dans le message, les plus récents d'abord.
      select (e->>'employe_id')::uuid as id,
             string_agg(d.j, ', ' order by d.ord) filter (where d.ord <= 8) as jours,
             count(*) as n_jours
        from jsonb_array_elements(v_lignes) e,
             lateral jsonb_array_elements_text(
               (e->'jours_vides') || (e->'jours_non_confirmes')) with ordinality as d(j, ord)
       group by 1
    ), cible as (
      select (e->>'employe_id')::uuid as id, e->>'prenom' as prenom,
             (e->>'sans_saisie')::int + (e->>'non_confirmes')::int as n,
             l.jours, l.n_jours
      from jsonb_array_elements(v_lignes) e
      join liste l on l.id = (e->>'employe_id')::uuid
      where (e->>'sans_saisie')::int + (e->>'non_confirmes')::int > 0
        -- Interrupteur par personne : coupé, aucun rappel n'est posé.
        and (e->>'notifications')::boolean
        and not exists (
          select 1 from public.messages m
           where m.employe_id = (e->>'employe_id')::uuid
             and m.automatique and m.cree_le >= date_trunc('day', now()))
    ), pose as (
      insert into public.messages (annee, mois, auteur_id, texte, employe_id,
                                   lu_direction, lu_compta, lu_employe, automatique)
      select v_an, v_mo, v_admin,
             'Bonjour ' || c.prenom || ', il reste ' || c.n || ' jour' ||
             case when c.n > 1 then 's' else '' end || ' à confirmer dans ta feuille d''heures : ' ||
             c.jours || case when c.n_jours > 8 then ', …' else '' end || '. ' ||
             'Ouvre l''application et touche ' ||
             case when c.n > 1 then 'ces jours dans la liste pour les confirmer'
                  else 'ce jour dans la liste pour le confirmer' end || '. Merci !',
             c.id, false, false, false, true
      from cible c
      returning employe_id
    )
    select coalesce(jsonb_agg(employe_id), '[]'::jsonb) into v_relances from pose;
  end if;

  return jsonb_build_object('ok', true, 'date', to_char(current_date, 'DD.MM.YYYY'),
    'jusqu_au', to_char(v_fin, 'DD.MM.YYYY'),
    'tracabilite_depuis', to_char(v_depuis, 'DD.MM.YYYY'),
    'techniciens', v_lignes, 'relances_posees', v_relances);
end $$;
revoke execute on function public.controle_saisies(text, boolean) from public, authenticated;
grant execute on function public.controle_saisies(text, boolean) to anon;

create or replace function public.controle_rapport(p_secret text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_attendu text; v_lignes jsonb; v_depuis date;
begin
  select valeur into v_attendu from public.parametres where cle = 'controle_secret';
  if v_attendu is null or v_attendu = '' or p_secret is distinct from v_attendu then
    return jsonb_build_object('ok', false, 'erreur', 'secret');
  end if;
  select coalesce((select valeur::date from public.parametres where cle = 'tracabilite_depuis'),
                  current_date) into v_depuis;

  with jours as (
    select d::date as jour
    from generate_series(date_trunc('month', current_date), current_date, '1 day') d
    where extract(dow from d) between 1 and 5
      and not exists (select 1 from public.feries_ge(extract(year from d)::int) f where f = d::date)
  ),
  techs as (select id, prenom, derniere_connexion from public.employes where role = 'employe' and actif),
  etat as (
    select t.id, j.jour, p.id is null as vide,
           (p.id is not null
            and (p.prerempli or j.jour >= v_depuis)
            and (p.saisi_par is null or p.saisi_par <> t.id)) as non_confirme
    from techs t cross join jours j
    left join public.pointages p on p.employe_id = t.id and p.jour = j.jour
  )
  select coalesce(jsonb_agg(x order by x->>'prenom'), '[]'::jsonb) into v_lignes from (
    select jsonb_build_object(
      'prenom', t.prenom,
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
          to_char(t.derniere_connexion at time zone 'Europe/Zurich', 'DD.MM HH24:MI'), 'jamais'),
      'rappel_envoye_aujourdhui', exists (
          select 1 from public.messages m
           where m.employe_id = t.id and m.automatique
             and m.cree_le >= date_trunc('day', now()))
    ) as x
    from techs t
  ) s;

  return jsonb_build_object('ok', true, 'date', to_char(current_date, 'DD.MM.YYYY'),
    'techniciens', v_lignes);
end $$;
revoke execute on function public.controle_rapport(text) from public, authenticated;
grant execute on function public.controle_rapport(text) to anon;

-- ------------------------------------------------ ordonnanceur

/**
 * L'ordre compte : on génère AVANT de relancer. Le rappel voit alors les jours
 * pré-remplis comme non confirmés et en demande la confirmation — au lieu de
 * les réclamer comme vides le matin et de les voir apparaître dans la foulée.
 */
create or replace function public.relancer_saisies()
returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_n int;
begin
  if extract(hour from now() at time zone 'Europe/Zurich')::int <> 9 then
    return -1;
  end if;

  perform public.generer_pointages_manquants();

  select jsonb_array_length(
           (public.controle_saisies(
              (select valeur from public.parametres where cle = 'controle_secret'), true)
           )->'relances_posees')
    into v_n;
  return coalesce(v_n, 0);
end $$;
revoke execute on function public.relancer_saisies() from anon, authenticated, public;
