-- Adaptateur du formulaire matin/après-midi vers les corrections existantes.
-- Conserve les événements, reçus et historiques ; ne change aucun helper.
create or replace function public.admin_formulaire_pointage(
 p_token uuid,p_employe uuid,p_jour date,p_evenements jsonb,p_remarque text,p_version integer,p_requete uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; r jsonb; c public.pointage_corrections;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 perform public._verrou_pointages(p_employe);
 -- Le rejeu ne doit pas réappliquer une remarque après une correction ultérieure.
 select * into c from public.pointage_corrections where employe_id=p_employe and requete=p_requete;
 r:=public.admin_pointage_enregistrer(p_token,p_jour,p_evenements,'Saisie back-office : '||coalesce(nullif(left(btrim(p_remarque),200),''),'heures vérifiées'),p_version,p_requete,p_employe);
 if not coalesce((r->>'ok')::boolean,false) or c.id is not null then return r; end if;
 perform set_config('horaires.acteur',acteur.id::text,true);
 update public.pointages set remarque=left(btrim(coalesce(p_remarque,'')),200) where employe_id=p_employe and jour=p_jour;
 return r;
end $$;
revoke all on function public.admin_formulaire_pointage(uuid,uuid,date,jsonb,text,integer,uuid) from public,authenticated;
grant execute on function public.admin_formulaire_pointage(uuid,uuid,date,jsonb,text,integer,uuid) to anon;
