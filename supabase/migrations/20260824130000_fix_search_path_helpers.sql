-- Fixe le search_path des helpers JSON (recommandation du linter Supabase).

create or replace function public._emp_json(e public.employes)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', e.id, 'prenom', e.prenom, 'nom', e.nom, 'metier', e.metier,
    'role', e.role, 'actif', e.actif,
    'matin_debut_def', to_char(e.matin_debut_def, 'HH24:MI'),
    'matin_fin_def',   to_char(e.matin_fin_def, 'HH24:MI'),
    'apm_debut_def',   to_char(e.apm_debut_def, 'HH24:MI'),
    'apm_fin_def',     to_char(e.apm_fin_def, 'HH24:MI'))
$$;

create or replace function public._ptg_json(p public.pointages)
returns jsonb
language sql stable set search_path = public, extensions
as $$
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
    'approuve_le', to_char(p.approuve_le, 'DD.MM.YYYY'))
$$;

revoke execute on function public._emp_json(public.employes) from public, anon, authenticated;
revoke execute on function public._ptg_json(public.pointages) from public, anon, authenticated;
