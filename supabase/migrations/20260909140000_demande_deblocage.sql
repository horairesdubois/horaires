-- Deux choses liées.
--
-- 1. Une journée validée par le back office était un mur : « modification
--    impossible », et le technicien n'avait plus qu'à téléphoner. Il peut
--    désormais demander l'ouverture, en disant pourquoi ; le back office
--    accorde ou refuse, et toute la chaîne reste dans le journal.
--
-- 2. Le journal gagne ce qui manquait pour contrôler vraiment : le retard de
--    saisie (une journée notée huit jours après n'a pas la même valeur que
--    celle notée le soir même), les heures supplémentaires du jour, l'appareil,
--    et les codes refusés à la connexion.

alter table public.pointages
  add column if not exists demande_etat       text,
  add column if not exists demande_motif      text,
  add column if not exists demande_le         timestamptz,
  add column if not exists demande_reponse    text,
  add column if not exists demande_repondu_le timestamptz,
  add column if not exists demande_repondu_par uuid references public.employes(id);

-- Un appareil, pas une empreinte : de quoi distinguer « saisi depuis le
-- chantier » de « saisi depuis le bureau », sans pister personne.
create or replace function public._appareil()
returns text language sql stable
set search_path to 'public', 'extensions'
as $$
  select case
    when u is null or u = '' then null
    when u ilike '%iphone%' or u ilike '%ipad%' then 'iPhone'
    when u ilike '%android%' then 'Android'
    else 'ordinateur' end
  from (select (current_setting('request.headers', true))::json->>'user-agent' as u) t
$$;

-- Les heures au-delà de la journée normale, calculées comme à l'écran :
-- 4 h dues par demi-journée travaillée, et rien un week-end ou un férié.
create or replace function public._sup_jour(
  p_jour date, p_mt text, p_md time, p_mf time, p_at text, p_ad time, p_af time)
returns int language sql stable
set search_path to 'public', 'extensions'
as $$
  select greatest(0, (public._demi_min(p_mt, p_md, p_mf) + public._demi_min(p_at, p_ad, p_af)) - (
    case when extract(dow from p_jour) between 1 and 5
          and not exists (select 1 from public.feries_ge(extract(year from p_jour)::int) f
                           where f = p_jour)
      then (case when coalesce(p_mt,'travail') = 'travail' then 240 else 0 end)
         + (case when coalesce(p_at,'travail') = 'travail' then 240 else 0 end)
      else 0 end))
$$;

revoke execute on function public._appareil() from anon, authenticated, public;
revoke execute on function public._sup_jour(date, text, time, time, text, time, time)
  from anon, authenticated, public;

-- Le technicien voit l'état de sa demande, le back office aussi.
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
    'approuve_le', to_char(p.approuve_le, 'DD.MM.YYYY'),
    'demande_etat', p.demande_etat,
    'demande_motif', p.demande_motif,
    'demande_le', to_char(p.demande_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'),
    'demande_reponse', p.demande_reponse,
    -- Confirmée = enregistrée par le collaborateur lui-même.
    'confirme', p.saisi_par is not null and p.saisi_par = p.employe_id)
$function$;

-- Le technicien demande l'ouverture d'une journée verrouillée.
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
  select * into v_p from public.pointages where employe_id = v_emp.id and jour = p_jour;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Journée introuvable');
  end if;
  if not coalesce(v_p.approuve, false) then
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

-- Le back office accorde (la journée se rouvre) ou refuse (en disant pourquoi).
create or replace function public.admin_repondre_demande(
  p_token uuid, p_employe uuid, p_jour date, p_accorde boolean, p_reponse text default null)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes; v_p public.pointages; v_rep text; v_prenom text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  select * into v_p from public.pointages where employe_id = p_employe and jour = p_jour;
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
  perform set_config('horaires.lot', '1', true);
  update public.pointages set
    demande_etat = case when p_accorde then 'accordee' else 'refusee' end,
    demande_reponse = v_rep, demande_repondu_le = now(), demande_repondu_par = v_emp.id,
    approuve     = case when p_accorde then false else approuve end,
    approuve_le  = case when p_accorde then null  else approuve_le end,
    approuve_par = case when p_accorde then null  else approuve_par end
  where id = v_p.id;
  perform set_config('horaires.lot', '0', true);

  perform public._journal(v_emp.id,
    case when p_accorde then 'deblocage_accorde' else 'deblocage_refuse' end,
    to_char(p_jour, 'DD.MM.YYYY'),
    jsonb_build_object('employe', v_prenom, 'motif', v_p.demande_motif, 'reponse', v_rep));
  return jsonb_build_object('ok', true);
end $function$;

-- Une journée réécrite solde la demande qui l'avait rouverte.
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
begin
  if p_jour is null or p_jour < date '2020-01-01' or p_jour > date '2100-12-31' then
    return jsonb_build_object('ok', false, 'erreur', 'Date invalide');
  end if;
  if not p_admin and exists (select 1 from public.pointages
      where employe_id = p_employe and jour = p_jour and approuve) then
    return jsonb_build_object('ok', false, 'erreur', 'Journée validée par le back office — modification impossible');
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
    delete from public.pointages where employe_id = p_employe and jour = p_jour;
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
    -- La correction faite, la demande a rempli son office.
    demande_etat = null, demande_motif = null, demande_le = null,
    demande_reponse = null, demande_repondu_le = null, demande_repondu_par = null,
    saisi_par = case
      when excluded.saisi_par = public.pointages.employe_id then excluded.saisi_par
      when public.pointages.saisi_par = public.pointages.employe_id then public.pointages.saisi_par
      else excluded.saisi_par
    end;
  return jsonb_build_object('ok', true);
end $function$;

-- Le déclencheur gagne le retard de saisie, les heures en plus et l'appareil.
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

  if new.saisi_par is distinct from old.saisi_par and new.saisi_par = new.employe_id then
    perform public._journal(v_acteur, 'confirmation', to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', v_emp, 'apres', v_apres) || v_ctx);
  end if;
  return new;
end $function$;

-- Un code refusé ne laissait aucune trace : un essai de codes passait donc
-- inaperçu. On le note, sans jamais écrire le code essayé, et groupé par
-- tranche de dix minutes pour qu'un martèlement ne noie pas le journal.
create or replace function public.connexion(p_pin text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes; v_token uuid; v_n int;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,10}$' then
    return jsonb_build_object('ok', false, 'erreur', 'Le code PIN doit comporter 4 à 10 chiffres');
  end if;
  if public._limiter('pin', 3, 10) then
    return jsonb_build_object('ok', false, 'erreur', 'Trop de tentatives. Réessayez dans une minute.');
  end if;
  select e.* into v_emp from public.employes e
   where e.actif and e.pin_actif and e.pin_hash = extensions.crypt(p_pin, e.pin_hash)
   limit 1;
  if v_emp.id is null then
    select count(*) into v_n from public.tentatives
     where genre = 'pin' and quand > now() - interval '10 minutes';
    if not exists (select 1 from public.journal
                    where action = 'connexion_echouee' and quand > now() - interval '10 minutes') then
      perform public._journal(null, 'connexion_echouee', '',
        jsonb_build_object('n', v_n, 'appareil', public._appareil()));
    end if;
    return jsonb_build_object('ok', false, 'erreur', 'Code PIN incorrect');
  end if;
  delete from public.sessions where expire_le < now();
  insert into public.sessions (employe_id) values (v_emp.id) returning token into v_token;
  update public.employes set derniere_connexion = now() where id = v_emp.id;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $function$;
