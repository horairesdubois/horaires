begin;
do $$
declare a uuid:=gen_random_uuid();e uuid:=gen_random_uuid();co uuid:=gen_random_uuid();atok uuid:=gen_random_uuid();et uuid:=gen_random_uuid();ct uuid:=gen_random_uuid();
 j date:='2026-10-14';p public.pointages;r jsonb;version text;req uuid:=gen_random_uuid();
 ev jsonb:='[{"action":"debut","heure":"08:00:17"},{"action":"fin","heure":"12:00:38"}]';
begin
 assert not has_function_privilege('authenticated','public.admin_enregistrer_absence(uuid,uuid,date,text,text,jsonb,text,text,uuid)','EXECUTE'),'authenticated sans accès';
 assert has_function_privilege('anon','public.admin_enregistrer_absence(uuid,uuid,date,text,text,jsonb,text,text,uuid)','EXECUTE'),'RPC anon sous contrôle du jeton';
 insert into public.employes(id,prenom,pin_hash,role,pointage_actif) values(a,'Essai absence admin','test','admin',false),(e,'Essai absence employé','test','employe',true),(co,'Essai absence compta','test','compta',false);
 insert into public.sessions(token,employe_id) values(atok,a),(et,e),(ct,co);
 r:=public.admin_enregistrer_absence(et,e,j,'vacances','vacances','[]','',null,req);assert not (r->>'ok')::boolean,'employé refusé';
 r:=public.admin_enregistrer_absence(ct,e,j,'vacances','vacances','[]','',null,req);assert not (r->>'ok')::boolean,'compta refusée';
 r:=public.admin_enregistrer_absence(atok,e,j,'vacances','vacances','[]','Congé',null,req);assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;
 assert p.matin_type='vacances' and p.apm_type='vacances' and public._pointe_total(p)=0 and p.pointe_etat='termine','absence entière complète sans travail';
 version:=md5(row_to_json(p)::text);
 r:=public.admin_enregistrer_absence(atok,e,j,'vacances','vacances','[]','Congé',null,req);assert (r->>'ok')::boolean,'rejeu';
 assert (select pointe_version=p.pointe_version from public.pointages where employe_id=e and jour=j),'rejeu sans doublon';
 r:=public.admin_enregistrer_absence(atok,e,j,'maladie','maladie','[]','Congé',null,req);assert not (r->>'ok')::boolean,'rejeu altéré';
 r:=public.admin_enregistrer_absence(atok,e,j,'travail','maladie',ev,'Maladie après-midi',version,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;
 assert p.matin_type='travail' and p.apm_type='maladie' and public._pointe_total(p)=240 and p.pointe_etat='termine','matin travaillé conservé';
 assert p.pointe_evenements->0->>'at' like '%06:00:17%','secondes conservées';
 r:=public.admin_enregistrer_absence(atok,e,j,'accident','accident','[]','',version,gen_random_uuid());assert not (r->>'ok')::boolean,'version périmée';
 version:=md5(row_to_json(p)::text);
 r:=public.admin_enregistrer_absence(atok,e,j,'accident','accident',ev,'',version,gen_random_uuid());assert not (r->>'ok')::boolean,'pas de travail avec absence entière';
 r:=public.admin_enregistrer_absence(atok,e,j,'accident','accident','[]','',version,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 assert exists(select 1 from public.journal where acteur_id=a and detail->'origine'->0->>'action'='debut'),'pointages originaux dans historique';
 select * into p from public.pointages where employe_id=e and jour=j;
 r:=public.admin_decider_heures(atok,e,j,0,'',md5(row_to_json(p)::text));assert (r->>'ok')::boolean,r::text;
 r:=public.pointage_exporter_valides(ct,2026,10,array[e]);assert (r->>'ok')::boolean,r::text;
 assert r->'pointages'->0->>'matin_type'='accident','absence validée exportable';
 -- Le travail de la moitié restante pourra démarrer normalement aujourd'hui.
 r:=public.admin_enregistrer_absence(atok,e,(clock_timestamp() at time zone 'Europe/Zurich')::date,'vacances','travail','[]','',null,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.pointage_pointer(et,(clock_timestamp() at time zone 'Europe/Zurich')::date,'debut',1,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 assert (select matin_type='vacances' and pointe_etat='travail' from public.pointages where employe_id=e and jour=(clock_timestamp() at time zone 'Europe/Zurich')::date),'pointage de l’autre moitié et motif conservé';
 -- Une demi-journée planifiée reste pointable pour l'autre moitié.
 j:=(clock_timestamp() at time zone 'Europe/Zurich')::date+1;
 r:=public.admin_enregistrer_absence(atok,e,j,'vacances','travail','[]','',null,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 assert (select pointe_etat='vide' and pointe_evenements='[]'::jsonb from public.pointages where employe_id=e and jour=j),'demi-journée future ouverte';
 r:=public.admin_enregistrer_absence(atok,e,j+1,'invalide','travail','[]','',null,gen_random_uuid());assert not (r->>'ok')::boolean,'motif invalide';
 assert not exists(select 1 from public.pointages where employe_id=e and jour=j+1),'aucune écriture invalide';
 raise notice 'OK : droits, journée complète, demi-journée, secondes, historique, conflit, rejeu, futur et motifs';
end $$;
rollback;
