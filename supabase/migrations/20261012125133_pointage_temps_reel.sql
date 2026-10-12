-- Pointage réel : journal serveur, reçus idempotents et corrections versionnées.
-- Les anciennes journées ne sont ni recalculées ni réécrites.
alter table public.employes add column if not exists pointage_actif boolean not null default false;
alter table public.pointages add column if not exists pointe_evenements jsonb;
alter table public.pointages add column if not exists pointe_segments jsonb;
alter table public.pointages add column if not exists pointe_etat text;
alter table public.pointages add column if not exists pointe_version integer not null default 0;

create table public.pointage_recus (
 employe_id uuid not null references public.employes(id), requete uuid not null,
 jour date not null, action text not null, recu_le timestamptz not null default clock_timestamp(),
 primary key(employe_id,requete)
);
create table public.pointage_corrections (
 id uuid primary key default gen_random_uuid(), employe_id uuid not null references public.employes(id),
 jour date not null, version integer not null, avant jsonb not null, proposition jsonb not null,
 motif text not null check(length(motif) between 5 and 500), auteur uuid not null references public.employes(id),
 demande_le timestamptz not null default clock_timestamp(),
 etat text not null default 'attente' check(etat in ('attente','acceptee','refusee')),
 decision_le timestamptz, decision_par uuid references public.employes(id), reponse text,
 requete uuid not null, unique(employe_id,requete)
);
create unique index pointage_correction_attente on public.pointage_corrections(employe_id,jour) where etat='attente';
create index pointage_corrections_jour on public.pointage_corrections(employe_id,jour,demande_le);
alter table public.pointage_recus enable row level security;
alter table public.pointage_corrections enable row level security;
revoke all on public.pointage_recus,public.pointage_corrections from public,anon,authenticated;

create or replace function public._pointe_total(p public.pointages) returns integer
language sql immutable set search_path='' as $$
 select case when p.pointe_segments is null then public._demi_min(p.matin_type,p.matin_debut,p.matin_fin)+public._demi_min(p.apm_type,p.apm_debut,p.apm_fin)
 else coalesce((select sum((s->>1)::integer-(s->>0)::integer)::integer from jsonb_array_elements(p.pointe_segments) s),0) end
$$;
-- Les secondes originales restent dans les événements ; chaque borne de calcul
-- est ramenée à sa minute, identiquement en SQL, écran et Excel, sans arrondi au quart d'heure.
create or replace function public._pointe_analyser(p_jour date,p_events jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare e jsonb; t timestamptz; precedent timestamptz; debut timestamptz; action text;
 etat text:='vide'; segments jsonb:='[]'; a integer; b integer; minute_reelle timestamptz; m integer;
begin
 if p_events is null or jsonb_typeof(p_events)<>'array' or jsonb_array_length(p_events)>200 then raise exception 'Liste de pointages invalide'; end if;
 for e in select value from jsonb_array_elements(p_events) loop
  action:=e->>'action'; t:=(e->>'at')::timestamptz;
  if t is null or (t at time zone 'Europe/Zurich')::date<>p_jour or t>clock_timestamp()+interval '5 seconds'
     or (precedent is not null and t<=precedent) then raise exception 'Les heures doivent être chronologiques, sur la journée choisie et non futures'; end if;
  if (etat='vide' and action='debut') or (etat='pause' and action='reprise') then debut:=t; etat:='travail';
  elsif etat='travail' and action in ('pause','fin') then
   -- Découper à la minute réelle : les changements d'heure conservent
   -- la durée exacte et la plage locale utilisée par les majorations.
   a:=null; b:=null; minute_reelle:=date_trunc('minute',debut);
   while minute_reelle<date_trunc('minute',t) loop
    m:=extract(hour from minute_reelle at time zone 'Europe/Zurich')::int*60+extract(minute from minute_reelle at time zone 'Europe/Zurich')::int;
    if a is null then a:=m; b:=m+1;
    elsif m=b then b:=m+1;
    else segments:=segments||jsonb_build_array(jsonb_build_array(a,b)); a:=m; b:=m+1;
    end if;
    minute_reelle:=minute_reelle+interval '1 minute';
   end loop;
   if a is not null then segments:=segments||jsonb_build_array(jsonb_build_array(a,b)); end if;
   etat:=case action when 'pause' then 'pause' else 'termine' end;
  elsif etat='pause' and action='fin' then etat:='termine';
  else raise exception 'Ordre invalide : début, pause, reprise, puis fin'; end if;
  precedent:=t;
 end loop;
 return jsonb_build_object('etat',etat,'segments',segments);
end $$;

create or replace function public._pointe_ecrire(p_emp uuid,p_jour date,p_events jsonb,p_auteur uuid) returns void
language plpgsql security definer set search_path='' as $$
declare resultat jsonb; ancien text;
begin
 resultat:=public._pointe_analyser(p_jour,p_events);
 ancien:=coalesce(current_setting('horaires.pointe_ecriture',true),'');
 perform set_config('horaires.pointe_ecriture','1',true);
 perform set_config('horaires.acteur',p_auteur::text,true);
 insert into public.pointages(employe_id,jour,pointe_evenements,pointe_segments,pointe_etat,pointe_version,saisi_par)
 values(p_emp,p_jour,p_events,resultat->'segments',resultat->>'etat',1,case when resultat->>'etat'='termine' then p_emp end)
 on conflict(employe_id,jour) do update set pointe_evenements=excluded.pointe_evenements,
 pointe_segments=excluded.pointe_segments,pointe_etat=excluded.pointe_etat,pointe_version=public.pointages.pointe_version+1,
 saisi_par=excluded.saisi_par,approuve=false,approuve_le=null,approuve_par=null,minutes_refusees=0,motif_refus=null,modifie_le=clock_timestamp();
 perform set_config('horaires.pointe_ecriture',ancien,true);
end $$;

create or replace function public.pointage_lire(p_token uuid,p_jour date,p_employe uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acteur public.employes; cible uuid; p public.pointages;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null then return jsonb_build_object('ok',false,'erreur','session'); end if;
 cible:=coalesce(p_employe,acteur.id);
 if cible<>acteur.id and acteur.role not in ('admin','compta') then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 if acteur.role='compta' and public._demo(cible) then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 select * into p from public.pointages where employe_id=cible and jour=p_jour;
 return jsonb_build_object('ok',true,'serveur',clock_timestamp(),'aujourdhui',(clock_timestamp() at time zone 'Europe/Zurich')::date,
 'jour',p_jour,'pointage',case when p.id is not null then public._ptg_json(p) end,
 'evenements',coalesce(p.pointe_evenements,'[]'),'etat',coalesce(p.pointe_etat,'vide'),'version',coalesce(p.pointe_version,0),
 'corrections',case when acteur.role='compta' then '[]'::jsonb else coalesce((select jsonb_agg(to_jsonb(c) order by c.demande_le) from public.pointage_corrections c where c.employe_id=cible and c.jour=p_jour),'[]') end,
 'incomplets',coalesce((select jsonb_agg(jour order by jour) from public.pointages where employe_id=cible and pointe_etat in ('travail','pause') and jour<p_jour),'[]'));
end $$;

create or replace function public.pointage_pointer(p_token uuid,p_jour date,p_action text,p_version integer,p_requete uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acteur public.employes; p public.pointages; events jsonb; dernier timestamptz; recu public.pointage_recus; resultat jsonb;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'employe' or not acteur.pointage_actif then return jsonb_build_object('ok',false,'erreur','Pointage non autorisé'); end if;
 perform public._verrou_pointages(acteur.id);
 if p_requete is null then return jsonb_build_object('ok',false,'erreur','Identifiant manquant'); end if;
 select * into recu from public.pointage_recus where employe_id=acteur.id and requete=p_requete;
 if found then
  if recu.jour<>p_jour or recu.action<>p_action then return jsonb_build_object('ok',false,'erreur','Requête réutilisée pour une autre action'); end if;
  return public.pointage_lire(p_token,p_jour)||jsonb_build_object('doublon',true);
 end if;
 if p_jour is distinct from (clock_timestamp() at time zone 'Europe/Zurich')::date then return jsonb_build_object('ok',false,'erreur','Le jour a changé. Rechargez la journée ; pour un oubli, demandez une correction.'); end if;
 select * into p from public.pointages where employe_id=acteur.id and jour=p_jour for update;
 if p.id is not null and p.pointe_evenements is null then return jsonb_build_object('ok',false,'erreur','Cette journée est déjà saisie manuellement. Le pointage commence à la prochaine journée vide.'); end if;
 if coalesce(p.pointe_version,0) is distinct from p_version then return jsonb_build_object('ok',false,'code','conflit','erreur','Un pointage a déjà été enregistré. Rechargez la journée.'); end if;
 if coalesce(p.approuve,false) then return jsonb_build_object('ok',false,'erreur','Journée approuvée'); end if;
 events:=coalesce(p.pointe_evenements,'[]');
 if jsonb_array_length(events)>0 then
  dernier:=(events->-1->>'at')::timestamptz;
  if clock_timestamp()-dernier<interval '2 seconds' then return jsonb_build_object('ok',false,'code','doublon','erreur','Pointage déjà reçu. Patientez deux secondes.'); end if;
 end if;
 events:=events||jsonb_build_array(jsonb_build_object('action',p_action,'at',clock_timestamp(),'id',p_requete));
 begin
  perform public._pointe_ecrire(acteur.id,p_jour,events,acteur.id);
 exception when raise_exception or invalid_datetime_format or invalid_text_representation then
  return jsonb_build_object('ok',false,'erreur',sqlerrm);
 end;
 insert into public.pointage_recus(employe_id,requete,jour,action) values(acteur.id,p_requete,p_jour,p_action);
 perform public._journal(acteur.id,'pointage_'||p_action,p_jour::text,jsonb_build_object('employe',acteur.prenom,'evenement',events->-1,'appareil',public._appareil()));
 return public.pointage_lire(p_token,p_jour);
end $$;

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
 if v_analyse->>'etat'<>'termine' then return jsonb_build_object('ok',false,'erreur','La correction doit décrire la journée complète, jusqu’à la fin'); end if;
 insert into public.pointage_corrections(employe_id,jour,version,avant,proposition,motif,auteur,requete)
 values(cible,p_jour,p_version,coalesce(p.pointe_evenements,'[]'),p_evenements,btrim(p_motif),acteur.id,p_requete) returning id into id_demande;
 if not public._demo(cible) then perform public._journal(acteur.id,'pointage_correction_demandee',p_jour::text,jsonb_build_object('employe',(select prenom from public.employes where id=cible),'demande',id_demande,'origine',coalesce(p.pointe_evenements,'[]'),'proposition',p_evenements,'motif',btrim(p_motif))); end if;
 return jsonb_build_object('ok',true,'id',id_demande);
end $$;

create or replace function public.pointage_decider(p_token uuid,p_demande uuid,p_accepter boolean,p_reponse text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare acteur public.employes; c public.pointage_corrections; p public.pointages;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 select * into c from public.pointage_corrections where id=p_demande;
 if not found or p_accepter is null then return jsonb_build_object('ok',false,'erreur','Demande introuvable'); end if;
 perform public._verrou_pointages(c.employe_id);
 select * into c from public.pointage_corrections where id=p_demande for update;
 if c.etat<>'attente' then return jsonb_build_object('ok',false,'erreur','Demande déjà traitée'); end if;
 select * into p from public.pointages where employe_id=c.employe_id and jour=c.jour for update;
 if p_accepter and (coalesce(p.pointe_version,0)<>c.version or (p.id is not null and p.pointe_evenements is null)) then return jsonb_build_object('ok',false,'erreur','Les pointages ont changé depuis la demande. Refusez cette demande et demandez une nouvelle correction.'); end if;
 if not p_accepter and length(btrim(coalesce(p_reponse,'')))<3 then return jsonb_build_object('ok',false,'erreur','Indiquez le motif du refus'); end if;
 if p_accepter then perform public._pointe_ecrire(c.employe_id,c.jour,c.proposition,acteur.id); end if;
 update public.pointage_corrections set etat=case when p_accepter then 'acceptee' else 'refusee' end,decision_le=clock_timestamp(),decision_par=acteur.id,reponse=left(btrim(p_reponse),500) where id=c.id;
 if not public._demo(c.employe_id) then perform public._journal(acteur.id,case when p_accepter then 'pointage_correction_acceptee' else 'pointage_correction_refusee' end,c.jour::text,jsonb_build_object('employe',(select prenom from public.employes where id=c.employe_id),'demande',c.id,'origine',c.avant,'proposition',c.proposition,'motif',c.motif,'reponse',left(p_reponse,500))); end if;
 return jsonb_build_object('ok',true);
end $$;

create or replace function public._pointe_garde() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  if old.pointe_evenements is not null then raise exception 'Les pointages ne se suppriment pas : utilisez une correction tracée'; end if;
  return old;
 end if;
 if coalesce(current_setting('horaires.pointe_ecriture',true),'')='1' then return new; end if;
 if tg_op='UPDATE' and old.pointe_evenements is not null then
  if row(new.pointe_evenements,new.pointe_segments,new.pointe_etat,new.matin_type,new.matin_debut,new.matin_fin,new.apm_type,new.apm_debut,new.apm_fin,new.jour,new.employe_id)
   is distinct from row(old.pointe_evenements,old.pointe_segments,old.pointe_etat,old.matin_type,old.matin_debut,old.matin_fin,old.apm_type,old.apm_debut,old.apm_fin,old.jour,old.employe_id) then raise exception 'Utilisez une correction des pointages pour modifier ces heures'; end if;
 end if;
 if new.approuve and new.pointe_evenements is not null and (new.pointe_etat<>'termine' or exists(select 1 from public.pointage_corrections where employe_id=new.employe_id and jour=new.jour and etat='attente')) then raise exception 'Terminez la journée et traitez les corrections avant approbation'; end if;
 return new;
end $$;
create trigger a_pointage_garde before insert or update or delete on public.pointages for each row execute function public._pointe_garde();

alter table public.pointages drop constraint pointages_decision_heures;
alter table public.pointages add constraint pointages_decision_heures check(minutes_refusees>=0 and minutes_refusees<=public._pointe_total(pointages) and (approuve or minutes_refusees=0) and (motif_refus is null or (minutes_refusees>0 and length(motif_refus)<=500)));

-- Déclaration d'ouverture réelle du client ; distincte des rafraîchissements de fond.
create or replace function public.activite_noter(p_token uuid,p_action text,p_ecran text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e public.employes;
begin
 e:=public._auth(p_token);
 if e.id is null then return jsonb_build_object('ok',false,'erreur','session'); end if;
 if p_action not in ('ouverture_app','consultation_ecran','retour_app') or p_ecran not in ('aujourdhui','mois','questions','back office') then return jsonb_build_object('ok',false,'erreur','Action invalide'); end if;
 perform public._verrou_pointages(e.id);
 if not exists(select 1 from public.journal where acteur_id=e.id and action=p_action and cible=p_ecran and quand>clock_timestamp()-interval '10 seconds') then
  perform public._journal(e.id,p_action,p_ecran,jsonb_build_object('appareil',public._appareil()));
 end if;
 return jsonb_build_object('ok',true);
end $$;

-- Aucun accès direct aux données ; les RPC authentifient jeton et rôle.
revoke all on function public._pointe_total(public.pointages),public._pointe_analyser(date,jsonb),public._pointe_ecrire(uuid,date,jsonb,uuid),public._pointe_garde() from public,anon,authenticated;
revoke all on function public.pointage_lire(uuid,date,uuid),public.pointage_pointer(uuid,date,text,integer,uuid),public.pointage_corriger(uuid,date,jsonb,text,integer,uuid,uuid),public.pointage_decider(uuid,uuid,boolean,text),public.activite_noter(uuid,text,text) from public,authenticated;
grant execute on function public.pointage_lire(uuid,date,uuid),public.pointage_pointer(uuid,date,text,integer,uuid),public.pointage_corriger(uuid,date,jsonb,text,integer,uuid,uuid),public.pointage_decider(uuid,uuid,boolean,text),public.activite_noter(uuid,text,text) to anon;

CREATE OR REPLACE FUNCTION public._emp_json(e employes)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', e.id, 'prenom', e.prenom, 'nom', e.nom, 'metier', e.metier,
    'role', e.role, 'actif', e.actif, 'demo', e.demo, 'pointage_actif', e.pointage_actif,
    'matin_debut_def', to_char(e.matin_debut_def, 'HH24:MI'),
    'matin_fin_def',   to_char(e.matin_fin_def, 'HH24:MI'),
    'apm_debut_def',   to_char(e.apm_debut_def, 'HH24:MI'),
    'apm_fin_def',     to_char(e.apm_fin_def, 'HH24:MI'))
$function$
;

CREATE OR REPLACE FUNCTION public._ptg_json(p pointages)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  select jsonb_build_object(
    'employe_id', p.employe_id,
    'jour', to_char(p.jour, 'YYYY-MM-DD'),
 'pointe_segments',p.pointe_segments,'pointe_etat',p.pointe_etat,'pointe_version',p.pointe_version,
 'pointe_evenements',p.pointe_evenements,
 'pointe_attente',exists(select 1 from public.pointage_corrections c where c.employe_id=p.employe_id and c.jour=p.jour and c.etat='attente'),
    'matin_type', p.matin_type,
    'matin_debut', to_char(p.matin_debut, 'HH24:MI'),
    'matin_fin',   to_char(p.matin_fin, 'HH24:MI'),
    'apm_type', p.apm_type,
    'apm_debut', to_char(p.apm_debut, 'HH24:MI'),
    'apm_fin',   to_char(p.apm_fin, 'HH24:MI'),
    'remarque', p.remarque,
    'approuve', p.approuve,
    'minutes_refusees', p.minutes_refusees,
    'motif_refus', p.motif_refus,
    'version_decision', md5(row_to_json(p)::text),
    'approuve_le', to_char(p.approuve_le, 'DD.MM.YYYY'),
    'demande_etat', p.demande_etat,
    'demande_motif', p.demande_motif,
    'demande_le', to_char(p.demande_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'),
    'demande_reponse', p.demande_reponse,
    -- Confirmée = enregistrée par le collaborateur lui-même.
    'confirme', p.saisi_par is not null and p.saisi_par = p.employe_id)
$function$
;

CREATE OR REPLACE FUNCTION public.admin_decider_heures(p_token uuid, p_employe uuid, p_jour date, p_minutes_approuvees integer, p_motif text, p_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_emp public.employes; v_p public.pointages; v_total integer; v_refus integer; v_motif text;
begin
  v_emp:=public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok',false,'erreur','session');
  end if;
  perform public._verrou_pointages(p_employe);
  select * into v_p from public.pointages where employe_id=p_employe and jour=p_jour for update;
  if not found then return jsonb_build_object('ok',false,'erreur','Journée introuvable'); end if;
  if p_version is distinct from md5(row_to_json(v_p)::text) then
    return jsonb_build_object('ok',false,'code','conflit','erreur','Cette journée a changé. Rouvrez-la avant de décider.');
  end if;
  if v_p.demande_etat='attente' then
    return jsonb_build_object('ok',false,'erreur','Traitez d’abord la demande de modification');
  end if;
  v_total:=public._pointe_total(v_p);
  if p_minutes_approuvees is null or p_minutes_approuvees<0 or p_minutes_approuvees>v_total then
    return jsonb_build_object('ok',false,'erreur','La durée approuvée doit être comprise entre zéro et la durée saisie');
  end if;
  if length(coalesce(p_motif,''))>500 then
    return jsonb_build_object('ok',false,'erreur','Le motif est limité à 500 caractères');
  end if;
  v_refus:=v_total-p_minutes_approuvees;
  v_motif:=case when v_refus>0 then nullif(btrim(p_motif),'') else null end;
  perform set_config('horaires.acteur',v_emp.id::text,true);
  update public.pointages set approuve=true, approuve_le=clock_timestamp(), approuve_par=v_emp.id,
    minutes_refusees=v_refus, motif_refus=v_motif
    where id=v_p.id and (not approuve or minutes_refusees<>v_refus or motif_refus is distinct from v_motif);
  return jsonb_build_object('ok',true,'minutes_approuvees',p_minutes_approuvees,'minutes_refusees',v_refus);
end $function$
;

CREATE OR REPLACE FUNCTION public.mes_pointages(p_token uuid, p_annee integer, p_mois integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_emp public.employes; v_debut date; v_ptgs jsonb;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  if v_emp.role = 'employe' then
    update public.employes set derniere_connexion = now() where id = v_emp.id;
  end if;
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb) into v_ptgs
    from public.pointages p
   where p.employe_id = v_emp.id and p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  return jsonb_build_object('ok', true, 'employe', public._emp_json(v_emp), 'pointages', v_ptgs, 'aujourdhui',(clock_timestamp() at time zone 'Europe/Zurich')::date);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_donnees(p_token uuid, p_annee integer, p_mois integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb;
  v_entreprise text; v_nl int; v_depuis date;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  perform public._presence(v_emp, p_annee, p_mois);
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce((select valeur::date from public.parametres where cle = 'tracabilite_depuis'),
                  current_date) into v_depuis;
  select coalesce(jsonb_agg(public._emp_json_admin(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e;
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_direction;
  return jsonb_build_object('ok', true, 'pointage_demandes',coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('employe',(select prenom from public.employes where id=c.employe_id)) order by c.demande_le) from public.pointage_corrections c where c.etat='attente' and not public._demo(c.employe_id)),'[]'), 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl,
    'tracabilite_depuis', to_char(v_depuis, 'YYYY-MM-DD'),
    'aujourdhui', to_char((now() at time zone 'Europe/Zurich')::date, 'YYYY-MM-DD'));
end $function$
;

CREATE OR REPLACE FUNCTION public.journal_lire(p_token uuid, p_jours integer DEFAULT 30, p_limite integer DEFAULT 300, p_acteur uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_emp public.employes; v_j int; v_l int; v_depuis timestamptz;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'Acces refuse');
  end if;
  v_j := least(greatest(coalesce(p_jours, 30), 1), 400);
  v_l := least(greatest(coalesce(p_limite, 300), 1), 2000);
  v_depuis := (date_trunc('day', now() at time zone 'Europe/Zurich')
               - make_interval(days => v_j - 1)) at time zone 'Europe/Zurich';
  return jsonb_build_object(
    'ok', true, 'jours', v_j,
    'acteurs', coalesce((
      select jsonb_agg(a order by a->>'nom')
        from (
          select distinct on (j.acteur_id) jsonb_build_object(
                   'id', j.acteur_id,
                   'nom', case when j.acteur_role = 'compta' then 'La fiduciaire' else j.acteur_nom end,
                   'role', j.acteur_role,
                   'nb', count(*) over (partition by j.acteur_id)) as a
            from public.journal j
           where j.quand >= v_depuis and j.acteur_id is not null
        ) t), '[]'::jsonb),
    'lignes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', j.id, 'acteur_id', j.acteur_id,
               'jour', to_char(j.quand at time zone 'Europe/Zurich', 'DD.MM.YYYY'),
               'heure', to_char(j.quand at time zone 'Europe/Zurich', 'HH24:MI:SS'),
               'qui', case when j.acteur_role = 'compta' then 'La fiduciaire' else j.acteur_nom end,
               'role', j.acteur_role,
               'action', j.action, 'cible', j.cible, 'detail', j.detail)
             order by j.quand desc)
        from (select * from public.journal
               where quand >= v_depuis and (p_acteur is null or acteur_id = p_acteur)
               order by quand desc limit v_l) j), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public._save_jour(p_employe uuid, p_jour date, p_matin_type text, p_matin_debut text, p_matin_fin text, p_apm_type text, p_apm_debut text, p_apm_fin text, p_remarque text, p_admin boolean, p_auteur uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_md time; v_mf time; v_ad time; v_af time;
  v_mt text; v_at text; v_rem text;
  v_p public.pointages; v_n int;
begin
  if p_jour is null or p_jour < date '2020-01-01' or p_jour > date '2100-12-31' then
    return jsonb_build_object('ok', false, 'erreur', 'Date invalide');
  end if;
  perform public._verrou_pointages(p_employe);
  if exists(select 1 from public.pointages where employe_id=p_employe and jour=p_jour and pointe_evenements is not null) then
    return jsonb_build_object('ok',false,'erreur','Utilisez une correction des pointages pour cette journée');
  end if;
  if not p_admin and p_jour >= date '2026-10-12'
    and exists(select 1 from public.employes where id=p_employe and pointage_actif)
    and not exists(select 1 from public.pointages where employe_id=p_employe and jour=p_jour)
    and (nullif(p_matin_debut,'') is not null or nullif(p_matin_fin,'') is not null or nullif(p_apm_debut,'') is not null or nullif(p_apm_fin,'') is not null) then
    return jsonb_build_object('ok',false,'erreur','Actualisez l’application, puis utilisez le bouton de pointage pour enregistrer le travail. En cas d’oubli, demandez une correction.');
  end if;
  -- La lecture verrouille la ligne jusqu'à la fin de la transaction : une
  -- approbation ou confirmation concurrente ne peut pas dépasser ce contrôle.
  select * into v_p from public.pointages
    where employe_id = p_employe and jour = p_jour for update;
  if not coalesce(p_admin, false) and
      (coalesce(v_p.approuve, false) or coalesce(v_p.saisi_par = p_employe, false)) then
    return jsonb_build_object('ok', false, 'code', 'jour_verrouille', 'erreur',
      'Journée confirmée ou approuvée — demandez son déblocage au back office');
  end if;
  v_mt := coalesce(nullif(trim(p_matin_type), ''), 'travail');
  v_at := coalesce(nullif(trim(p_apm_type), ''), 'travail');
  if v_mt not in ('travail','vacances','maladie','accident','ferie','armee','ecole','conge_np','autre')
     or v_at not in ('travail','vacances','maladie','accident','ferie','armee','ecole','conge_np','autre') then
    return jsonb_build_object('ok', false, 'erreur', 'Type de journée invalide');
  end if;
  begin
    v_md := nullif(trim(coalesce(p_matin_debut, '')), '')::time;
    v_mf := nullif(trim(coalesce(p_matin_fin, '')), '')::time;
    v_ad := nullif(trim(coalesce(p_apm_debut, '')), '')::time;
    v_af := nullif(trim(coalesce(p_apm_fin, '')), '')::time;
  exception when others then
    return jsonb_build_object('ok', false, 'erreur', 'Heure invalide');
  end;
  if v_mt <> 'travail' then v_md := null; v_mf := null; end if;
  if v_at <> 'travail' then v_ad := null; v_af := null; end if;
  if v_md is not null and v_mf is not null and v_mf <= v_md then
    return jsonb_build_object('ok', false, 'erreur', 'Matin : l''heure de fin doit être après le début');
  end if;
  if v_ad is not null and v_af is not null and v_af <= v_ad then
    return jsonb_build_object('ok', false, 'erreur', 'Après-midi : l''heure de fin doit être après le début');
  end if;
  if v_mf is not null and v_ad is not null and v_ad < v_mf then
    return jsonb_build_object('ok', false, 'erreur', 'L''après-midi ne peut pas commencer avant la fin du matin');
  end if;
  v_rem := left(coalesce(trim(p_remarque), ''), 200);

  perform set_config('horaires.acteur', coalesce(p_auteur, p_employe)::text, true);

  -- Une saisie explicite à zéro reste une journée, même sans remarque.
  insert into public.pointages
    (employe_id, jour, matin_type, matin_debut, matin_fin, apm_type, apm_debut, apm_fin, remarque, saisi_par)
  values
    (p_employe, p_jour, v_mt, v_md, v_mf, v_at, v_ad, v_af, v_rem, p_auteur)
  on conflict (employe_id, jour) do update set
    matin_type = excluded.matin_type, matin_debut = excluded.matin_debut, matin_fin = excluded.matin_fin,
    apm_type = excluded.apm_type, apm_debut = excluded.apm_debut, apm_fin = excluded.apm_fin,
    remarque = excluded.remarque, modifie_le = now(),
    -- Le BO ne solde pas une demande en corrigeant la feuille. Seule la
    -- nouvelle confirmation de l'employé après réouverture termine le cycle.
    demande_etat = case when p_admin then public.pointages.demande_etat else null end,
    demande_motif = case when p_admin then public.pointages.demande_motif else null end,
    demande_le = case when p_admin then public.pointages.demande_le else null end,
    demande_reponse = case when p_admin then public.pointages.demande_reponse else null end,
    demande_repondu_le = case when p_admin then public.pointages.demande_repondu_le else null end,
    demande_repondu_par = case when p_admin then public.pointages.demande_repondu_par else null end,
    saisi_par = case
      when excluded.saisi_par = public.pointages.employe_id then excluded.saisi_par
      when public.pointages.saisi_par = public.pointages.employe_id then public.pointages.saisi_par
      else excluded.saisi_par
    end
  -- Si la ligne n'existait pas au SELECT, une autre première confirmation peut
  -- l'avoir créée entre-temps. Le conflit est contrôlé sur sa version courante.
  where coalesce(p_admin, false) or
        (not public.pointages.approuve and
         public.pointages.saisi_par is distinct from public.pointages.employe_id);
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'code', 'jour_verrouille', 'erreur',
      'Journée confirmée ou approuvée — demandez son déblocage au back office');
  end if;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public._trg_journal_pointages()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_acteur uuid; v_par text; v_horaire text; v_emp text;
  v_avant jsonb; v_apres jsonb; v_champs text[] := '{}'; v_ctx jsonb;
begin
  if coalesce(current_setting('horaires.pointe_ecriture',true),'')='1' then
    return new;
  end if;
  if tg_op = 'DELETE' then
    if public._demo(old.employe_id) or public._demo(old.saisi_par) then return old; end if;
    v_acteur := coalesce(nullif(current_setting('horaires.acteur', true), '')::uuid, old.saisi_par);
    perform public._journal(v_acteur, 'suppression', to_char(old.jour, 'DD.MM.YYYY'),
      jsonb_build_object(
        'employe', (select prenom from public.employes where id = old.employe_id),
        'appareil', public._appareil(),
        'avant', public._ptg_resume(old.matin_type, old.matin_debut, old.matin_fin,
                                    old.apm_type, old.apm_debut, old.apm_fin, old.remarque)));
    return old;
  end if;

  if public._demo(new.employe_id) or public._demo(new.saisi_par) then return new; end if;

  v_acteur := coalesce(nullif(current_setting('horaires.acteur', true), '')::uuid, new.saisi_par);
  v_emp    := (select prenom from public.employes where id = new.employe_id);
  v_par    := case when v_acteur = new.employe_id then 'technicien' else 'back office' end;
  v_horaire := case
    when coalesce((to_jsonb(new)->>'prerempli')::boolean, false) then 'type' else 'tapé' end;
  v_apres := public._ptg_resume(new.matin_type,new.matin_debut,new.matin_fin,new.apm_type,new.apm_debut,new.apm_fin,new.remarque);
  if new.pointe_evenements is not null then v_apres:=jsonb_build_object('m','Pointage réel','min',public._pointe_total(new),'rem',new.remarque); end if;
  -- Le contexte d'une écriture : combien de jours après la journée concernée,
  -- combien d'heures au-delà de la normale, et depuis quel appareil.
  v_ctx := jsonb_build_object(
    'retard', (current_date - new.jour),
    'sup', public._sup_jour(new.jour, new.matin_type, new.matin_debut, new.matin_fin,
                            new.apm_type, new.apm_debut, new.apm_fin),
    'appareil', public._appareil());

  if tg_op = 'INSERT' then
    perform public._journal(v_acteur, 'saisie', to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', v_emp, 'par', v_par, 'horaire', v_horaire,
                         'apres', v_apres) || v_ctx);
    return new;
  end if;

  v_avant := public._ptg_resume(old.matin_type,old.matin_debut,old.matin_fin,old.apm_type,old.apm_debut,old.apm_fin,old.remarque);
  if old.pointe_evenements is not null then v_avant:=jsonb_build_object('m','Pointage réel','min',public._pointe_total(old),'rem',old.remarque); end if;

  if v_avant is distinct from v_apres then
    if new.matin_type  is distinct from old.matin_type
    or new.matin_debut is distinct from old.matin_debut
    or new.matin_fin   is distinct from old.matin_fin then
      v_champs := array_append(v_champs, 'matin');
    end if;
    if new.apm_type  is distinct from old.apm_type
    or new.apm_debut is distinct from old.apm_debut
    or new.apm_fin   is distinct from old.apm_fin then
      v_champs := array_append(v_champs, 'après-midi');
    end if;
    if new.remarque is distinct from old.remarque then
      v_champs := array_append(v_champs, 'remarque');
    end if;
    perform public._journal(v_acteur, 'modification', to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object(
        'employe', v_emp, 'par', v_par, 'horaire', v_horaire,
        'avant', v_avant, 'apres', v_apres,
        'delta', (v_apres->>'min')::int - (v_avant->>'min')::int,
        'champs', to_jsonb(v_champs),
        'etait_approuve', coalesce(old.approuve, false),
        -- Rouverte sur demande : on rappelle le motif invoqué.
        'motif_demande', old.demande_motif) || v_ctx);
    return new;
  end if;

  if new.approuve is distinct from old.approuve then
    if coalesce(nullif(current_setting('horaires.lot', true), ''), '0') = '1' then
      return new;
    end if;
    perform public._journal(
      coalesce(case when new.approuve then new.approuve_par else v_acteur end, v_acteur),
      case when new.approuve then 'validation' else 'deverrouillage' end,
      to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', v_emp, 'apres', v_apres));
    return new;
  end if;

  -- Un BO peut rouvrir une journée confirmée avant même de l'approuver.
  -- Cette transition ne change pas approuve : elle doit néanmoins être tracée.
  if old.saisi_par = old.employe_id
     and new.saisi_par is distinct from new.employe_id then
    if coalesce(nullif(current_setting('horaires.lot', true), ''), '0') <> '1' then
      perform public._journal(v_acteur, 'deverrouillage', to_char(new.jour, 'DD.MM.YYYY'),
        jsonb_build_object('employe', v_emp, 'apres', v_apres, 'confirmation_retiree', true));
    end if;
    return new;
  end if;

  if new.saisi_par is distinct from old.saisi_par and new.saisi_par = new.employe_id then
    perform public._journal(v_acteur, 'confirmation', to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', v_emp, 'apres', v_apres) || v_ctx);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public._trg_journal_decision_heures()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_acteur uuid;
begin
  if public._demo(new.employe_id) then return new; end if;
  if row(new.minutes_refusees,new.motif_refus) is distinct from row(old.minutes_refusees,old.motif_refus) then
    v_acteur:=nullif(current_setting('horaires.acteur',true),'')::uuid;
    perform public._journal(v_acteur,'decision_heures',new.jour::text,jsonb_build_object(
      'employe',(select prenom from public.employes where id=new.employe_id),
      'minutes_saisies',public._pointe_total(new),
      'minutes_refusees',new.minutes_refusees,'motif',new.motif_refus,
      'refus_avant',old.minutes_refusees,'motif_avant',old.motif_refus,'approuve',new.approuve));
  end if;
  return new;
end $function$
;;


-- Instantané serveur à l'export : aucun export de pointages inachevés ou en litige.
create or replace function public.pointage_exporter(p_token uuid,p_annee integer,p_mois integer,p_employes uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acteur public.employes; debut date; fin date; donnees jsonb; attente boolean;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role not in ('admin','compta') then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 debut:=make_date(p_annee,p_mois,1); fin:=(debut+interval '1 month')::date;
 -- Une seule lecture SQL fournit un instantané cohérent des lignes et demandes.
 select coalesce((select jsonb_agg(public._ptg_json(p)) from public.pointages p join public.employes e on e.id=p.employe_id where p.jour>=debut and p.jour<fin and p.employe_id=any(p_employes) and not e.demo),'[]'),
 exists(select 1 from public.pointage_corrections c join public.employes e on e.id=c.employe_id where c.jour>=debut and c.jour<fin and c.employe_id=any(p_employes) and c.etat='attente' and not e.demo)
 into donnees,attente;
 if attente or exists(select 1 from jsonb_array_elements(donnees) p where p->>'pointe_etat' in ('travail','pause')) then
  return jsonb_build_object('ok',false,'erreur','Export suspendu : terminez les journées pointées et traitez les corrections en attente.');
 end if;
 return jsonb_build_object('ok',true,'pointages',donnees,'aujourdhui',(clock_timestamp() at time zone 'Europe/Zurich')::date,'instantane',clock_timestamp());
end $$;
revoke all on function public.pointage_exporter(uuid,integer,integer,uuid[]) from public,authenticated;
grant execute on function public.pointage_exporter(uuid,integer,integer,uuid[]) to anon;
