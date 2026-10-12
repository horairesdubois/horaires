-- Essais sans persistance : employés, sessions et journaux sont annulés.
begin;
do $$
declare e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); et uuid:=gen_random_uuid(); atok uuid:=gen_random_uuid(); ct uuid:=gen_random_uuid();
 j date:=(clock_timestamp() at time zone 'Europe/Zurich')::date; r jsonb; ev jsonb; ev2 jsonb; p public.pointages; req uuid:=gen_random_uuid(); demande uuid; n int;
begin
 insert into public.employes(id,prenom,nom,pin_hash,role,pointage_actif) values(e,'Essai','Technicien','test','employe',true),(a,'Essai','Admin','test','admin',false),(c,'Essai','Compta','test','compta',false);
 insert into public.sessions(token,employe_id,expire_le) values(et,e,now()+interval '1 hour'),(atok,a,now()+interval '1 hour'),(ct,c,now()+interval '1 hour');
 r:=public.pointage_pointer(et,j,'debut',0,req); assert (r->>'ok')::boolean,r::text;
 r:=public.pointage_pointer(et,j,'debut',0,req); assert (r->>'doublon')::boolean,'rejeu réseau';
 r:=public.pointage_pointer(et,j,'debut',0,gen_random_uuid()); assert not (r->>'ok')::boolean,'concurrence version';
 r:=public.pointage_pointer(et,j,'pause',1,gen_random_uuid()); assert not (r->>'ok')::boolean,'double clic immédiat';
 select * into p from public.pointages where employe_id=e and jour=j;
 assert jsonb_array_length(p.pointe_evenements)=1,'un seul événement';
 begin perform public.admin_approuver(atok,e,extract(year from j)::int,extract(month from j)::int,j,true); raise exception 'test approbation attendait refus'; exception when raise_exception then assert sqlerrm like '%Terminez%',sqlerrm; end;
 r:=public.pointage_lire(ct,j,e); assert (r->>'ok')::boolean and r->'corrections'='[]'::jsonb,'compta lit les heures sans historique des corrections';
 r:=public.pointage_lire(et,j,a); assert not (r->>'ok')::boolean,'pas de lecture autre employé';
 ev:=jsonb_build_array(
  jsonb_build_object('action','debut','at',(j+time '01:00') at time zone 'Europe/Zurich'),
  jsonb_build_object('action','pause','at',(j+time '03:00') at time zone 'Europe/Zurich'),
  jsonb_build_object('action','reprise','at',(j+time '03:15') at time zone 'Europe/Zurich'),
  jsonb_build_object('action','pause','at',(j+time '05:00') at time zone 'Europe/Zurich'),
  jsonb_build_object('action','reprise','at',(j+time '05:45') at time zone 'Europe/Zurich'),
  jsonb_build_object('action','fin','at',(j+time '09:00') at time zone 'Europe/Zurich'));
 req:=gen_random_uuid();r:=public.pointage_corriger(et,j,ev,'Oubli du pointage de la matinée',1,req);assert (r->>'ok')::boolean,r::text;demande:=(r->>'id')::uuid;
 r:=public.pointage_corriger(et,j,ev,'Oubli du pointage de la matinée',1,req);assert (r->>'ok')::boolean,'correction idempotente';
 r:=public.pointage_decider(et,demande,true,'');assert not (r->>'ok')::boolean,'pas auto approbation';
 r:=public.pointage_decider(atok,demande,true,'Vérifié');assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;
 assert public._pointe_total(p)=420,'7 heures avec deux pauses';assert p.pointe_etat='termine';assert not p.approuve;
 assert p.pointe_segments='[[60,180],[195,300],[345,540]]'::jsonb,p.pointe_segments::text;
 r:=public.admin_decider_heures(atok,e,j,400,'20 minutes refusées',md5(row_to_json(p)::text));assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;assert p.approuve and p.minutes_refusees=20;
 ev2:=jsonb_set(ev,'{5,at}',to_jsonb((j+time '08:50') at time zone 'Europe/Zurich'));
 r:=public.pointage_corriger(et,j,ev2,'Fin réelle dix minutes plus tôt',p.pointe_version,gen_random_uuid());assert (r->>'ok')::boolean,r::text;demande:=(r->>'id')::uuid;
 r:=public.pointage_decider(atok,demande,true,'Rectification contrôlée');assert (r->>'ok')::boolean,r::text;
 select * into p from public.pointages where employe_id=e and jour=j;assert public._pointe_total(p)=410;assert not p.approuve and p.minutes_refusees=0,'correction invalide ancienne décision';
 assert (select avant=ev from public.pointage_corrections where id=demande),'original conservé';
 assert (select count(*)>=2 from public.journal where acteur_id=e and action='pointage_correction_demandee'),'demandes tracées';
 assert (select count(*)=2 from public.journal where acteur_id=a and action='pointage_correction_acceptee'),'décisions attribuées';
 r:=public.enregistrer_jour(et,j,'travail','08:00','12:00','travail','13:00','17:00','');assert not (r->>'ok')::boolean,'pas de contournement manuel';
 begin perform public.admin_supprimer_jour(atok,e,j);raise exception 'test suppression attendait refus';exception when raise_exception then assert sqlerrm like '%ne se suppriment%',sqlerrm;end;
 begin perform public._pointe_analyser(j,jsonb_build_array(ev->0,ev->2));raise exception 'ordre accepté à tort';exception when raise_exception then assert sqlerrm like '%Ordre invalide%',sqlerrm;end;
 r:=public._pointe_analyser(j,jsonb_build_array(ev->0,ev->1,jsonb_build_object('action','fin','at',(j+time '03:30') at time zone 'Europe/Zurich')));assert r->>'etat'='termine';assert r->'segments'='[[60,180]]'::jsonb,'fin pendant pause';
 assert not has_function_privilege('anon','public._pointe_ecrire(uuid,date,jsonb,uuid)','execute'),'helper inaccessible';
 assert not has_table_privilege('anon','public.pointage_corrections','select'),'table inaccessible';
 r:=public.pointage_exporter(et,extract(year from j)::int,extract(month from j)::int,array[e]);assert not (r->>'ok')::boolean,'export réservé admin et compta';
 r:=public.pointage_exporter(ct,extract(year from j)::int,extract(month from j)::int,array[e]);assert (r->>'ok')::boolean;assert jsonb_array_length(r->'pointages')=1;
 ev2:='[{"action":"debut","heure":"01:00:17"},{"action":"fin","heure":"08:45:38"}]';req:=gen_random_uuid();
 r:=public.pointage_corriger(et,j,ev2,'Correction avec les heures du téléphone',p.pointe_version,req);assert (r->>'ok')::boolean,r::text;demande:=(r->>'id')::uuid;
 r:=public.pointage_corriger(et,j,ev2,'Correction avec les heures du téléphone',p.pointe_version,req);assert (r->>'ok')::boolean,'rejeu heures locales';
 r:=public.pointage_exporter(ct,extract(year from j)::int,extract(month from j)::int,array[e]);assert not (r->>'ok')::boolean,'export bloqué correction';
 r:=public.pointage_decider(atok,demande,false,'Heures à vérifier');assert (r->>'ok')::boolean;
 r:=public._pointe_analyser(date '2026-03-29','[{"action":"debut","at":"2026-03-29T01:30:00+01:00"},{"action":"fin","at":"2026-03-29T03:30:00+02:00"}]');assert r->'segments'='[[90,120],[180,210]]'::jsonb,'changement heure été';
 r:=public._pointe_analyser(date '2025-10-26','[{"action":"debut","at":"2025-10-26T01:30:00+02:00"},{"action":"fin","at":"2025-10-26T03:30:00+01:00"}]');assert r->'segments'='[[90,180],[120,210]]'::jsonb,'changement heure hiver';
 raise notice 'OK : idempotence, concurrence, permissions, pauses multiples, correction, décision partielle, historique, protection des anciennes saisies';
end $$;
rollback;
