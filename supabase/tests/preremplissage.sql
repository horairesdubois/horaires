\set ON_ERROR_STOP on

-- GARDE-FOU — ce scénario écrit de fausses données.
do $$
begin
  if exists (select 1 from public.employes) or exists (select 1 from public.pointages) then
    raise exception 'REFUS : cette base contient des données réelles. Ce scénario ne se joue que sur une base jetable.';
  end if;
end $$;

insert into public.parametres (cle, valeur) values ('controle_secret','s3cret')
  on conflict (cle) do update set valeur='s3cret';
update public.parametres set valeur = date_trunc('month', current_date)::text
 where cle in ('tracabilite_depuis','generation_depuis');

insert into public.employes (prenom, nom, pin_hash, role) values ('Hugo','Dubois','x','admin');
insert into public.employes (prenom, nom, pin_hash, role, matin_debut_def, matin_fin_def, apm_debut_def, apm_fin_def)
values ('Steve','M.','x','employe','07:30','12:00','13:00','17:00'),
       ('Sofia','R.','x','employe','08:00','12:00','13:30','17:30');

-- Sofia a saisi et confirmé l'avant-veille : la génération ne doit pas y toucher.
insert into public.pointages (employe_id, jour, matin_debut, matin_fin, apm_debut, apm_fin, remarque, saisi_par)
select id, current_date - 2, '06:00', '11:00', '12:00', '16:00', 'chantier Carouge', id
  from public.employes where prenom = 'Sofia';

select '— 1. génération —' as etape;
select jsonb_pretty(jsonb_build_object(
  'nombre', (public.generer_pointages_manquants())->'nombre'));

select '— 2. le compte correspond-il aux jours ouvrés écoulés ? —' as etape;
with attendus as (
  select d::date as jour
    from generate_series(date_trunc('month', current_date), current_date - 1, '1 day') d
   where extract(dow from d) between 1 and 5
     and not exists (select 1 from public.feries_ge(extract(year from d)::int) f where f = d::date)
)
select (select count(*) from attendus) as jours_ouvres_ecoules,
       (select count(*) from public.pointages where prerempli) as lignes_prereplies,
       (select count(*) from public.pointages where prerempli
          and (extract(dow from jour) not between 1 and 5)) as sur_week_end,
       (select count(*) from public.pointages where prerempli and jour >= current_date) as sur_aujourdhui_ou_futur,
       (select count(*) from public.pointages where prerempli and saisi_par is not null) as faussement_attestees;

select '— 3. la saisie humaine de Sofia est-elle intacte ? —' as etape;
select e.prenom, p.jour, to_char(p.matin_debut,'HH24:MI') as matin, p.remarque,
       p.prerempli, (p.saisi_par = p.employe_id) as confirme
  from public.pointages p join public.employes e on e.id = p.employe_id
 where p.jour = current_date - 2 and e.prenom = 'Sofia';

select '— 4. idempotence : deuxième passage —' as etape;
select (public.generer_pointages_manquants())->>'nombre' as reposees;

select '— 5. le contrôle voit-il encore les jours pré-remplis ? —' as etape;
select t->>'prenom' as prenom, t->>'sans_saisie' as vides, t->>'non_confirmes' as non_confirmes
  from jsonb_array_elements((public.controle_saisies('s3cret', true))->'techniciens') t;

select '— 6. Steve confirme un jour : le marqueur tombe-t-il ? —' as etape;
select public._save_jour(
  (select id from public.employes where prenom='Steve'), current_date - 1,
  'travail','07:30','12:00','travail','13:00','17:00','', false,
  (select id from public.employes where prenom='Steve'));
select p.jour, p.prerempli, (p.saisi_par = p.employe_id) as confirme
  from public.pointages p join public.employes e on e.id=p.employe_id
 where e.prenom='Steve' and p.jour = current_date - 1;

select '— 7. un jour antérieur à generation_depuis reste-t-il vide ? —' as etape;
update public.parametres set valeur = (current_date - 1)::text where cle = 'generation_depuis';
delete from public.pointages where prerempli;
select (public.generer_pointages_manquants())->>'nombre' as posees_depuis_hier,
       (select count(*) from public.pointages where prerempli and jour < current_date - 1) as avant_la_borne;
