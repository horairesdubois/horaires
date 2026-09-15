-- Régression métier et permissions, sur cinq comptes synthétiques temporaires.
-- Aucun compte existant n'est lu ou modifié. Tout est annulé au ROLLBACK.
-- À exécuter après la migration, avec psql -v ON_ERROR_STOP=1 ou un outil SQL
-- qui s'arrête à la première erreur. Chaque échec lève une exception.
begin;
set local statement_timeout = '15s';
set local plpgsql.check_asserts = on;
set local request.headers = '{"user-agent":"Test SQL synthétique"}';

create temp table test_verrou (lib text primary key, id uuid, token uuid) on commit drop;
insert into test_verrou (lib, id, token) select x, gen_random_uuid(), gen_random_uuid()
from unnest(array['technicien','autre','admin','compta','demo']) x;
insert into public.employes (id, prenom, nom, pin_hash, role, demo)
select id, 'Test verrou ' || lib, 'SYNTHETIQUE', 'aucun-code-utilisable',
       case when lib in ('admin','compta') then lib else 'employe' end, lib = 'demo'
from test_verrou;
insert into public.sessions (token, employe_id) select token, id from test_verrou;

do $$
declare t uuid; a uuid; c uuid; ti uuid; ai uuid; j date:=date '2099-11-04'; r jsonb; p public.pointages; v text; n int;
begin
 select token,id into t,ti from test_verrou where lib='technicien';
 select token,id into a,ai from test_verrou where lib='admin';
 select token into c from test_verrou where lib='compta';
 r:=public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','19:00','');
 assert (r->>'ok')::boolean;
 select * into p from public.pointages where employe_id=ti and jour=j;
 v:=public._ptg_json(p)->>'version_decision';
 r:=public.admin_decider_heures(t,ti,j,480,null,v); assert not (r->>'ok')::boolean,'Employé interdit';
 r:=public.admin_decider_heures(c,ti,j,480,null,v); assert not (r->>'ok')::boolean,'Fiduciaire interdite';
 r:=public.admin_decider_heures(a,ti,j,601,null,v); assert not (r->>'ok')::boolean,'Dépassement interdit';
 r:=public.admin_decider_heures(a,ti,j,-1,null,v); assert not (r->>'ok')::boolean,'Négatif interdit';
 r:=public.admin_decider_heures(a,ti,j,null,null,v); assert not (r->>'ok')::boolean,'Null interdit';
 r:=public.admin_decider_heures(a,ti,j,480,null,v); assert (r->>'ok')::boolean,'8 h validées sur 10 sans motif';
 select * into p from public.pointages where employe_id=ti and jour=j;
 assert p.approuve and p.minutes_refusees=120 and p.motif_refus is null and p.apm_fin=time '19:00','Saisie conservée';
 r:=public.admin_decider_heures(a,ti,j,540,'motif',v); assert r->>'code'='conflit','Fenêtre périmée refusée';
 r:=public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','17:00','');
 assert r->>'code'='jour_verrouille','Employé toujours verrouillé';
 for n in select unnest(array[540,0,600,480]) loop
   select * into p from public.pointages where employe_id=ti and jour=j;
   r:=public.admin_decider_heures(a,ti,j,n,'Explication facultative',public._ptg_json(p)->>'version_decision');
   assert (r->>'ok')::boolean,'Révision de la décision';
   select * into p from public.pointages where employe_id=ti and jour=j;
   assert p.minutes_refusees=600-n and p.approuve;
   assert (p.motif_refus is null)=(n=600),'Aucun motif de refus si tout est approuvé';
 end loop;
 r:=public.admin_approuver(a,ti,2099,11,null,true);
 select * into p from public.pointages where employe_id=ti and jour=j;
 assert p.minutes_refusees=120,'La validation du mois conserve la décision partielle';
 assert exists(select 1 from public.journal where action='decision_heures' and acteur_id=ai),'Auteur BO dans le journal';
 r:=public.demande_modification(t,j,'Corriger les heures'); assert (r->>'ok')::boolean;
 select * into p from public.pointages where employe_id=ti and jour=j;
 r:=public.admin_decider_heures(a,ti,j,540,null,public._ptg_json(p)->>'version_decision');
 assert not (r->>'ok')::boolean,'Traiter la demande avant une décision';
 r:=public.admin_repondre_demande(a,ti,j,true,''); assert (r->>'ok')::boolean;
 select * into p from public.pointages where employe_id=ti and jour=j;
 assert not p.approuve and p.minutes_refusees=0 and p.motif_refus is null,'Réouverture efface la décision active';
 r:=public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','19:00','');
 select * into p from public.pointages where employe_id=ti and jour=j;
 r:=public.admin_decider_heures(a,ti,j,480,null,public._ptg_json(p)->>'version_decision');
 r:=public.admin_enregistrer_jour(a,ti,j,'travail','08:00','12:00','travail','13:00','18:00','');
 select * into p from public.pointages where employe_id=ti and jour=j;
 assert not p.approuve and p.saisi_par is null and p.minutes_refusees=0,'Changer l’horaire impose une nouvelle confirmation';
 assert not has_table_privilege('anon','public.pointages','update'),'Aucun accès direct';
 assert not has_function_privilege('anon','public._trg_preparer_decision_heures()','execute'),'Helper privé';
 raise notice 'Approbation partielle : rôles, montants, verrouillage, conflit, révision, lot et journal OK';
end $$;
rollback;
