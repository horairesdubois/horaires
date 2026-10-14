begin;
do $$
declare e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); f uuid:=gen_random_uuid(); autre uuid:=gen_random_uuid();
 et uuid:=gen_random_uuid(); atok uuid:=gen_random_uuid(); ft uuid:=gen_random_uuid(); j date:=(clock_timestamp() at time zone 'Europe/Zurich')::date;
 r jsonb; p public.pointages; req uuid:=gen_random_uuid(); original jsonb;
begin
 insert into public.employes(id,prenom,nom,pin_hash,role,pointage_actif) values(e,'Essai unitaire','Tech','test','employe',true),(a,'Essai unitaire','Admin','test','admin',false),(f,'Essai unitaire','Fiduciaire','test','compta',false),(autre,'Essai unitaire','Autre','test','employe',true);
 insert into public.sessions(token,employe_id,expire_le) values(et,e,now()+interval '1 hour'),(atok,a,now()+interval '1 hour'),(ft,f,now()+interval '1 hour');
 r:=public.admin_pointer(et,e,j,'debut','00:01',0,req);assert not (r->>'ok')::boolean,'employé interdit';
 r:=public.admin_pointer(ft,e,j,'debut','00:01',0,req);assert not (r->>'ok')::boolean,'fiduciaire interdite';
 r:=public.admin_pointer(null,e,j,'debut','00:01',0,req);assert not (r->>'ok')::boolean,'session obligatoire';
 r:=public.admin_pointer(atok,e,j,'pause','00:01',0,req);assert not (r->>'ok')::boolean,'pause sans début interdite';
 r:=public.admin_pointer(atok,e,j,'debut','25:00',0,req);assert not (r->>'ok')::boolean,'heure invalide';
 r:=public.admin_pointer(atok,e,j+1,'debut','00:01',0,req);assert not (r->>'ok')::boolean,'jour futur';
 r:=public.admin_pointer(atok,e,j,'debut',to_char((clock_timestamp() at time zone 'Europe/Zurich')+interval '1 minute','HH24:MI:SS'),0,req);assert not (r->>'ok')::boolean,'heure future';
 r:=public.admin_pointer(atok,e,j,'debut','00:01:17',0,req);assert (r->>'ok')::boolean,r::text;assert r->>'etat'='travail','journée ouverte';original:=r->'evenements'->0;
 r:=public.admin_pointer(atok,e,j,'debut','00:01:17',0,req);assert (r->>'doublon')::boolean,'rejeu sans doublon';
 r:=public.admin_pointer(atok,e,j,'debut','00:02',0,req);assert not (r->>'ok')::boolean,'requête altérée';
 r:=public.admin_pointer(atok,e,j,'pause','00:02',0,gen_random_uuid());assert r->>'code'='conflit','version obsolète';
 r:=public.admin_pointer(atok,e,j,'debut','00:02',1,gen_random_uuid());assert not (r->>'ok')::boolean,'deux débuts interdits';
 r:=public.admin_pointer(atok,e,j,'pause','00:01',1,gen_random_uuid());assert not (r->>'ok')::boolean,'chronologie';
 r:=public.admin_pointer(atok,e,j,'pause','00:02',1,gen_random_uuid());assert (r->>'ok')::boolean,r::text;assert r->>'etat'='pause','pause isolée';assert r->'evenements'->0=original,'secondes et identifiant conservés';
 r:=public.pointage_pointer(et,j,'reprise',2,gen_random_uuid());assert (r->>'ok')::boolean,r::text;assert r->>'etat'='travail','technicien continue après pause admin';
 r:=public.admin_pointer(atok,e,j,'debut','00:01:17',0,req);assert (r->>'ok')::boolean and jsonb_array_length(r->'evenements')=3,'rejeu conserve suite technicien';
 assert not exists(select 1 from public.pointages where employe_id=autre),'autre technicien intact';
 assert (select count(*)=2 from public.pointage_corrections where employe_id=e and etat='acceptee' and auteur=a),'auteur back-office tracé';
 -- La suite complète, y compris la fin depuis une pause, sur un autre technicien.
 r:=public.admin_pointer(atok,autre,j,'debut','00:01',0,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(atok,autre,j,'pause','00:02',1,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(atok,autre,j,'reprise','00:03',2,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(atok,autre,j,'pause','00:04',3,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(atok,autre,j,'fin','00:05',4,gen_random_uuid());assert (r->>'ok')::boolean and r->>'etat'='termine',r::text;
 r:=public.admin_pointer(atok,autre,j,'reprise','00:06',5,gen_random_uuid());assert not (r->>'ok')::boolean,'terminée protégée';
 -- Un jour passé peut aussi être régularisé.
 r:=public.admin_pointer(atok,autre,j-1,'debut','08:00',0,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(atok,e,j,'fin','00:04',3,gen_random_uuid());assert not (r->>'ok')::boolean,'heure antérieure à reprise réelle';
 assert not has_function_privilege('authenticated','public.admin_pointer(uuid,uuid,date,text,text,integer,uuid)','EXECUTE'),'grant limité';
end $$;
do $$
declare e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); et uuid:=gen_random_uuid(); atok uuid:=gen_random_uuid(); j date:=(clock_timestamp() at time zone 'Europe/Zurich')::date; r jsonb;
begin
 insert into public.employes(id,prenom,nom,pin_hash,role,pointage_actif) values(e,'Essai relais','Tech','test','employe',true),(a,'Essai relais','Admin','test','admin',false);
 insert into public.sessions(token,employe_id,expire_le) values(et,e,now()+interval '1 hour'),(atok,a,now()+interval '1 hour');
 r:=public.admin_pointer(atok,e,j,'debut','00:01',0,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.pointage_pointer(et,j,'debut',0,gen_random_uuid());assert r->>'code'='conflit','ancien écran technicien ne crée pas de doublon';
 r:=public.pointage_lire(et,j);assert r->>'etat'='travail','téléphone au travail après début admin';
 r:=public.pointage_pointer(et,j,'pause',1,gen_random_uuid());assert (r->>'ok')::boolean and r->>'etat'='pause',r::text;
 insert into public.pointages(employe_id,jour,matin_type,apm_type) values(e,j-1,'travail','travail');
 r:=public.admin_pointer(atok,e,j-1,'debut','08:00',0,gen_random_uuid());assert not (r->>'ok')::boolean,'saisie manuelle protégée';
 r:=public.admin_pointer(atok,a,j,'debut','00:01',0,gen_random_uuid());assert not (r->>'ok')::boolean,'cible non technicien interdite';
end $$;
rollback;
