\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from public.pointages) then raise exception 'REFUS : base non jetable.'; end if;
end $$;

insert into public.employes (prenom,nom,pin_hash,role) values
  ('Back Office','','x','admin'), ('Assidu','A','x','employe'),
  ('Distrait','D','x','employe'), ('Absent','B','x','employe'), ('Fidu','','x','compta');
insert into public.sessions (employe_id) select id from public.employes;
create temporary view a as
  select e.prenom, e.role, e.id, s.token from public.sessions s join public.employes e on e.id=s.employe_id;
select token as jadmin from a where role='admin' \gset
select token as jtech  from a where prenom='Assidu' \gset
select token as jfidu  from a where role='compta' \gset

-- Assidu a tout saisi jusqu'à hier. Distrait s'est arrêté il y a trois jours
-- ouvrés. Absent n'a jamais rien saisi.
insert into public.pointages (employe_id, jour, matin_type, matin_debut, matin_fin,
                              apm_type, apm_debut, apm_fin, saisi_par)
select (select id from a where prenom='Assidu'), g::date, 'travail','08:00','12:00','travail','13:00','17:00',
       (select id from a where prenom='Assidu')
  from generate_series(current_date - 21, current_date - 1, interval '1 day') g
 where extract(isodow from g) between 1 and 5
   and g::date not in (select public.feries_ge(extract(year from g)::int));

insert into public.pointages (employe_id, jour, matin_type, matin_debut, matin_fin,
                              apm_type, apm_debut, apm_fin, saisi_par)
select (select id from a where prenom='Distrait'), g::date, 'travail','08:00','12:00','travail','13:00','17:00',
       (select id from a where prenom='Distrait')
  from generate_series(current_date - 21, current_date - 1, interval '1 day') g
 where extract(isodow from g) between 1 and 5
   and g::date not in (select public.feries_ge(extract(year from g)::int))
   and g::date <= (select max(d) from (
         select d from generate_series(current_date - 21, current_date - 1, interval '1 day') x(d)
          where extract(isodow from x.d) between 1 and 5
            and x.d::date not in (select public.feries_ge(extract(year from x.d)::int))
          order by d desc offset 3) z);

select '— ce que le back office voit —' as etape;
select jsonb_pretty(public.retards_saisie(:'jadmin'::uuid));

select '— et ce que les autres voient —' as etape;
select 'technicien' as qui, public.retards_saisie(:'jtech'::uuid) as reponse
union all select 'fiduciaire', public.retards_saisie(:'jfidu'::uuid);

select '— contrôle : Assidu n a aucun trou —' as etape;
select prenom, count(*) as jours_saisis from public.pointages p
  join public.employes e on e.id=p.employe_id group by 1 order by 1;
