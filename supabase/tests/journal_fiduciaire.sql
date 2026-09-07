\set ON_ERROR_STOP on
do $$ begin
  if exists (select 1 from public.pointages) then
    raise exception 'REFUS : base non jetable.';
  end if;
end $$;

insert into public.employes (prenom, nom, pin_hash, role) values
  ('Back Office','','x','admin'), ('Fiduciaire','','x','compta'), ('Sami','Ferjani','x','employe');
insert into public.sessions (employe_id) select id from public.employes;
create temporary view jetons as
  select e.prenom, e.role, e.id, s.token from public.sessions s join public.employes e on e.id=s.employe_id;

select '— 1. la fiduciaire ouvre son écran cinq fois de suite (le rafraîchissement d une minute) —' as etape;
select public.compta_donnees((select token from jetons where role='compta'), 2026, 9) is not null from generate_series(1,5);
select action, cible, count(*) as lignes from public.journal
 where acteur_role='compta' group by 1,2 order by 1;

select '— 2. elle passe au mois d avant : cela, on veut le voir —' as etape;
select public.compta_donnees((select token from jetons where role='compta'), 2026, 8) is not null;
select action, cible, count(*) as lignes from public.journal
 where acteur_role='compta' group by 1,2 order by 1,2;

select '— 3. le back office aussi est vu arriver, maintenant —' as etape;
select public.admin_donnees((select token from jetons where role='admin'), 2026, 9) is not null from generate_series(1,3);
select acteur_nom, action, cible, count(*) from public.journal
 where action='consultation' group by 1,2,3 order by 1,3;

select '— 4. la direction écrit, la fiduciaire lit : la lecture a un auteur —' as etape;
select public.message_ecrire((select token from jetons where role='admin'), 2026, 9, 'Question pour la fiduciaire.');
select public.messages_marquer_lus((select token from jetons where role='compta'), 2026, 9);
select acteur_nom, acteur_role, (acteur_id is not null) as classable, action, cible
  from public.journal where action='message_lu';

select '— 5. l export qu elle emporte —' as etape;
select public.journal_noter((select token from jetons where role='compta'), 'export', '09.2026',
                            jsonb_build_object('n', 3));
select public.journal_noter((select token from jetons where role='compta'), 'suppression_totale', 'tout')
       as action_refusee;
select acteur_nom, action, cible, detail->>'n' as employes from public.journal where action='export';

select '— 6. et le technicien ne voit toujours rien de tout cela —' as etape;
select prenom, role, coalesce((public.journal_lire(token,30))->>'erreur','(ouvert)') as journal
  from jetons order by role;

select '— 7. le journal de la fiduciaire, tel que le back office le lira —' as etape;
select jsonb_pretty(jsonb_agg(x)) from (
  select jsonb_build_object('action', action, 'cible', cible, 'detail', detail) as x
    from public.journal where acteur_role='compta' order by quand) s;
