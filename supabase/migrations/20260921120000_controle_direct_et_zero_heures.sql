-- Le back office décide sans confirmation préalable du collaborateur.
-- Aucun pointage existant n'est modifié ; les verrous employés restent en place.
select set_config('horaires.empreinte_avant_migration',
  coalesce((select md5(string_agg(row_to_json(p)::text,'|' order by id)) from public.pointages p),'vide'), true);

create or replace function public._save_jour(
  p_employe uuid, p_jour date, p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text, p_remarque text,
  p_admin boolean, p_auteur uuid default null)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_md time; v_mf time; v_ad time; v_af time;
  v_mt text; v_at text; v_rem text;
  v_p public.pointages; v_n int;
begin
  if p_jour is null or p_jour < date '2020-01-01' or p_jour > date '2100-12-31' then
    return jsonb_build_object('ok', false, 'erreur', 'Date invalide');
  end if;
  perform public._verrou_pointages(p_employe);
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
end $function$;

create or replace function public.admin_approuver(
  p_token uuid, p_employe uuid, p_annee integer, p_mois integer, p_jour date, p_approuve boolean)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_emp public.employes; v_debut date; v_n int; v_lot text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_approuve is null then
    return jsonb_build_object('ok', false, 'erreur', 'Choisissez valider ou déverrouiller');
  end if;
  perform public._verrou_pointages(p_employe);
  perform set_config('horaires.acteur', v_emp.id::text, true);

  if p_jour is not null then
    if exists (select 1 from public.pointages where employe_id=p_employe and jour=p_jour
        and demande_etat='attente') then
      return jsonb_build_object('ok', false, 'code', 'demande_en_attente', 'erreur',
        'Répondez à la demande de déblocage avant de valider ou déverrouiller cette journée');
    end if;
    update public.pointages set
      -- L'action admin « Déverrouiller » retire les deux verrous.
      saisi_par = case when p_approuve then saisi_par else null end,
      -- Une réouverture directe règle aussi la demande encore visible.
      demande_etat = case when not p_approuve and demande_etat is not null then 'accordee' else demande_etat end,
      demande_reponse = case when not p_approuve and demande_etat is not null
        then 'Réouverture accordée par le back office' else demande_reponse end,
      demande_repondu_le = case when not p_approuve and demande_etat is not null then now() else demande_repondu_le end,
      demande_repondu_par = case when not p_approuve and demande_etat is not null then v_emp.id else demande_repondu_par end,
      approuve = p_approuve,
      approuve_le = case when p_approuve then now() else null end,
      approuve_par = case when p_approuve then v_emp.id else null end
    where employe_id = p_employe and jour = p_jour;
    get diagnostics v_n = row_count;
  else
    if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
      return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
    end if;
    v_debut := make_date(p_annee, p_mois, 1);
    if exists (select 1 from public.pointages
        where employe_id=p_employe and jour>=v_debut and jour<v_debut+interval '1 month'
          and demande_etat='attente') then
      return jsonb_build_object('ok', false, 'code', 'demande_en_attente', 'erreur',
        'Répondez aux demandes de déblocage en attente — aucune journée modifiée');
    end if;
    -- Le lot est tout ou rien. Le verrou par collaborateur empêche qu'une
    -- nouvelle journée non confirmée soit ajoutée entre contrôle et UPDATE.
    -- Un mois validé d'un geste, c'est une ligne de journal, pas trente.
    v_lot := coalesce(current_setting('horaires.lot', true), '0');
    perform set_config('horaires.lot', '1', true);
    update public.pointages set
      -- L'action admin « Déverrouiller » retire les deux verrous.
      saisi_par = case when p_approuve then saisi_par else null end,
      -- Une réouverture directe règle aussi la demande encore visible.
      demande_etat = case when not p_approuve and demande_etat is not null then 'accordee' else demande_etat end,
      demande_reponse = case when not p_approuve and demande_etat is not null
        then 'Réouverture accordée par le back office' else demande_reponse end,
      demande_repondu_le = case when not p_approuve and demande_etat is not null then now() else demande_repondu_le end,
      demande_repondu_par = case when not p_approuve and demande_etat is not null then v_emp.id else demande_repondu_par end,
      approuve = p_approuve,
      approuve_le = case when p_approuve then now() else null end,
      approuve_par = case when p_approuve then v_emp.id else null end
    where employe_id = p_employe and jour >= v_debut and jour < v_debut + interval '1 month'
      and (approuve is distinct from p_approuve
           or (not p_approuve and saisi_par = employe_id));
    get diagnostics v_n = row_count;
    perform set_config('horaires.lot', v_lot, true);
    if v_n > 0 and not public._demo(p_employe) then
      perform public._journal(v_emp.id,
        case when p_approuve then 'validation_mois' else 'deverrouillage_mois' end,
        to_char(v_debut, 'MM.YYYY'),
        jsonb_build_object(
          'employe', (select prenom from public.employes where id = p_employe),
          'n', v_n));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'nombre', v_n);
end $function$;

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

revoke execute on function public._save_jour(uuid,date,text,text,text,text,text,text,text,boolean,uuid) from public,anon,authenticated;
revoke execute on function public.admin_approuver(uuid,uuid,integer,integer,date,boolean) from public,authenticated;
grant execute on function public.admin_approuver(uuid,uuid,integer,integer,date,boolean) to anon;
revoke execute on function public.admin_decider_heures(uuid,uuid,date,integer,text,text) from public,authenticated;
grant execute on function public.admin_decider_heures(uuid,uuid,date,integer,text,text) to anon;
do $$ begin
 if current_setting('horaires.empreinte_avant_migration') is distinct from
   coalesce((select md5(string_agg(row_to_json(p)::text,'|' order by id)) from public.pointages p),'vide') then
   raise exception 'Migration annulée : les pointages existants ont changé';
 end if;
end $$;
