-- Ajouter un seul événement, sans inventer la suite de la journée.
-- Le circuit de correction existant conserve l'avant et l'auteur réel.
create or replace function public.admin_pointer(
 p_token uuid,p_employe uuid,p_jour date,p_action text,p_heure text,p_version integer,p_requete uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; p public.pointages; c public.pointage_corrections;
 evenement jsonb; events jsonb; r jsonb; motif text:='Pointage individuel enregistré par le back-office';
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 if not exists(select 1 from public.employes where id=p_employe and role='employe' and pointage_actif) then return jsonb_build_object('ok',false,'erreur','Pointage non activé pour ce technicien'); end if;
 if p_requete is null or p_version is null or p_jour is null or p_jour<date '2026-10-12' or p_jour>(clock_timestamp() at time zone 'Europe/Zurich')::date or p_action is null or p_action not in ('debut','pause','reprise','fin') or p_heure is null or p_heure!~'^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' then
  return jsonb_build_object('ok',false,'erreur','Vérifiez la date, le pointage et son heure');
 end if;
 evenement:=jsonb_build_object('action',p_action,'at',(p_jour+p_heure::time) at time zone 'Europe/Zurich','id',p_requete);
 perform public._verrou_pointages(p_employe);
 -- Vérifier le reçu avant la version : le technicien peut avoir continué
 -- depuis une réponse perdue. Un rejeu ne doit jamais écraser cette suite.
 select * into c from public.pointage_corrections where employe_id=p_employe and requete=p_requete;
 if found then
  if c.auteur is distinct from acteur.id or c.jour is distinct from p_jour or c.version is distinct from p_version or c.motif is distinct from motif or c.proposition is distinct from (c.avant||jsonb_build_array(evenement)) or c.etat<>'acceptee' then
   return jsonb_build_object('ok',false,'erreur','Requête déjà utilisée pour un autre pointage');
  end if;
  return public.pointage_lire(p_token,p_jour,p_employe)||jsonb_build_object('doublon',true);
 end if;
 select * into p from public.pointages where employe_id=p_employe and jour=p_jour for update;
 if coalesce(p.pointe_version,0) is distinct from p_version then return jsonb_build_object('ok',false,'code','conflit','erreur','Un pointage a changé entre-temps. Actualisez avant de continuer.'); end if;
 if p.id is not null and p.pointe_evenements is null then return jsonb_build_object('ok',false,'erreur','Cette journée est saisie manuellement. Utilisez le formulaire de correction.'); end if;
 if p.approuve or p.pointe_etat='termine' then return jsonb_build_object('ok',false,'erreur','Cette journée est terminée. Utilisez la correction des heures.'); end if;
 if exists(select 1 from public.pointage_corrections where employe_id=p_employe and jour=p_jour and etat='attente') then return jsonb_build_object('ok',false,'erreur','Traitez d’abord la correction en attente pour cette journée.'); end if;
 events:=coalesce(p.pointe_evenements,'[]')||jsonb_build_array(evenement);
 -- Même machine d'états, chronologie et contrôle des heures futures que sur téléphone.
 begin perform public._pointe_analyser(p_jour,events);
 exception when others then return jsonb_build_object('ok',false,'erreur',sqlerrm); end;
 r:=public.admin_pointage_enregistrer(p_token,p_jour,events,motif,p_version,p_requete,p_employe);
 if not coalesce((r->>'ok')::boolean,false) then return r; end if;
 return public.pointage_lire(p_token,p_jour,p_employe);
end $$;
revoke all on function public.admin_pointer(uuid,uuid,date,text,text,integer,uuid) from public,authenticated;
grant execute on function public.admin_pointer(uuid,uuid,date,text,text,integer,uuid) to anon;
