-- Deux corrections sans lesquelles l'affichage « confirmé / posé par le back
-- office » mentirait à la direction. Les deux ont été reproduites sur la base
-- avant correction, puis revérifiées après.
--
-- 1. UNE CORRECTION DE LA DIRECTION N'EFFACE PLUS LA CONFIRMATION DU TECHNICIEN
--    _save_jour écrasait saisi_par à chaque écriture. Reproduit : Sami confirme
--    sa journée (confirme = true), la direction corrige la seule remarque, la
--    journée repasse « non confirmée ». La grille l'aurait signalée en défaut et
--    la relance du soir aurait réclamé au technicien une modification qu'il
--    n'avait pas faite. La confirmation appartient à l'intéressé : elle ne se
--    perd que s'il change lui-même d'avis, pas quand un tiers touche à la ligne.
--
-- 2. « DERNIÈRE CONNEXION » DEVIENT « DERNIÈRE OUVERTURE DE L'APPLICATION »
--    Le champ n'était horodaté qu'à la connexion. Or les sessions durent 90 jours
--    et le jeton reste sur le téléphone : au démarrage, l'application appelle
--    directement mes_pointages sans repasser par connexion_cle. Reproduit :
--    rouvrir l'application ne changeait rien. Un technicien fidèle serait resté
--    affiché « vu » à sa toute première connexion, et la direction en aurait
--    conclu qu'il ne s'en sert pas. mes_pointages horodate donc à son tour.

create or replace function public._save_jour(
  p_employe uuid, p_jour date, p_matin_type text, p_matin_debut text, p_matin_fin text,
  p_apm_type text, p_apm_debut text, p_apm_fin text, p_remarque text, p_admin boolean,
  p_auteur uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_md time; v_mf time; v_ad time; v_af time;
  v_mt text; v_at text; v_rem text;
begin
  if p_jour is null or p_jour < date '2020-01-01' or p_jour > date '2100-12-31' then
    return jsonb_build_object('ok', false, 'erreur', 'Date invalide');
  end if;
  if not p_admin and exists (select 1 from public.pointages
      where employe_id = p_employe and jour = p_jour and approuve) then
    return jsonb_build_object('ok', false, 'erreur', 'Journée validée par la direction — modification impossible');
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
end $$;

create or replace function public.mes_pointages(p_token uuid, p_annee integer, p_mois integer)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
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
  return jsonb_build_object('ok', true, 'employe', public._emp_json(v_emp), 'pointages', v_ptgs);
end $$;
