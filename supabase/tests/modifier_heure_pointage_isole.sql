begin;
do $$
declare e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); f uuid:=gen_random_uuid();
 et uuid:=gen_random_uuid(); atok uuid:=gen_random_uuid(); ft uuid:=gen_random_uuid(); j date:=(clock_timestamp() at time zone 'Europe/Zurich')::date;
 r jsonb; ev jsonb; avant jsonb; req uuid:=gen_random_uuid(); i integer;
begin
 insert into public.employes(id,prenom,nom,pin_hash,role,pointage_actif) values(e,'Essai quatre étapes','Tech','test','employe',true),(a,'Essai quatre étapes','Admin','test','admin',false),(f,'Essai quatre étapes','Compta','test','compta',false);
 insert into public.sessions(token,employe_id,expire_le) values(et,e,now()+interval '1 hour'),(atok,a,now()+interval '1 hour'),(ft,f,now()+interval '1 hour');
 r:=public.admin_pointer(atok,e,j,'debut','00:01:17',0,gen_random_uuid());assert (r->>'ok')::boolean,r::text;avant:=r->'evenements';
 r:=public.admin_modifier_heure_pointage(et,e,j,0,'00:00',1,req);assert not (r->>'ok')::boolean,'employé refusé';
 r:=public.admin_modifier_heure_pointage(ft,e,j,0,'00:00',1,req);assert not (r->>'ok')::boolean,'compta refusée';
 r:=public.admin_modifier_heure_pointage(null,e,j,0,'00:00',1,req);assert not (r->>'ok')::boolean,'session requise';
 r:=public.admin_modifier_heure_pointage(atok,e,j,0,'25:00',1,req);assert not (r->>'ok')::boolean,'heure invalide';
 r:=public.admin_modifier_heure_pointage(atok,e,j,1,'00:00',1,req);assert not (r->>'ok')::boolean,'indice inexistant';
 r:=public.admin_modifier_heure_pointage(atok,e,j,0,'00:00',0,req);assert r->>'code'='conflit','version périmée';
 r:=public.admin_modifier_heure_pointage(atok,e,j,0,'00:00:32',1,req);assert (r->>'ok')::boolean,r::text;
 assert r->>'etat'='travail' and jsonb_array_length(r->'evenements')=1,'modifier le début laisse uniquement le début';
 assert r->'evenements'->0->>'id'=avant->0->>'id','identifiant conservé';
 r:=public.pointage_pointer(et,j,'pause',2,gen_random_uuid());assert (r->>'ok')::boolean and r->>'etat'='pause',r::text;
 r:=public.admin_modifier_heure_pointage(atok,e,j,0,'00:00:32',1,req);assert (r->>'doublon')::boolean and jsonb_array_length(r->'evenements')=2,'rejeu ne supprime pas pause technicien';
 r:=public.admin_modifier_heure_pointage(atok,e,j,0,'00:00:33',1,req);assert not (r->>'ok')::boolean,'rejeu altéré refusé';
 r:=public.admin_modifier_heure_pointage(atok,e,j,1,'00:02:20',3,gen_random_uuid());assert (r->>'ok')::boolean and r->>'etat'='pause',r::text;
 r:=public.admin_pointer(atok,e,j,'reprise','00:03:30',4,gen_random_uuid());assert (r->>'ok')::boolean and r->>'etat'='travail',r::text;
 r:=public.admin_pointer(atok,e,j,'fin','00:04:40',5,gen_random_uuid());assert (r->>'ok')::boolean and r->>'etat'='termine',r::text;
 -- Chaque correction ne touche que sa borne ; toutes les autres restent exactes.
 for i in 0..3 loop
  avant:=r->'evenements';
  r:=public.admin_modifier_heure_pointage(atok,e,j,i,'00:0'||i::text||':45',(r->>'version')::int,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
  assert r->>'etat'='termine','corriger une borne ne rouvre pas une journée terminée';
  assert ((r->'evenements'->i)-'at')=((avant->i)-'at'),'action et identifiant inchangés';
  assert not exists(select 1 from jsonb_array_elements(avant) with ordinality x(v,n) where n<>i+1 and v is distinct from r->'evenements'->(n::int-1)),'autres événements inchangés';
 end loop;
 r:=public.admin_modifier_heure_pointage(atok,e,j,1,'00:00',10,gen_random_uuid());assert not (r->>'ok')::boolean,'pas de chevauchement';
 assert not exists(select 1 from public.pointage_corrections where employe_id=e and auteur<>a),'corrections attribuées au back-office';
end $$;
rollback;
