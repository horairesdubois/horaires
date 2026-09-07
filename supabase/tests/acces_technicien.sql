\set ON_ERROR_STOP on

-- GARDE-FOU — ce scénario écrit de fausses données.
do $$
begin
  if exists (select 1 from public.pointages) then
    raise exception 'REFUS : cette base contient des pointages réels. Scénario réservé à une base jetable.';
  end if;
end $$;

insert into public.employes (prenom, nom, pin_hash, role) values
  ('Back Office','','x','admin'), ('Fiduciaire','','x','compta'),
  ('Sami','Ferjani','x','employe'), ('Steve','Carvalho','x','employe');
insert into public.sessions (employe_id) select id from public.employes;
create temporary view a as
  select e.prenom, e.role, e.id, s.token from public.sessions s join public.employes e on e.id=s.employe_id;
select token as jsami from a where prenom='Sami' \gset
select token as jadmin from a where role='admin' \gset
select token as jfidu from a where role='compta' \gset
select id as steve from a where prenom='Steve' \gset

select '— 1. la porte dérobée : _save_jour sans jeton, sous le rôle public —' as etape;
set role anon;
do $$
begin
  perform public._save_jour('00000000-0000-0000-0000-000000000000'::uuid, '2026-09-01',
    'travail','08:00','12:00','travail','13:00','17:00','', true, null);
  raise exception 'ÉCHEC : _save_jour reste appelable par anon.';
exception when insufficient_privilege then
  raise notice 'OK : permission refusée sur _save_jour.';
end $$;
reset role;

select '— 2. mais les portes d entrée fonctionnent toujours —' as etape;
set role anon;
select public.enregistrer_jour(:'jsami'::uuid,'2026-09-01','travail','08:00','12:00','travail','13:00','17:00','') as technicien;
select public.admin_enregistrer_jour(:'jadmin'::uuid, :'steve'::uuid,'2026-09-02','travail','08:00','12:00','travail','13:00','17:00','') as back_office;
reset role;

select '— 3. ce qu un technicien atteint de ce qui ne le regarde pas —' as etape;
select 'écran back office'  as tentative, public.admin_donnees(:'jsami'::uuid, 2026, 9) as reponse
union all select 'écran fiduciaire',  public.compta_donnees(:'jsami'::uuid, 2026, 9)
union all select 'les logs',          public.journal_lire(:'jsami'::uuid, 30)
union all select 'valider un jour',   public.admin_approuver(:'jsami'::uuid, :'steve'::uuid, 2026, 9, '2026-09-02', true)
union all select 'supprimer un jour', public.admin_supprimer_jour(:'jsami'::uuid, :'steve'::uuid, '2026-09-02')
union all select 'clé de Steve',      public.admin_regenerer_cle(:'jsami'::uuid, :'steve'::uuid)
union all select 'réglages',          public.admin_parametre(:'jsami'::uuid, 'entreprise', 'PIRATE')
union all select 'écrire au registre',public.journal_noter(:'jsami'::uuid, 'export', '09.2026');

select '— 4. ses pointages ne parlent que de lui —' as etape;
select count(distinct x->>'employe_id') as personnes_visibles
  from jsonb_array_elements((public.mes_pointages(:'jsami'::uuid, 2026, 9))->'pointages') x;

select '— 5. forcer le fil d un autre ne change rien —' as etape;
select public.message_ecrire(:'jsami'::uuid, 2026, 9, 'INTRUSION', :'steve'::uuid);
select coalesce(e.prenom, '(partagé)') as fil_d_arrivee
  from public.messages m left join public.employes e on e.id = m.employe_id where m.texte = 'INTRUSION';

select '— 6. les bulletins restent à leur propriétaire —' as etape;
select public.bulletin_deposer(:'jadmin'::uuid, :'steve'::uuid, 2026, 8, 'b.pdf',
  'JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZz4+ZW5kb2JqCnRyYWlsZXI8PC9Sb290IDEgMCBSPj4KJSVFT0YK') as depot;
select jsonb_array_length((public.bulletins_lister(:'jsami'::uuid))->'bulletins') as sami_en_voit;
select (public.bulletin_telecharger(:'jsami'::uuid, (select id from public.bulletins limit 1)))->>'erreur' as sami_telecharge;

select '— 7. et la fiduciaire, elle, écrit bien au registre —' as etape;
select public.journal_noter(:'jfidu'::uuid, 'export', '09.2026') as fiduciaire;
