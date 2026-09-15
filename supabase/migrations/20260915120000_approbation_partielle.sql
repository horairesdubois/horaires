-- La migration est transactionnelle : préserver toutes les données existantes.
lock table public.pointages in access exclusive mode;
do $$ begin
  perform set_config('horaires.empreinte_avant_migration',
    coalesce((select md5(string_agg((to_jsonb(p)-'minutes_refusees'-'motif_refus')::text,'|' order by employe_id,jour)) from public.pointages p), 'vide'), true);
end $$;

-- Une journée traitée peut comporter des heures refusées, sans altérer la saisie.
alter table public.pointages
  add column if not exists minutes_refusees integer not null default 0,
  add column if not exists motif_refus text;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='pointages_decision_heures' and conrelid='public.pointages'::regclass) then
    alter table public.pointages add constraint pointages_decision_heures check (
      minutes_refusees >= 0 and minutes_refusees <=
        public._demi_min(matin_type,matin_debut,matin_fin) + public._demi_min(apm_type,apm_debut,apm_fin)
      and (approuve or minutes_refusees=0)
      and (motif_refus is null or (minutes_refusees > 0 and length(motif_refus)<=500)));
  end if;
end $$;

create or replace function public._trg_preparer_decision_heures()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Une correction des horaires approuvés impose un nouveau cycle de contrôle.
  if old.approuve and row(new.matin_type,new.matin_debut,new.matin_fin,new.apm_type,new.apm_debut,new.apm_fin)
     is distinct from row(old.matin_type,old.matin_debut,old.matin_fin,old.apm_type,old.apm_debut,old.apm_fin) then
    new.approuve := false; new.approuve_le := null; new.approuve_par := null;
    new.saisi_par := null;
  end if;
  if not new.approuve then new.minutes_refusees:=0; new.motif_refus:=null; end if;
  if row(new.approuve,new.minutes_refusees,new.motif_refus)
     is distinct from row(old.approuve,old.minutes_refusees,old.motif_refus) then
    new.modifie_le := clock_timestamp();
  end if;
  return new;
end $$;
revoke all on function public._trg_preparer_decision_heures() from public,anon,authenticated;
drop trigger if exists preparer_decision_heures on public.pointages;
create trigger preparer_decision_heures before update on public.pointages
for each row execute function public._trg_preparer_decision_heures();

create or replace function public.admin_decider_heures(
  p_token uuid, p_employe uuid, p_jour date, p_minutes_approuvees integer,
  p_motif text, p_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  if not v_p.approuve and v_p.saisi_par is distinct from p_employe then
    return jsonb_build_object('ok',false,'erreur','Confirmation de l’employé attendue');
  end if;
  v_total:=public._demi_min(v_p.matin_type,v_p.matin_debut,v_p.matin_fin)+public._demi_min(v_p.apm_type,v_p.apm_debut,v_p.apm_fin);
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
end $$;
revoke all on function public.admin_decider_heures(uuid,uuid,date,integer,text,text) from public,authenticated,anon;
grant execute on function public.admin_decider_heures(uuid,uuid,date,integer,text,text) to anon;

create or replace function public._trg_journal_decision_heures()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_acteur uuid;
begin
  if public._demo(new.employe_id) then return new; end if;
  if row(new.minutes_refusees,new.motif_refus) is distinct from row(old.minutes_refusees,old.motif_refus) then
    v_acteur:=nullif(current_setting('horaires.acteur',true),'')::uuid;
    perform public._journal(v_acteur,'decision_heures',new.jour::text,jsonb_build_object(
      'employe',(select prenom from public.employes where id=new.employe_id),
      'minutes_saisies',public._demi_min(new.matin_type,new.matin_debut,new.matin_fin)+public._demi_min(new.apm_type,new.apm_debut,new.apm_fin),
      'minutes_refusees',new.minutes_refusees,'motif',new.motif_refus,
      'refus_avant',old.minutes_refusees,'motif_avant',old.motif_refus,'approuve',new.approuve));
  end if;
  return new;
end $$;
revoke all on function public._trg_journal_decision_heures() from public,anon,authenticated;
drop trigger if exists journal_decision_heures on public.pointages;
create trigger journal_decision_heures after update on public.pointages
for each row execute function public._trg_journal_decision_heures();

create or replace function public._ptg_json(p pointages)
returns jsonb language sql stable
set search_path to 'public', 'extensions'
as $function$
  select jsonb_build_object(
    'employe_id', p.employe_id,
    'jour', to_char(p.jour, 'YYYY-MM-DD'),
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
$function$;


revoke all on function public._ptg_json(public.pointages) from public,anon,authenticated;

-- Aucun horaire, statut, auteur, motif existant ou horodatage ne doit changer.
do $$ begin
  if current_setting('horaires.empreinte_avant_migration') is distinct from
    coalesce((select md5(string_agg((to_jsonb(p)-'minutes_refusees'-'motif_refus')::text,'|' order by employe_id,jour)) from public.pointages p), 'vide') then
    raise exception 'Migration annulée : une donnée existante a changé';
  end if;
end $$;
