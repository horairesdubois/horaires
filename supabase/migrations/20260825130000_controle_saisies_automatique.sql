-- Jours fériés genevois en base + contrôle automatique des saisies.
--
-- Jusqu'ici seule l'interface (en JavaScript) savait calculer les fériés ; la base
-- en a besoin à son tour, pour ne pas réclamer des heures un jour férié.
-- Pâques suit l'algorithme de Meeus/Jones/Butcher, comme côté navigateur.
--
-- Le contrôle est appelé chaque soir par une routine planifiée. Cette routine
-- tourne sans les outils Supabase : elle appelle donc la fonction par une simple
-- requête HTTPS avec la clé publique « anon ». Comme le rapport nomme les
-- collaborateurs en retard, il ne doit pas être lisible par le premier venu :
-- la fonction exige un secret dédié, stocké dans parametres (hors dépôt).
--
-- Ce secret ne donne accès qu'au rapport et à la pose d'un rappel. Il ne permet
-- ni de lire des heures, ni un bulletin de salaire, ni de modifier quoi que ce
-- soit — contrairement à un jeton de direction, qu'il aurait été imprudent de
-- déposer dans une tâche planifiée.

create or replace function public.paques(p_annee int)
returns date
language sql immutable set search_path = public
as $$
  with x as (select p_annee % 19 as a, p_annee / 100 as b, p_annee % 100 as c),
       y as (select a, b, c, b / 4 as d, b % 4 as e, (b + 8) / 25 as f from x),
       z as (select a, b, c, d, e, f, (b - f + 1) / 3 as g, c / 4 as i, c % 4 as k from y),
       w as (select a, c, d, e, g, i, k, b, (19 * a + b - d - g + 15) % 30 as h from z),
       v as (select a, h, (32 + 2 * e + 2 * i - h - k) % 7 as l from w),
       u as (select h, l, (a + 11 * h + 22 * l) / 451 as m from v)
  select make_date(p_annee, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1) from u
$$;

create or replace function public.feries_ge(p_annee int)
returns setof date
language sql immutable set search_path = public
as $$
  select d from (values
      (make_date(p_annee, 1, 1)),            -- Nouvel An
      (public.paques(p_annee) - 2),          -- Vendredi saint
      (public.paques(p_annee) + 1),          -- Lundi de Pâques
      (public.paques(p_annee) + 39),         -- Ascension
      (public.paques(p_annee) + 50),         -- Lundi de Pentecôte
      (make_date(p_annee, 8, 1)),            -- Fête nationale
      (make_date(p_annee, 9, 1)              -- Jeûne genevois : jeudi suivant le
        + ((7 - extract(dow from make_date(p_annee, 9, 1))::int) % 7) + 4),  -- 1er dimanche de septembre
      (make_date(p_annee, 12, 25)),          -- Noël
      (make_date(p_annee, 12, 31))           -- Restauration de la République
  ) as t(d)
$$;

alter table public.messages add column if not exists automatique boolean not null default false;

create or replace function public.controle_saisies(p_secret text, p_relancer boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_attendu text; v_admin uuid; v_lignes jsonb; v_relances jsonb; v_an int; v_mo int;
begin
  select valeur into v_attendu from public.parametres where cle = 'controle_secret';
  if v_attendu is null or v_attendu = '' or p_secret is distinct from v_attendu then
    return jsonb_build_object('ok', false, 'erreur', 'secret');
  end if;

  v_an := extract(year from current_date)::int;
  v_mo := extract(month from current_date)::int;
  select id into v_admin from public.employes where role = 'admin' and actif limit 1;

  with jours as (
    select d::date as jour
    from generate_series(date_trunc('month', current_date), current_date, '1 day') d
    where extract(dow from d) between 1 and 5
      and not exists (select 1 from public.feries_ge(extract(year from d)::int) f where f = d::date)
  ),
  techs as (select id, prenom, nom from public.employes where role = 'employe' and actif),
  manques as (
    select t.id, t.prenom, j.jour
    from techs t cross join jours j
    left join public.pointages p on p.employe_id = t.id and p.jour = j.jour
    where p.id is null
  )
  select coalesce(jsonb_agg(x order by x->>'prenom'), '[]'::jsonb) into v_lignes from (
    select jsonb_build_object(
      'employe_id', t.id, 'prenom', t.prenom,
      'manquants', (select count(*) from manques m where m.id = t.id),
      'aujourdhui', exists (select 1 from manques m where m.id = t.id and m.jour = current_date),
      'jours', coalesce((select jsonb_agg(to_char(m.jour, 'DD.MM') order by m.jour desc)
                           from manques m where m.id = t.id), '[]'::jsonb)
    ) as x from techs t
  ) s;

  -- Rappel déposé dans le fil du collaborateur, au plus une fois par jour.
  v_relances := '[]'::jsonb;
  if p_relancer and v_admin is not null then
    with cible as (
      select (e->>'employe_id')::uuid as id, e->>'prenom' as prenom, (e->>'manquants')::int as n
      from jsonb_array_elements(v_lignes) e
      where (e->>'manquants')::int > 0
        and not exists (
          select 1 from public.messages m
           where m.employe_id = (e->>'employe_id')::uuid
             and m.automatique and m.cree_le >= date_trunc('day', now()))
    ), pose as (
      insert into public.messages (annee, mois, auteur_id, texte, employe_id,
                                   lu_direction, lu_compta, lu_employe, automatique)
      select v_an, v_mo, v_admin,
             'Bonjour ' || c.prenom || ', il manque ' || c.n || ' jour' ||
             case when c.n > 1 then 's' else '' end ||
             ' dans ta feuille d''heures. Peux-tu les compléter depuis l''application ? ' ||
             'Un appui sur « Enregistrer ma journée d''aujourd''hui » suffit si tu as fait ton horaire normal. Merci !',
             c.id, false, false, false, true
      from cible c
      returning employe_id
    )
    select coalesce(jsonb_agg(employe_id), '[]'::jsonb) into v_relances from pose;
  end if;

  return jsonb_build_object('ok', true, 'date', to_char(current_date, 'DD.MM.YYYY'),
    'jour', trim(to_char(current_date, 'TMDay')),
    'techniciens', v_lignes, 'relances_posees', v_relances);
end $$;
revoke execute on function public.controle_saisies(text, boolean) from public, authenticated;
grant execute on function public.controle_saisies(text, boolean) to anon;
