-- Cloisonnement du lien magique (cle_acces) : réservé à la direction.
--
-- Problème : _emp_json exposait le champ 'cle' (lien de connexion personnel) pour
-- chaque employé. compta_donnees s'en sert pour lister l'équipe → la fiduciaire,
-- pourtant en lecture seule, recevait dans le JSON de son navigateur le lien
-- d'accès de chaque technicien ET de la direction. Avec le lien de la direction,
-- un compte comptable pouvait se connecter en administrateur (escalade de
-- privilège). Le champ n'était affiché nulle part côté fiduciaire, mais il était
-- présent dans la réponse réseau — donc récupérable via les outils du navigateur.
--
-- Correctif : _emp_json ne renvoie plus la clé. Seule la direction, qui gère les
-- liens depuis l'onglet Employés, la reçoit via une sérialisation dédiée utilisée
-- uniquement par admin_donnees.

create or replace function public._emp_json(e public.employes)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', e.id, 'prenom', e.prenom, 'nom', e.nom, 'metier', e.metier,
    'role', e.role, 'actif', e.actif, 'cct', e.cct,
    'matin_debut_def', to_char(e.matin_debut_def, 'HH24:MI'),
    'matin_fin_def',   to_char(e.matin_fin_def, 'HH24:MI'),
    'apm_debut_def',   to_char(e.apm_debut_def, 'HH24:MI'),
    'apm_fin_def',     to_char(e.apm_fin_def, 'HH24:MI'))
$$;

-- Sérialisation réservée à la direction : ajoute le lien personnel.
create or replace function public._emp_json_admin(e public.employes)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select public._emp_json(e) || jsonb_build_object('cle', e.cle_acces)
$$;
revoke execute on function public._emp_json_admin(public.employes) from anon, authenticated, public;

-- Seul admin_donnees renvoie les liens (boutons « Lien » de l'onglet Employés).
create or replace function public.admin_donnees(p_token uuid, p_annee integer, p_mois integer)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb; v_entreprise text; v_nl int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._emp_json_admin(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e;
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_direction;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl);
end $$;
