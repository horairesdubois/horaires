-- Le rappel passe du soir au lendemain 9h00, et devient désactivable par personne.
--
-- CE QUI CHANGE, ET POURQUOI LE TEXTE DU MESSAGE DOIT CHANGER AUSSI
-- Le rappel partait à 18h00 UTC, soit 20h00 à Genève l'été, et portait sur la
-- journée en cours. Il part désormais le lendemain à 9h00, et porte sur les
-- jours déjà terminés.
--
-- Conséquence qu'il ne faut pas manquer : l'ancien texte renvoyait au bouton
-- vert en haut de l'écran. Ce bouton agit TOUJOURS sur la journée du jour —
-- « Enregistrer ma journée d'aujourd'hui », ou « Confirmer ma journée » quand
-- elle est déjà posée. Reçu le lendemain matin à propos de la veille, ce conseil
-- ferait donc enregistrer le mauvais jour : le technicien croirait avoir
-- rattrapé son retard en créant une saisie fausse pour la journée qui commence.
--
-- Le rappel ne portant plus que sur des jours passés, le bouton vert n'est
-- jamais la bonne action. Le texte nomme les jours concernés et renvoie vers la
-- liste — « touche ce jour dans la liste », le geste que l'application propose
-- déjà elle-même pour corriger un jour antérieur.
--
-- 9H00 À GENÈVE TOUTE L'ANNÉE
-- pg_cron raisonne en UTC, et Genève change d'heure deux fois par an. Une seule
-- planification donnerait 9h00 l'été et 10h00 l'hiver. On planifie donc deux
-- réveils, à 7h00 et 8h00 UTC, et la fonction ne fait rien si l'heure locale
-- n'est pas 9. Exactement un envoi par jour ouvré, à la même heure toute l'année.
--
-- LE VENDREDI EST RATTRAPÉ LE LUNDI, PAS LE SAMEDI
-- Le lendemain d'un vendredi est un samedi. Relancer un technicien le samedi
-- matin sur sa feuille d'heures est intrusif et ne fait rien gagner : la
-- planification reste du lundi au vendredi, et comme la fenêtre couvre tous les
-- jours ouvrés du mois jusqu'à la veille, le vendredi manquant ressort le lundi.

-- ---------------------------------------------------------------- interrupteur

alter table public.employes
  add column if not exists notifications boolean not null default true;

comment on column public.employes.notifications is
  'Faux : ce collaborateur ne reçoit aucun rappel automatique. Il reste visible '
  'dans le contrôle de la direction — on coupe la notification, pas la surveillance.';

-- ---------------------------------------------------------------- contrôle

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
    select t.id, j.jour, p.id is null as vide,
           (p.id is not null and j.jour >= v_depuis
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

-- ---------------------------------------------------------------- ordonnanceur

/**
 * Réveillé à 7h00 et 8h00 UTC ; ne travaille qu'à 9h00 heure de Genève.
 * Renvoie -1 quand il passe son tour, pour distinguer « rien à faire » de
 * « ce n'était pas l'heure » quand on relit cron.job_run_details.
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

  select jsonb_array_length(
           (public.controle_saisies(
              (select valeur from public.parametres where cle = 'controle_secret'), true)
           )->'relances_posees')
    into v_n;
  return coalesce(v_n, 0);
end $$;
revoke execute on function public.relancer_saisies() from anon, authenticated, public;

-- Reprogrammation. Contrairement aux migrations précédentes, elle ne peut pas
-- rester en commentaire : l'ancienne tâche du soir enverrait sinon un rappel à
-- 20h00 portant sur la veille, ce qui serait pire que l'état actuel.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- On ne se fie pas au nom de l'ancienne tâche : on retire TOUTE tâche qui
    -- appelle relancer_saisies. Un nom deviné et faux laisserait l'ancien envoi
    -- du soir en place, et les techniciens recevraient deux rappels par jour.
    perform cron.unschedule(jobid)
       from cron.job
      where command ilike '%relancer_saisies%'
        and jobname not in ('relance-saisies-matin-a', 'relance-saisies-matin-b');
    if not exists (select 1 from cron.job where jobname = 'relance-saisies-matin-a') then
      perform cron.schedule('relance-saisies-matin-a', '0 7 * * 1-5',
                            'select public.relancer_saisies();');
    end if;
    if not exists (select 1 from cron.job where jobname = 'relance-saisies-matin-b') then
      perform cron.schedule('relance-saisies-matin-b', '0 8 * * 1-5',
                            'select public.relancer_saisies();');
    end if;
  else
    raise notice 'pg_cron absent : planification à poser à la main.';
  end if;
exception when others then
  raise notice 'Reprogrammation impossible ici (%). À poser à la main.', sqlerrm;
end $$;

-- ---------------------------------------------------------------- cas Alen

-- Demande explicite de la direction : Alen ne reçoit plus de rappel automatique,
-- et l'historique de ceux déjà envoyés est effacé de son fil.
--
-- La suppression ne porte QUE sur les messages automatiques : un mot écrit à la
-- main par la direction ou la comptabilité reste, quoi qu'il arrive. Et si le
-- prénom ne désigne pas exactement une personne, la migration s'arrête au lieu
-- de deviner — mieux vaut la rejouer avec le bon prénom que de vider le fil de
-- quelqu'un d'autre.
do $$
declare v_id uuid; v_n int; v_efface int;
begin
  select count(*) into v_n from public.employes where lower(trim(prenom)) = 'alen';
  if v_n <> 1 then
    raise exception
      'Attendu exactement un collaborateur prénommé « Alen », trouvé %. '
      'Corrigez le prénom dans cette migration puis rejouez-la.', v_n;
  end if;

  select id into v_id from public.employes where lower(trim(prenom)) = 'alen';
  update public.employes set notifications = false where id = v_id;

  delete from public.messages where employe_id = v_id and automatique;
  get diagnostics v_efface = row_count;
  raise notice 'Alen : notifications coupées, % rappel(s) automatique(s) effacé(s).', v_efface;
end $$;
