-- Le back office doit pouvoir constater, sans quitter son tableau, si une
-- journée a été confirmée par le technicien ou seulement posée à sa place, et
-- si l'intéressé s'est connecté.
--
-- Les pointages portaient déjà « confirme » (voir 20260825150000). Manquaient
-- deux informations côté administration :
--   * la dernière connexion de chaque collaborateur ;
--   * la date à partir de laquelle l'auteur des saisies est connu — sans elle,
--     l'interface signalerait comme « non confirmés » des mois entiers repris
--     de l'historique, où saisi_par est NULL par construction.
--
-- « aujourdhui » est renvoyé par le serveur plutôt que lu sur le poste : le
-- téléphone d'un collaborateur peut être mal réglé, et la notion de « connecté
-- aujourd'hui » doit s'appuyer sur l'heure de Genève, pas sur celle du client.

create or replace function public._emp_json_admin(e public.employes)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select public._emp_json(e) || jsonb_build_object(
    'cle', e.cle_acces,
    'derniere_connexion',
      to_char(e.derniere_connexion at time zone 'Europe/Zurich', 'YYYY-MM-DD"T"HH24:MI'))
$$;
revoke execute on function public._emp_json_admin(public.employes) from anon, authenticated, public;

create or replace function public.admin_donnees(p_token uuid, p_annee integer, p_mois integer)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
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
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl,
    'tracabilite_depuis', to_char(v_depuis, 'YYYY-MM-DD'),
    'aujourdhui', to_char((now() at time zone 'Europe/Zurich')::date, 'YYYY-MM-DD'));
end $$;
