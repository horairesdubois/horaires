-- Absences sur journées pointées ou encore vides. Aucun horaire réel n'est
-- modifié par la migration : seules les futures actions explicites du bureau écrivent.
create or replace function public.admin_enregistrer_absence(
 p_token uuid,p_employe uuid,p_jour date,p_matin_type text,p_apm_type text,
 p_evenements jsonb,p_remarque text,p_version text,p_requete uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; p public.pointages; apres public.pointages;
 events jsonb; resultat jsonb; recu public.pointage_recus; signature text; ancien text;
 types text[]:=array['travail','vacances','maladie','accident','ferie','armee','ecole','conge_np','autre'];
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 if not exists(select 1 from public.employes where id=p_employe and role='employe' and pointage_actif) then
  return jsonb_build_object('ok',false,'erreur','Employé avec pointage introuvable'); end if;
 if p_requete is null or p_jour is null or p_jour<date '2020-01-01' or p_jour>date '2100-12-31' or
  p_matin_type is null or p_apm_type is null or not(p_matin_type=any(types)) or not(p_apm_type=any(types)) then
  return jsonb_build_object('ok',false,'erreur','Date ou motif d’absence invalide'); end if;
 if p_evenements is null or jsonb_typeof(p_evenements)<>'array' then return jsonb_build_object('ok',false,'erreur','Pointages invalides'); end if;
 -- La requête complète sert de reçu : un rejeu ne réécrit pas une décision ultérieure.
 signature:='absence:'||md5(jsonb_build_array(p_jour,p_matin_type,p_apm_type,p_evenements,p_remarque,p_version)::text);
 perform public._verrou_pointages(p_employe);
 select * into recu from public.pointage_recus where employe_id=p_employe and requete=p_requete;
 if found then
  if recu.jour<>p_jour or recu.action<>signature then return jsonb_build_object('ok',false,'erreur','Requête déjà utilisée'); end if;
  return jsonb_build_object('ok',true);
 end if;
 select * into p from public.pointages where employe_id=p_employe and jour=p_jour for update;
 if (case when p.id is null then null else md5(row_to_json(p)::text) end) is distinct from p_version then
  return jsonb_build_object('ok',false,'code','conflit','erreur','La journée a changé. Fermez puis rouvrez-la avant d’enregistrer.'); end if;
 if p.id is not null and p.pointe_evenements is null then return jsonb_build_object('ok',false,'erreur','Utilisez les statuts du formulaire de cette journée manuelle'); end if;
 if exists(select 1 from public.pointage_corrections where employe_id=p_employe and jour=p_jour and etat='attente') then
  return jsonb_build_object('ok',false,'erreur','Traitez la demande de correction en attente avant de modifier l’absence'); end if;
 begin
  select coalesce(jsonb_agg(case when e ? 'heure' then jsonb_build_object('action',e->>'action','at',(p_jour+(e->>'heure')::time) at time zone 'Europe/Zurich') else e end order by n),'[]')
   into events from jsonb_array_elements(p_evenements) with ordinality x(e,n);
  resultat:=public._pointe_analyser(p_jour,events);
 exception when others then return jsonb_build_object('ok',false,'erreur','Heures invalides : '||sqlerrm); end;
 if jsonb_array_length(events)>0 and resultat->>'etat'<>'termine' then
  return jsonb_build_object('ok',false,'erreur','Complétez les heures travaillées avant d’enregistrer l’absence'); end if;
 if p_matin_type<>'travail' and p_apm_type<>'travail' and jsonb_array_length(events)>0 then
  return jsonb_build_object('ok',false,'erreur','Une journée entièrement absente ne peut pas contenir des heures travaillées'); end if;
 perform public._pointe_ecrire(p_employe,p_jour,events,acteur.id);
 ancien:=coalesce(current_setting('horaires.pointe_ecriture',true),'');
 perform set_config('horaires.pointe_ecriture','1',true);
 update public.pointages set matin_type=p_matin_type,apm_type=p_apm_type,
  matin_debut=null,matin_fin=null,apm_debut=null,apm_fin=null,
  remarque=left(btrim(coalesce(p_remarque,'')),200),
  pointe_etat=case when p_matin_type<>'travail' and p_apm_type<>'travail' then 'termine' else pointe_etat end
 where employe_id=p_employe and jour=p_jour returning * into apres;
 perform set_config('horaires.pointe_ecriture',ancien,true);
 insert into public.pointage_recus(employe_id,requete,jour,action) values(p_employe,p_requete,p_jour,signature);
 if not public._demo(p_employe) then
  perform public._journal(acteur.id,'modification',p_jour::text,jsonb_build_object(
   'employe',(select prenom from public.employes where id=p_employe),'motif','Absence enregistrée par le back-office',
   'avant',to_jsonb(p),'apres',to_jsonb(apres),'origine',coalesce(p.pointe_evenements,'[]'),'proposition',events));
 end if;
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.admin_enregistrer_absence(uuid,uuid,date,text,text,jsonb,text,text,uuid) from public,authenticated;
grant execute on function public.admin_enregistrer_absence(uuid,uuid,date,text,text,jsonb,text,text,uuid) to anon;
