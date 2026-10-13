begin;
do $$
declare e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); co uuid:=gen_random_uuid();
 atok uuid:=gen_random_uuid(); etok uuid:=gen_random_uuid(); ctok uuid:=gen_random_uuid(); req uuid:=gen_random_uuid();
 j date:='2026-10-12'; p public.pointages; r jsonb;
 ev jsonb:='[{"action":"debut","heure":"08:00"},{"action":"pause","heure":"12:00"},{"action":"reprise","heure":"13:00"},{"action":"fin","heure":"17:00"}]';
begin
 insert into public.employes(id,prenom,pin_hash,role,pointage_actif) values
 (e,'Essai jour passé','test','employe',true),(a,'Essai jour passé','test','admin',false),(co,'Essai jour passé','test','compta',false);
 insert into public.sessions(token,employe_id,expire_le) values(etok,e,now()+interval '1 hour'),(atok,a,now()+interval '1 hour'),(ctok,co,now()+interval '1 hour');
 -- Reproduction de la journée réellement bloquée, sans modifier son employé.
 perform public._pointe_ecrire(e,j,'[{"action":"debut","at":"2026-10-12T21:11:04.70382+02:00"},{"action":"pause","at":"2026-10-12T21:11:56.520068+02:00"}]',e);
 r:=public.admin_formulaire_pointage(etok,e,j,ev,'Correction bureau',1,req);assert not (r->>'ok')::boolean,'employé interdit';
 r:=public.admin_formulaire_pointage(ctok,e,j,ev,'Correction bureau',1,req);assert not (r->>'ok')::boolean,'compta interdite';
 r:=public.admin_formulaire_pointage(atok,e,j,ev,'Correction bureau',1,req);assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;
 assert p.pointe_etat='termine' and public._pointe_total(p)=480 and p.pointe_version=2,'journée passée complétée';
 assert p.remarque='Correction bureau','remarque conservée';
 assert (select avant->1->>'action'='pause' and avant->0->>'at' like '%21:11:04%' from public.pointage_corrections where employe_id=e),'origine conservée';
 r:=public.admin_formulaire_pointage(atok,e,j,ev,'Correction bureau',1,req);assert (r->>'ok')::boolean,'rejeu';
 assert (select pointe_version=2 from public.pointages where employe_id=e and jour=j),'rejeu sans doublon';
 r:=public.admin_decider_heures(atok,e,j,480,'',md5(row_to_json(p)::text));assert (r->>'ok')::boolean,r::text;
 ev:=jsonb_set(ev,'{3,heure}','"16:30"');
 r:=public.admin_formulaire_pointage(atok,e,j,ev,'Nouvelle correction',2,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;
 assert not p.approuve and public._pointe_total(p)=450 and p.pointe_version=3,'modifiable après validation';
 r:=public.admin_formulaire_pointage(atok,e,j,ev,'Conflit',2,gen_random_uuid());assert not (r->>'ok')::boolean,'version périmée';
 r:=public.admin_formulaire_pointage(atok,e,j,'[{"action":"debut","heure":"17:00"},{"action":"fin","heure":"08:00"}]','Ordre invalide',3,gen_random_uuid());assert not (r->>'ok')::boolean,'chronologie contrôlée';
 assert (select pointe_version=3 from public.pointages where employe_id=e and jour=j),'échecs sans modification';
 -- Une seule demi-journée reste possible, avec suppression de la plage erronée.
 r:=public.admin_formulaire_pointage(atok,e,j,'[{"action":"debut","heure":"08:00"},{"action":"fin","heure":"12:00"}]','Matin uniquement',3,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;
 assert public._pointe_total(p)=240,'matin seul';
 r:=public.admin_decider_heures(atok,e,j,240,'',md5(row_to_json(p)::text));assert (r->>'ok')::boolean,r::text;
 r:=public.pointage_exporter(ctok,2026,10,array[e]);assert (r->>'ok')::boolean,r::text;
 assert r->'pointages'->0->>'remarque'='Matin uniquement','export corrigé';
 assert not exists(select 1 from public.pointage_corrections where employe_id=e and etat='attente'),'aucune demande bloquée';
 assert (select count(*)=3 from public.journal where acteur_id=a and action='pointage_correction_acceptee'),'journal attribué au bureau';
end $$;
rollback;
