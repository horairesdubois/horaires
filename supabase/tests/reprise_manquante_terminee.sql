-- Aucun changement conservé : essais de l'API existante utilisée par la ligne Reprise.
begin;
do $$
declare e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); t uuid:=gen_random_uuid();
 j date:=(clock_timestamp() at time zone 'Europe/Zurich')::date;
 r jsonb; avant jsonb; proposition jsonb; req uuid:=gen_random_uuid();
begin
 insert into public.employes(id,prenom,nom,pin_hash,role,pointage_actif)
 values(e,'Essai reprise','Tech','test','employe',true),(a,'Essai reprise','Admin','test','admin',false);
 insert into public.sessions(token,employe_id,expire_le) values(t,a,now()+interval '1 hour');
 r:=public.admin_pointer(t,e,j,'debut','00:01',0,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(t,e,j,'pause','00:02',1,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 r:=public.admin_pointer(t,e,j,'fin','00:04',2,gen_random_uuid());assert (r->>'ok')::boolean,r::text;
 avant:=r->'evenements';
 proposition:=jsonb_insert(avant,'{2}',jsonb_build_object('action','reprise','heure','00:01:30'));
 r:=public.admin_pointage_enregistrer(t,j,proposition,'Reprise manquante ajoutée par le back-office',3,req,e);
 assert not (r->>'ok')::boolean,'reprise avant pause refusée';
 proposition:=jsonb_insert(avant,'{2}',jsonb_build_object('action','reprise','heure','00:03'));
 r:=public.admin_pointage_enregistrer(t,j,proposition,'Reprise manquante ajoutée par le back-office',2,req,e);
 assert not (r->>'ok')::boolean,'version périmée refusée';
 r:=public.admin_pointage_enregistrer(t,j,proposition,'Reprise manquante ajoutée par le back-office',3,req,e);
 assert (r->>'ok')::boolean,r::text;
 r:=public.pointage_lire(t,j,e);
 assert r->>'etat'='termine' and (r->>'version')::int=4;
 assert ((r->'evenements')-2)=avant,'autres événements identiques';
 r:=public.admin_pointage_enregistrer(t,j,proposition,'Reprise manquante ajoutée par le back-office',3,req,e);
 assert (r->>'ok')::boolean,r::text;
 assert (select pointe_version from public.pointages where employe_id=e and jour=j)=4,'rejeu sans doublon';
 assert exists(select 1 from public.pointage_corrections where requete=req and auteur=a and etat='acceptee'),'auteur admin et historique conservés';
end $$;
rollback;
