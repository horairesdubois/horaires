-- Écriture administrative atomique, sans circuit de demande pour le responsable.
create or replace function public.admin_pointage_enregistrer(
 p_token uuid,p_jour date,p_evenements jsonb,p_motif text,p_version integer,p_requete uuid,p_employe uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; r jsonb; c public.pointage_corrections; ident uuid;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 perform public._verrou_pointages(p_employe);
 p_motif:=coalesce(nullif(btrim(p_motif),''),'Modification directe par le back-office');
 -- Le sous-bloc annule aussi le traitement des demandes si les heures sont invalides.
 begin
  if not exists(select 1 from public.pointage_corrections where employe_id=p_employe and requete=p_requete) then
   for c in select * from public.pointage_corrections where employe_id=p_employe and jour=p_jour and etat='attente' loop
    r:=public.pointage_decider(p_token,c.id,false,'Remplacée par la saisie directe du back-office');
    if not coalesce((r->>'ok')::boolean,false) then raise exception '%',r->>'erreur'; end if;
   end loop;
  end if;
  r:=public.pointage_corriger(p_token,p_jour,p_evenements,p_motif,p_version,p_requete,p_employe);
  if not coalesce((r->>'ok')::boolean,false) then raise exception '%',r->>'erreur'; end if;
  ident:=(r->>'id')::uuid;
  select * into c from public.pointage_corrections where id=ident;
  if c.etat='attente' then
   r:=public.pointage_decider(p_token,ident,true,'Enregistrement direct du back-office');
   if not coalesce((r->>'ok')::boolean,false) then raise exception '%',r->>'erreur'; end if;
  elsif c.etat<>'acceptee' then raise exception 'Cette requête a déjà été refusée';
  end if;
  return jsonb_build_object('ok',true,'id',ident);
 exception when raise_exception then return jsonb_build_object('ok',false,'erreur',sqlerrm);
 end;
end $$;
revoke all on function public.admin_pointage_enregistrer(uuid,date,jsonb,text,integer,uuid,uuid) from public,authenticated;
grant execute on function public.admin_pointage_enregistrer(uuid,date,jsonb,text,integer,uuid,uuid) to anon;
