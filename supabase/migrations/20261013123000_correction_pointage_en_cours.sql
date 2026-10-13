create or replace function public.pointage_corriger(p_token uuid,p_jour date,p_evenements jsonb,p_motif text,p_version integer,p_requete uuid,p_employe uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acteur public.employes; cible uuid; p public.pointages; id_demande uuid; v_analyse jsonb; ancien public.pointage_corrections;
begin
 acteur:=public._auth(p_token); cible:=coalesce(p_employe,acteur.id);
 if acteur.id is null or acteur.role='compta' or (cible<>acteur.id and acteur.role<>'admin') then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 if not exists(select 1 from public.employes where id=cible and role='employe' and pointage_actif) then return jsonb_build_object('ok',false,'erreur','Pointage non activé'); end if;
 -- Les heures saisies sur téléphone sont interprétées dans le fuseau de l'entreprise.
 begin
  select jsonb_agg(case when e ? 'heure' then jsonb_build_object('action',e->>'action','at',(p_jour+(e->>'heure')::time) at time zone 'Europe/Zurich') else e end order by n)
   into p_evenements from jsonb_array_elements(p_evenements) with ordinality x(e,n);
 exception when others then return jsonb_build_object('ok',false,'erreur','Heures invalides'); end;
 perform public._verrou_pointages(cible);
 select * into ancien from public.pointage_corrections where employe_id=cible and requete=p_requete;
 if found then
  if ancien.jour<>p_jour or ancien.proposition is distinct from p_evenements or ancien.motif is distinct from btrim(p_motif) then return jsonb_build_object('ok',false,'erreur','Requête déjà utilisée'); end if;
  return jsonb_build_object('ok',true,'id',ancien.id);
 end if;
 if p_requete is null or p_jour is null or p_jour<date '2026-10-12' or p_jour>(clock_timestamp() at time zone 'Europe/Zurich')::date or length(btrim(coalesce(p_motif,''))) not between 5 and 500 then return jsonb_build_object('ok',false,'erreur','Vérifiez la date et indiquez un motif de 5 à 500 caractères'); end if;
 select * into p from public.pointages where employe_id=cible and jour=p_jour for update;
 if p.id is not null and p.pointe_evenements is null then return jsonb_build_object('ok',false,'erreur','Utilisez la correction de la feuille manuelle pour cette journée'); end if;
 if coalesce(p.pointe_version,0) is distinct from p_version then return jsonb_build_object('ok',false,'erreur','Les pointages ont changé. Rechargez avant de corriger.'); end if;
 if exists(select 1 from public.pointage_corrections where employe_id=cible and jour=p_jour and etat='attente') then return jsonb_build_object('ok',false,'erreur','Une correction est déjà en attente'); end if;
 begin v_analyse:=public._pointe_analyser(p_jour,p_evenements); exception when others then return jsonb_build_object('ok',false,'erreur',sqlerrm); end;
 if v_analyse->>'etat'<>'termine' and acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','La correction doit décrire la journée complète, jusqu’à la fin'); end if;
 insert into public.pointage_corrections(employe_id,jour,version,avant,proposition,motif,auteur,requete)
 values(cible,p_jour,p_version,coalesce(p.pointe_evenements,'[]'),p_evenements,btrim(p_motif),acteur.id,p_requete) returning id into id_demande;
 if not public._demo(cible) then perform public._journal(acteur.id,'pointage_correction_demandee',p_jour::text,jsonb_build_object('employe',(select prenom from public.employes where id=cible),'demande',id_demande,'origine',coalesce(p.pointe_evenements,'[]'),'proposition',p_evenements,'motif',btrim(p_motif))); end if;
 return jsonb_build_object('ok',true,'id',id_demande);
end $$;


-- Adaptateur du formulaire matin/après-midi vers les corrections existantes.
-- Conserve les événements, reçus et historiques ; ne change aucun helper.
create or replace function public.admin_formulaire_pointage(
 p_token uuid,p_employe uuid,p_jour date,p_evenements jsonb,p_remarque text,p_version integer,p_requete uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; r jsonb; c public.pointage_corrections; p public.pointages; attendu text; dernier text;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 perform public._verrou_pointages(p_employe);
 -- Le rejeu ne doit pas réappliquer une remarque après une correction ultérieure.
 select * into c from public.pointage_corrections where employe_id=p_employe and requete=p_requete;
 select * into p from public.pointages where employe_id=p_employe and jour=p_jour;
 if c.id is null and p.pointe_etat in ('travail','pause') then
  dernier:=p_evenements->-1->>'action';
  attendu:=case when p.pointe_etat='pause' then 'pause' else case when jsonb_array_length(p.pointe_evenements)=1 then 'debut' else 'reprise' end end;
  if dernier is distinct from attendu or jsonb_array_length(p_evenements)<>jsonb_array_length(p.pointe_evenements) or
   exists(select 1 from jsonb_array_elements(p_evenements) with ordinality e(v,n) where v->>'action' is distinct from p.pointe_evenements->(n::int-1)->>'action') then
   return jsonb_build_object('ok',false,'erreur','Corrigez les heures existantes sans changer l’état de la journée en cours.');
  end if;
 end if;
 r:=public.admin_pointage_enregistrer(p_token,p_jour,p_evenements,'Saisie back-office : '||coalesce(nullif(left(btrim(p_remarque),200),''),'heures vérifiées'),p_version,p_requete,p_employe);
 if not coalesce((r->>'ok')::boolean,false) or c.id is not null then return r; end if;
 perform set_config('horaires.acteur',acteur.id::text,true);
 update public.pointages set remarque=left(btrim(coalesce(p_remarque,'')),200) where employe_id=p_employe and jour=p_jour;
 return r;
end $$;
revoke all on function public.admin_formulaire_pointage(uuid,uuid,date,jsonb,text,integer,uuid) from public,authenticated;
grant execute on function public.admin_formulaire_pointage(uuid,uuid,date,jsonb,text,integer,uuid) to anon;
