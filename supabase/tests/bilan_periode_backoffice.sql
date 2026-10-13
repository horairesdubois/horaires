begin;
do $$
declare a uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); autre uuid:=gen_random_uuid(); co uuid:=gen_random_uuid(); demo uuid:=gen_random_uuid();
 atok uuid:=gen_random_uuid(); etok uuid:=gen_random_uuid(); ctok uuid:=gen_random_uuid(); r jsonb; n integer;
begin
 insert into public.employes(id,prenom,pin_hash,role,demo) values(a,'Essai période admin','test','admin',false),(e,'Essai période salarié','test','employe',false),(autre,'Essai autre salarié','test','employe',false),(co,'Essai période compta','test','compta',false),(demo,'Essai période démo','test','employe',true);
 insert into public.sessions(token,employe_id,expire_le) values(atok,a,now()+interval '1 hour'),(etok,e,now()+interval '1 hour'),(ctok,co,now()+interval '1 hour');
 insert into public.pointages(employe_id,jour,matin_type,matin_debut,matin_fin,apm_type,apm_debut,apm_fin)
 select e,j,'travail',time '08:00',time '12:00','travail',time '13:00',time '17:00' from unnest(array[date '2026-08-20',date '2026-08-21',date '2026-09-20',date '2026-09-21']) j;
 insert into public.pointages(employe_id,jour) values(autre,'2026-08-21');
 select count(*) into n from public.pointages;
 r:=public.admin_bilan_periode(atok,e,'2026-08-21','2026-09-20');assert (r->>'ok')::boolean,r::text;
 assert jsonb_array_length(r->'pointages')=2,'bornes inclusives seulement';
 assert r->'pointages'->0->>'jour'='2026-08-21' and r->'pointages'->1->>'jour'='2026-09-20','ordre des journées';
 assert not exists(select 1 from jsonb_array_elements(r->'pointages') p where p->>'employe_id'<>e::text),'un seul salarié';
 assert r->>'aujourdhui'=((clock_timestamp() at time zone 'Europe/Zurich')::date)::text,'date serveur';
 r:=public.admin_bilan_periode(etok,e,'2026-08-21','2026-09-20');assert not (r->>'ok')::boolean,'employé interdit même pour lui-même';
 r:=public.admin_bilan_periode(ctok,e,'2026-08-21','2026-09-20');assert not (r->>'ok')::boolean,'fiduciaire interdite';
 r:=public.admin_bilan_periode(gen_random_uuid(),e,'2026-08-21','2026-09-20');assert not (r->>'ok')::boolean,'session invalide interdite';
 r:=public.admin_bilan_periode(atok,e,'2026-09-20','2026-08-21');assert not (r->>'ok')::boolean,'dates inversées';
 r:=public.admin_bilan_periode(atok,e,null,'2026-09-20');assert not (r->>'ok')::boolean,'date vide';
 r:=public.admin_bilan_periode(atok,demo,'2026-08-21','2026-09-20');assert not (r->>'ok')::boolean,'compte démo exclu';
 r:=public.admin_bilan_periode(atok,gen_random_uuid(),'2026-08-21','2026-09-20');assert not (r->>'ok')::boolean,'cible inconnue';
 r:=public.admin_bilan_periode(atok,e,'2026-10-01','2026-10-12');assert (r->>'ok')::boolean and jsonb_array_length(r->'pointages')=0,'période vide';
 assert (select count(*)=n from public.pointages),'lecture sans écriture';
 assert has_function_privilege('anon','public.admin_bilan_periode(uuid,uuid,date,date)','EXECUTE'),'RPC accessible avec contrôle interne';
 assert not has_function_privilege('authenticated','public.admin_bilan_periode(uuid,uuid,date,date)','EXECUTE'),'pas de droit public implicite';
end $$;
rollback;
