-- Corriger une seule heure sans changer les actions ni leurs identifiants.
create or replace function public.admin_modifier_heure_pointage(
 p_token uuid,p_employe uuid,p_jour date,p_indice integer,p_heure text,p_version integer,p_requete uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; p public.pointages; c public.pointage_corrections;
 events jsonb; r jsonb; heure timestamptz; motif text;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 if not exists(select 1 from public.employes where id=p_employe and role='employe' and pointage_actif) then return jsonb_build_object('ok',false,'erreur','Pointage non activé pour ce technicien'); end if;
 if p_requete is null or p_version is null or p_indice is null or p_indice<0 or p_jour is null or p_jour<date '2026-10-12' or p_jour>(clock_timestamp() at time zone 'Europe/Zurich')::date or p_heure is null or p_heure!~'^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' then
  return jsonb_build_object('ok',false,'erreur','Vérifiez la date, le pointage et son heure');
 end if;
 heure:=(p_jour+p_heure::time) at time zone 'Europe/Zurich';
 motif:='Heure du pointage '||(p_indice+1)::text||' corrigée par le back-office';
 perform public._verrou_pointages(p_employe);
 select * into c from public.pointage_corrections where employe_id=p_employe and requete=p_requete;
 if found then
  if c.auteur is distinct from acteur.id or c.jour is distinct from p_jour or c.version is distinct from p_version or c.motif is distinct from motif or p_indice>=jsonb_array_length(c.avant) or c.proposition is distinct from jsonb_set(c.avant,array[p_indice::text,'at'],to_jsonb(heure)) or c.etat<>'acceptee' then
   return jsonb_build_object('ok',false,'erreur','Requête déjà utilisée pour une autre correction');
  end if;
  return public.pointage_lire(p_token,p_jour,p_employe)||jsonb_build_object('doublon',true);
 end if;
 select * into p from public.pointages where employe_id=p_employe and jour=p_jour for update;
 if coalesce(p.pointe_version,0) is distinct from p_version then return jsonb_build_object('ok',false,'code','conflit','erreur','Un pointage a changé entre-temps. Actualisez avant de continuer.'); end if;
 if p.pointe_evenements is null or p_indice>=jsonb_array_length(p.pointe_evenements) then return jsonb_build_object('ok',false,'erreur','Pointage introuvable. Actualisez la journée.'); end if;
 if exists(select 1 from public.pointage_corrections where employe_id=p_employe and jour=p_jour and etat='attente') then return jsonb_build_object('ok',false,'erreur','Traitez d’abord la correction en attente pour cette journée.'); end if;
 events:=jsonb_set(p.pointe_evenements,array[p_indice::text,'at'],to_jsonb(heure));
 r:=public.admin_pointage_enregistrer(p_token,p_jour,events,motif,p_version,p_requete,p_employe);
 if not coalesce((r->>'ok')::boolean,false) then return r; end if;
 return public.pointage_lire(p_token,p_jour,p_employe);
end $$;
revoke all on function public.admin_modifier_heure_pointage(uuid,uuid,date,integer,text,integer,uuid) from public,authenticated;
grant execute on function public.admin_modifier_heure_pointage(uuid,uuid,date,integer,text,integer,uuid) to anon;
