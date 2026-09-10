-- Le journal disait « Steve a modifié le 07.09 » sans dire ce qui avait changé,
-- et surtout il le disait à tort : approuver une journée met à jour sa ligne,
-- le déclencheur se réveillait et attribuait la modification à `saisi_par`,
-- c'est-à-dire au technicien. Trois lignes « Steve a modifié » du 08.09
-- correspondaient en réalité, à la minute près, aux approbations du back office.
--
-- Cette migration règle les deux choses : qui a agi, et ce qui a bougé.
--   1. l'acteur réel voyage dans `horaires.acteur` (déjà utilisé par les messages)
--      plutôt que d'être déduit de `saisi_par`, qui appartient au technicien ;
--   2. une mise à jour est classée : contenu changé -> `modification` avec
--      l'avant et l'après ; approbation seule -> `validation` / `deverrouillage` ;
--      confirmation seule -> `confirmation`.

-- Une demi-journée en clair : « 08:00–12:00 », ou le motif d'absence.
create or replace function public._demi_txt(p_t text, p_d time, p_f time)
returns text language sql immutable
set search_path to 'public', 'extensions'
as $$
  select case
    when coalesce(p_t, 'travail') <> 'travail' then
      coalesce((select x.lib from (values
        ('vacances','Vacances'), ('maladie','Maladie'), ('accident','Accident'),
        ('ferie','Férié'), ('armee','Armée / PC'), ('ecole','Formation'),
        ('conge_np','Congé non payé'), ('autre','Autre')) as x(k, lib)
        where x.k = p_t), p_t)
    when p_d is null and p_f is null then '—'
    else coalesce(to_char(p_d, 'HH24:MI'), '?') || '–' || coalesce(to_char(p_f, 'HH24:MI'), '?')
  end
$$;

create or replace function public._demi_min(p_t text, p_d time, p_f time)
returns int language sql immutable
set search_path to 'public', 'extensions'
as $$
  select case
    when coalesce(p_t, 'travail') = 'travail' and p_d is not null and p_f is not null
      then greatest(0, (extract(epoch from (p_f - p_d)) / 60)::int)
    else 0 end
$$;

-- L'état d'une journée en un objet comparable : deux demi-journées, le total
-- en minutes, la remarque. Comparer deux résumés dit s'il y a eu un vrai
-- changement de contenu — et lequel.
create or replace function public._ptg_resume(
  p_mt text, p_md time, p_mf time, p_at text, p_ad time, p_af time, p_rem text)
returns jsonb language sql immutable
set search_path to 'public', 'extensions'
as $$
  select jsonb_build_object(
    'm',   public._demi_txt(p_mt, p_md, p_mf),
    'a',   public._demi_txt(p_at, p_ad, p_af),
    'min', public._demi_min(p_mt, p_md, p_mf) + public._demi_min(p_at, p_ad, p_af),
    'rem', left(coalesce(p_rem, ''), 200))
$$;

-- Ces trois helpers suivent la règle de la maison : rien en `public._%` n'est
-- appelable depuis Internet.
revoke execute on function public._demi_txt(text, time, time) from anon, authenticated, public;
revoke execute on function public._demi_min(text, time, time) from anon, authenticated, public;
revoke execute on function public._ptg_resume(text, time, time, text, time, time, text)
  from anon, authenticated, public;

create or replace function public._trg_journal_pointages()
returns trigger language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_acteur uuid; v_par text; v_horaire text; v_emp text;
  v_avant jsonb; v_apres jsonb; v_champs text[] := '{}';
begin
  if tg_op = 'DELETE' then
    if public._demo(old.employe_id) or public._demo(old.saisi_par) then return old; end if;
    v_acteur := coalesce(nullif(current_setting('horaires.acteur', true), '')::uuid, old.saisi_par);
    perform public._journal(v_acteur, 'suppression', to_char(old.jour, 'DD.MM.YYYY'),
      jsonb_build_object(
        'employe', (select prenom from public.employes where id = old.employe_id),
        'avant', public._ptg_resume(old.matin_type, old.matin_debut, old.matin_fin,
                                    old.apm_type, old.apm_debut, old.apm_fin, old.remarque)));
    return old;
  end if;

  if public._demo(new.employe_id) or public._demo(new.saisi_par) then return new; end if;

  -- L'acteur réel est celui que la fonction appelante a annoncé. `saisi_par`
  -- appartient au technicien et survit aux écritures du back office : s'en
  -- servir comme auteur, c'était mettre les approbations du patron sur son dos.
  v_acteur := coalesce(nullif(current_setting('horaires.acteur', true), '')::uuid, new.saisi_par);
  v_emp    := (select prenom from public.employes where id = new.employe_id);
  v_par    := case when v_acteur = new.employe_id then 'technicien' else 'back office' end;
  v_horaire := case
    when coalesce((to_jsonb(new)->>'prerempli')::boolean, false) then 'type' else 'tapé' end;
  v_apres  := public._ptg_resume(new.matin_type, new.matin_debut, new.matin_fin,
                                 new.apm_type, new.apm_debut, new.apm_fin, new.remarque);

  if tg_op = 'INSERT' then
    perform public._journal(v_acteur, 'saisie', to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', v_emp, 'par', v_par, 'horaire', v_horaire,
                         'apres', v_apres));
    return new;
  end if;

  v_avant := public._ptg_resume(old.matin_type, old.matin_debut, old.matin_fin,
                                old.apm_type, old.apm_debut, old.apm_fin, old.remarque);

  -- 1. Le contenu a bougé : c'est la seule vraie « modification », et on dit
  --    d'où l'on vient, où l'on va, et combien de minutes cela fait.
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
        -- Modifier une journée déjà approuvée, c'est l'événement qu'on ne veut
        -- surtout pas manquer.
        'etait_approuve', coalesce(old.approuve, false)));
    return new;
  end if;

  -- 2. Seule l'approbation a bougé. Le lot d'un mois entier se résume en une
  --    ligne côté admin_approuver plutôt qu'en trente ici.
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

  -- 3. Ni le contenu ni l'approbation : le technicien a confirmé telle quelle
  --    une journée posée par le back office.
  if new.saisi_par is distinct from old.saisi_par and new.saisi_par = new.employe_id then
    perform public._journal(v_acteur, 'confirmation', to_char(new.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', v_emp, 'apres', v_apres));
  end if;
  return new;
end $function$;

-- Les appelants annoncent qui agit réellement, avant toute écriture.
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

  -- Qui écrit, pour le journal. `p_auteur` est le technicien pour lui-même,
  -- l'admin quand il saisit à la place de quelqu'un.
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
    -- La confirmation appartient au technicien : une écriture de sa part la pose,
    -- une écriture d'un tiers ne la retire pas.
    saisi_par = case
      when excluded.saisi_par = public.pointages.employe_id then excluded.saisi_par
      when public.pointages.saisi_par = public.pointages.employe_id then public.pointages.saisi_par
      else excluded.saisi_par
    end;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.admin_approuver(
  p_token uuid, p_employe uuid, p_annee integer, p_mois integer, p_jour date, p_approuve boolean)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_emp public.employes; v_debut date; v_n int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  perform set_config('horaires.acteur', v_emp.id::text, true);

  if p_jour is not null then
    update public.pointages set
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
    -- Un mois validé d'un geste, c'est une ligne de journal, pas trente.
    perform set_config('horaires.lot', '1', true);
    update public.pointages set
      approuve = p_approuve,
      approuve_le = case when p_approuve then now() else null end,
      approuve_par = case when p_approuve then v_emp.id else null end
    where employe_id = p_employe and jour >= v_debut and jour < v_debut + interval '1 month'
      and approuve is distinct from p_approuve;
    get diagnostics v_n = row_count;
    perform set_config('horaires.lot', '0', true);
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
  perform set_config('horaires.acteur', v_emp.id::text, true);
  delete from public.pointages where employe_id = p_employe and jour = p_jour;
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.supprimer_jour(p_token uuid, p_jour date)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then return jsonb_build_object('ok', false, 'erreur', 'session'); end if;
  if exists (select 1 from public.pointages
      where employe_id = v_emp.id and jour = p_jour and approuve) then
    return jsonb_build_object('ok', false, 'erreur', 'Journée validée par le back office — suppression impossible');
  end if;
  perform set_config('horaires.acteur', v_emp.id::text, true);
  delete from public.pointages where employe_id = v_emp.id and jour = p_jour;
  return jsonb_build_object('ok', true);
end $function$;
