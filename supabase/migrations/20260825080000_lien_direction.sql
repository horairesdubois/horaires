-- Lien personnel pour tous les accès, direction comprise.
--
-- 1. La régénération d'un lien ne se limitait qu'aux employés : la direction et
--    la fiduciaire n'avaient aucun moyen de renouveler le leur depuis
--    l'interface. Elle couvre désormais les trois rôles.
-- 2. Régénérer son propre lien ne déconnecte plus la personne qui le fait :
--    seules les autres sessions du compte sont fermées (c'est bien elles que
--    l'on veut invalider quand un lien a fuité).
create or replace function public.admin_regenerer_cle(p_token uuid, p_employe uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_cle text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  update public.employes set cle_acces = encode(extensions.gen_random_bytes(16), 'hex')
   where id = p_employe and role in ('employe', 'compta', 'admin')
   returning cle_acces into v_cle;
  if v_cle is null then
    return jsonb_build_object('ok', false, 'erreur', 'Accès introuvable');
  end if;
  delete from public.sessions where employe_id = p_employe and token <> p_token;
  return jsonb_build_object('ok', true, 'cle', v_cle);
end $$;
