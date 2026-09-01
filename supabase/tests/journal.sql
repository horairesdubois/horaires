\set ON_ERROR_STOP on

-- GARDE-FOU — ce scénario écrit de fausses données.
do $$
begin
  if exists (select 1 from public.employes) or exists (select 1 from public.pointages) then
    raise exception 'REFUS : cette base contient des données réelles. Ce scénario ne se joue que sur une base jetable.';
  end if;
end $$;

insert into public.employes (prenom, nom, pin_hash, role) values
  ('Hugo','Dubois','x','admin'), ('Sami','Ferjani','x','employe'), ('Nadia','Compta','x','compta');

-- Trois connexions : le déclencheur sur sessions doit toutes les voir.
insert into public.sessions (employe_id) select id from public.employes;

select '— 1. connexions inscrites —' as etape;
select action, count(*) from public.journal group by 1;

-- Jetons nommés, pour la suite
create temporary view jetons as
  select e.prenom, e.role, s.token from public.sessions s join public.employes e on e.id = s.employe_id;

select '— 2. le technicien saisit, modifie ; la direction valide puis déverrouille —' as etape;
select public.enregistrer_jour((select token from jetons where prenom='Sami'),
  current_date - 1, 'travail','07:30','12:00','travail','13:00','18:30','chantier Vernier, urgence') ->> 'ok' as saisie;
select public.enregistrer_jour((select token from jetons where prenom='Sami'),
  current_date - 1, 'travail','07:30','12:00','travail','13:00','19:00','chantier Vernier, urgence prolongée') ->> 'ok' as modification;
select public.admin_approuver((select token from jetons where prenom='Hugo'),
  (select id from public.employes where prenom='Sami'),
  extract(year from current_date)::int, extract(month from current_date)::int,
  current_date - 1, true) ->> 'ok' as validation;
select public.admin_approuver((select token from jetons where prenom='Hugo'),
  (select id from public.employes where prenom='Sami'),
  extract(year from current_date)::int, extract(month from current_date)::int,
  current_date - 1, false) ->> 'ok' as deverrouillage;

select '— 3. la fiduciaire consulte ; le technicien ouvre l''application —' as etape;
select public.compta_donnees((select token from jetons where prenom='Nadia'),
  extract(year from current_date)::int, extract(month from current_date)::int) ->> 'ok' as consultation;
select public.mes_pointages((select token from jetons where prenom='Sami'),
  extract(year from current_date)::int, extract(month from current_date)::int) ->> 'ok' as ouverture;

select '— 4. le journal, tel que la direction le lit —' as etape;
select l->>'heure' as heure, l->>'qui' as qui, l->>'role' as role,
       l->>'action' as action, l->>'cible' as cible
  from jsonb_array_elements(
        (public.journal_lire((select token from jetons where prenom='Hugo')))->'lignes') l
 order by 1;

select '— 5. qui a le droit de lire ? —' as etape;
select 'direction'  as demandeur, (public.journal_lire((select token from jetons where prenom='Hugo')))->>'ok' as reponse
union all select 'technicien', (public.journal_lire((select token from jetons where prenom='Sami')))->>'ok'
union all select 'fiduciaire', (public.journal_lire((select token from jetons where prenom='Nadia')))->>'ok';
