-- CAPTURE DE LA PRODUCTION — NE PAS APPLIQUER TEL QUEL
--
-- Ce fichier n'est pas une migration. C'est la définition de controle_saisies
-- réellement en service sur la base, relevée le 31.08.2026 par
-- pg_get_functiondef. Elle n'existe dans aucune migration du dépôt : quelqu'un
-- l'a posée directement sur la base, et deux fois déjà une migration a failli
-- l'effacer sans bruit.
--
-- Ce qu'elle contient d'unique : la formulation du rappel, qui renvoie au
-- bouton vert et non à « Enregistrer ma journée d'aujourd'hui ».
--
-- Le fichier vit hors de supabase/migrations pour qu'aucun rejeu ne le
-- réapplique dans le mauvais ordre. Il est ici pour qu'on ne le perde plus, et
-- pour servir de référence à toute migration qui touchera cette fonction.

CREATE OR REPLACE FUNCTION public.controle_saisies(p_secret text, p_relancer boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
      -- Le libellé du bouton varie (« Enregistrer » ou « Confirmer » selon que la
      -- journée est déjà posée) : le message reste donc neutre.
      select v_an, v_mo, v_admin,
             'Bonjour ' || c.prenom || ', il reste ' || c.n || ' jour' ||
             case when c.n > 1 then 's' else '' end || ' à confirmer dans ta feuille d''heures. ' ||
             'Ouvre l''application et touche le bouton vert en haut : si l''horaire affiché est le bon, ' ||
             'un appui suffit. Sinon, touche le jour dans la liste pour le corriger. Merci !',
             c.id, false, false, false, true
      from cible c
      returning employe_id
    )
    select coalesce(jsonb_agg(employe_id), '[]'::jsonb) into v_relances from pose;
  end if;

  return jsonb_build_object('ok', true, 'date', to_char(current_date, 'DD.MM.YYYY'),
    'tracabilite_depuis', to_char(v_depuis, 'DD.MM.YYYY'),
    'techniciens', v_lignes, 'relances_posees', v_relances);
end $function$
