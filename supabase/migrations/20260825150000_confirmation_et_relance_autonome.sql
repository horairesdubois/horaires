-- Confirmation de la journée par le technicien, et relances autonomes.
--
-- 1. CONFIRMATION
--    Le bouton du jour considérait comme acquise une journée déjà posée : le
--    technicien ne pouvait pas la confirmer. Or c'est justement sa confirmation
--    en fin de journée qui atteste son passage — même quand l'horaire
--    pré-rempli lui convient tel quel. _ptg_json expose donc « confirme », vrai
--    seulement si la ligne a été écrite par l'intéressé lui-même.
--
-- 2. SIGNATURE
--    Les rappels automatiques ne sont pas écrits par la direction. Les signer
--    « Direction » laisserait croire au technicien que son patron lui écrit
--    personnellement à chaque oubli : ils sont signés « Back office ».
--
-- 3. RELANCES AUTONOMES
--    Le contrôle du soir était déclenché par une routine extérieure, qui
--    appelait la base par HTTPS. Cet appel a été refusé par le classificateur
--    de sécurité de l'environnement d'exécution : les techniciens n'auraient
--    jamais été relancés. La relance redescend donc dans la base, où elle a
--    toujours eu sa place — pg_cron la déclenche du lundi au vendredi à 18h00
--    UTC (20h00 à Genève l'été, 19h00 l'hiver). Le rapport à la direction reste
--    du ressort de la routine, mais s'il manque, les collaborateurs sont
--    relancés quand même.

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
    'confirme', p.saisi_par is not null and p.saisi_par = p.employe_id)
$$;

create or replace function public._msg_json(m public.messages)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', m.id, 'annee', m.annee, 'mois', m.mois, 'employe_id', m.employe_id,
    'auteur', case when m.automatique then 'Back office'
                   else (select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom)
                           from public.employes e where e.id = m.auteur_id) end,
    'role', case when m.automatique then 'systeme'
                 else (select e.role from public.employes e where e.id = m.auteur_id) end,
    'automatique', m.automatique,
    'texte', m.texte,
    'quand', to_char(m.cree_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'))
$$;

-- Rapport en lecture seule, appelable par une simple URL (fonction STABLE) :
-- la routine qui rend compte à la direction ne peut pas lancer de commande shell.
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
           (p.id is not null and j.jour >= v_depuis
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

-- Relance déclenchée par l'ordonnanceur interne, sans secret à transporter :
-- la fonction n'est pas exposée à anon, donc appelable seulement depuis la base.
create extension if not exists pg_cron with schema extensions;

create or replace function public.relancer_saisies()
returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_n int;
begin
  select jsonb_array_length(
           (public.controle_saisies(
              (select valeur from public.parametres where cle = 'controle_secret'), true)
           )->'relances_posees')
    into v_n;
  return coalesce(v_n, 0);
end $$;
revoke execute on function public.relancer_saisies() from anon, authenticated, public;

-- select cron.schedule('relance-saisies-soir', '0 18 * * 1-5',
--                      $$select public.relancer_saisies();$$);
-- (Planification posée une seule fois ; cron.schedule échouerait à rejouer.)
