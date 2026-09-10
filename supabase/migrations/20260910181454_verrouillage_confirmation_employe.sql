-- Une confirmation engage la journée : le collaborateur ne peut plus modifier
-- ni supprimer ses heures, absences ou remarques sans déblocage du back office.
-- Aucun changement de calcul, de table, de RLS ou de données historiques.
--
-- Cycle : saisie employé -> confirmée/verrouillée -> demande ->
-- refus (reste verrouillée) OU accord (confirmation et approbation retirées) ->
-- correction/reconfirmation employé -> approbation back office.
-- Les écritures concurrentes recontrôlent le verrou sur la ligne courante.

-- Une sérialisation par collaborateur couvre aussi une journée inexistante
-- et les opérations portant sur tout le mois. Tous les écrivains prennent ce
-- verrou avant les verrous de lignes ; il disparaît au commit/rollback.
create or replace function public._verrou_pointages(p_employe uuid)
returns void language sql volatile
set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('horaires.pointages:' || p_employe::text, 0))
$$;
revoke execute on function public._verrou_pointages(uuid) from anon, authenticated, public;

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

  if v_mt = 'travail' and v_at = 'travail'
     and v_md is null and v_mf is null and v_ad is null and v_af is null and v_rem = '' then
    -- La condition protège aussi une ligne insérée après la lecture initiale.
    delete from public.pointages where employe_id = p_employe and jour = p_jour
      and (coalesce(p_admin, false) or
           (not approuve and saisi_par is distinct from employe_id));
    if not coalesce(p_admin, false) and exists (select 1 from public.pointages
        where employe_id = p_employe and jour = p_jour
          and (approuve or saisi_par = employe_id)) then
      return jsonb_build_object('ok', false, 'code', 'jour_verrouille', 'erreur',
        'Journée confirmée ou approuvée — demandez son déblocage au back office');
    end if;
    return jsonb_build_object('ok', true, 'supprime', true);
  end if;

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

create or replace function public.supprimer_jour(p_token uuid, p_jour date)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes; v_p public.pointages;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if v_emp.role = 'compta' then
    return jsonb_build_object('ok', false, 'erreur', 'Accès fiduciaire : consultation uniquement');
  end if;
  perform public._verrou_pointages(v_emp.id);
  select * into v_p from public.pointages
    where employe_id = v_emp.id and jour = p_jour for update;
  if coalesce(v_p.approuve, false) or coalesce(v_p.saisi_par = v_emp.id, false) then
    return jsonb_build_object('ok', false, 'code', 'jour_verrouille', 'erreur',
      'Journée confirmée ou approuvée — demandez son déblocage au back office');
  end if;
  perform set_config('horaires.acteur', v_emp.id::text, true);
  delete from public.pointages where employe_id = v_emp.id and jour = p_jour
    and not approuve and saisi_par is distinct from employe_id;
  if exists (select 1 from public.pointages
      where employe_id = v_emp.id and jour = p_jour and (approuve or saisi_par = employe_id)) then
    return jsonb_build_object('ok', false, 'code', 'jour_verrouille', 'erreur',
      'Journée confirmée ou approuvée — demandez son déblocage au back office');
  end if;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.demande_modification(p_token uuid, p_jour date, p_motif text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes; v_p public.pointages; v_motif text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if v_emp.role <> 'employe' then
    return jsonb_build_object('ok', false, 'erreur', 'Seul un collaborateur demande une ouverture');
  end if;
  v_motif := left(trim(coalesce(p_motif, '')), 300);
  if length(v_motif) < 5 then
    return jsonb_build_object('ok', false, 'erreur',
      'Expliquez en une phrase ce qu''il faut corriger');
  end if;
  perform public._verrou_pointages(v_emp.id);
  select * into v_p from public.pointages where employe_id = v_emp.id and jour = p_jour for update;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Journée introuvable');
  end if;
  if not (coalesce(v_p.approuve, false) or coalesce(v_p.saisi_par = v_emp.id, false)) then
    return jsonb_build_object('ok', false, 'erreur', 'Cette journée est déjà modifiable');
  end if;
  if v_p.demande_etat = 'attente' then
    return jsonb_build_object('ok', false, 'erreur', 'Une demande est déjà en attente');
  end if;
  perform set_config('horaires.acteur', v_emp.id::text, true);
  -- Seules les colonnes `demande_*` bougent : le déclencheur ne journalise ni
  -- contenu ni approbation, il se tait donc de lui-même.
  update public.pointages
     set demande_etat = 'attente', demande_motif = v_motif, demande_le = now(),
         demande_reponse = null, demande_repondu_le = null, demande_repondu_par = null
   where id = v_p.id;
  perform public._journal(v_emp.id, 'demande_modification', to_char(p_jour, 'DD.MM.YYYY'),
    jsonb_build_object('employe', v_emp.prenom, 'motif', v_motif,
      'appareil', public._appareil(),
      'etat', public._ptg_resume(v_p.matin_type, v_p.matin_debut, v_p.matin_fin,
                                 v_p.apm_type, v_p.apm_debut, v_p.apm_fin, v_p.remarque)));
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.admin_repondre_demande(
  p_token uuid, p_employe uuid, p_jour date, p_accorde boolean, p_reponse text default null)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes; v_p public.pointages; v_rep text; v_prenom text; v_lot text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_accorde is null then
    return jsonb_build_object('ok', false, 'erreur', 'Choisissez accorder ou refuser');
  end if;
  perform public._verrou_pointages(p_employe);
  select * into v_p from public.pointages
    where employe_id = p_employe and jour = p_jour for update;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Journée introuvable');
  end if;
  if v_p.demande_etat is distinct from 'attente' then
    return jsonb_build_object('ok', false, 'erreur', 'Aucune demande en attente sur ce jour');
  end if;
  v_rep := nullif(left(trim(coalesce(p_reponse, '')), 300), '');
  select prenom into v_prenom from public.employes where id = p_employe;

  perform set_config('horaires.acteur', v_emp.id::text, true);
  -- Accorder, c'est rouvrir la journée. Le déverrouillage est déjà raconté par
  -- la ligne « deblocage_accorde » : on fait taire celle du déclencheur.
  v_lot := coalesce(current_setting('horaires.lot', true), '0');
  perform set_config('horaires.lot', '1', true);
  update public.pointages set
    demande_etat = case when p_accorde then 'accordee' else 'refusee' end,
    demande_reponse = v_rep, demande_repondu_le = now(), demande_repondu_par = v_emp.id,
    -- La confirmation est dérivée de saisi_par = employe_id. La retirer rouvre
    -- un cycle : correction, nouvelle confirmation, puis approbation du BO.
    saisi_par    = case when p_accorde then null else saisi_par end,
    approuve     = case when p_accorde then false else approuve end,
    approuve_le  = case when p_accorde then null  else approuve_le end,
    approuve_par = case when p_accorde then null  else approuve_par end
  where id = v_p.id;
  perform set_config('horaires.lot', v_lot, true);

  if not public._demo(p_employe) then
    perform public._journal(v_emp.id,
    case when p_accorde then 'deblocage_accorde' else 'deblocage_refuse' end,
    to_char(p_jour, 'DD.MM.YYYY'),
    jsonb_build_object('employe', v_prenom, 'motif', v_p.demande_motif, 'reponse', v_rep,
      'etait_confirme', coalesce(v_p.saisi_par = p_employe, false),
      'etait_approuve', v_p.approuve));
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
    if p_approuve and exists (select 1 from public.pointages
        where employe_id = p_employe and jour = p_jour
          and not approuve and saisi_par is distinct from employe_id) then
      return jsonb_build_object('ok', false, 'code', 'confirmation_requise', 'erreur',
        'Le collaborateur doit confirmer cette journée avant votre approbation');
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
    if p_approuve and exists (select 1 from public.pointages
        where employe_id = p_employe and jour >= v_debut and jour < v_debut + interval '1 month'
          and not approuve and saisi_par is distinct from employe_id) then
      return jsonb_build_object('ok', false, 'code', 'confirmation_requise', 'erreur',
        'Des journées restent à confirmer par le collaborateur — aucune approbation effectuée');
    end if;
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

create or replace function public._trg_journal_pointages()
returns trigger language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_acteur uuid; v_par text; v_horaire text; v_emp text;
  v_avant jsonb; v_apres jsonb; v_champs text[] := '{}'; v_ctx jsonb;
begin
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
  v_apres  := public._ptg_resume(new.matin_type, new.matin_debut, new.matin_fin,
                                 new.apm_type, new.apm_debut, new.apm_fin, new.remarque);
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

  v_avant := public._ptg_resume(old.matin_type, old.matin_debut, old.matin_fin,
                                old.apm_type, old.apm_debut, old.apm_fin, old.remarque);

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
end $function$;
create or replace function public.admin_supprimer_jour(p_token uuid, p_employe uuid, p_jour date)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  perform public._verrou_pointages(p_employe);
  perform set_config('horaires.acteur', v_emp.id::text, true);
  delete from public.pointages where employe_id = p_employe and jour = p_jour;
  return jsonb_build_object('ok', true);
end $function$;

-- Les RPC restent accessibles uniquement via le rôle anon et leur jeton métier.
-- Les helpers demeurent inaccessibles depuis la Data API.
revoke execute on function public._save_jour(uuid, date, text, text, text, text, text, text, text, boolean, uuid)
  from anon, authenticated, public;
revoke execute on function public._trg_journal_pointages() from anon, authenticated, public;
revoke execute on function public.supprimer_jour(uuid, date) from authenticated, public;
revoke execute on function public.demande_modification(uuid, date, text) from authenticated, public;
revoke execute on function public.admin_repondre_demande(uuid, uuid, date, boolean, text) from authenticated, public;
revoke execute on function public.admin_approuver(uuid, uuid, integer, integer, date, boolean) from authenticated, public;
grant execute on function public.supprimer_jour(uuid, date) to anon;
grant execute on function public.demande_modification(uuid, date, text) to anon;
grant execute on function public.admin_repondre_demande(uuid, uuid, date, boolean, text) to anon;
grant execute on function public.admin_approuver(uuid, uuid, integer, integer, date, boolean) to anon;
