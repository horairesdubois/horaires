-- Une fonction interne était joignable depuis Internet.
--
-- CE QUI A ÉTÉ TROUVÉ
-- public._save_jour est le cœur de l'écriture d'une journée : elle ne demande
-- aucun jeton, prend l'employé en paramètre, accepte p_admin (qui contourne le
-- verrou des jours déjà validés) et p_auteur (qui décide de la signature portée
-- au journal). C'est voulu : ses deux appelants, enregistrer_jour et
-- admin_enregistrer_jour, ont déjà vérifié la session et le rôle avant de
-- l'appeler.
--
-- Elle était pourtant accordée au rôle « anon », celui de la clé publique que
-- porte la page publiée — donc lisible par quiconque ouvre le code source. La
-- vérification l'a confirmé en conditions réelles : appelée sans jeton, elle
-- répond. N'importe qui pouvait donc écrire ou récrire la journée de n'importe
-- quel technicien, passer outre une validation du back office, et signer la
-- ligne du nom de quelqu'un d'autre.
--
-- Aucun essai d'écriture n'a été fait sur des données réelles : la preuve a été
-- obtenue avec une date invalide, que la fonction rejette elle-même — ce qui
-- suffit à établir qu'elle s'exécute.
--
-- CE QU'ON POSE
-- Les fonctions internes (préfixe « _ ») ne sont plus accordées à personne
-- d'autre que leur propriétaire. Elles restent appelables par les fonctions
-- publiques, qui sont SECURITY DEFINER et s'exécutent donc sous ce
-- propriétaire : rien ne change pour l'application.
--
-- La règle est écrite en boucle plutôt qu'en liste : une fonction interne
-- ajoutée demain se refermerait toute seule au prochain rejeu, là où une liste
-- l'aurait oubliée.

do $$
declare r record; n int := 0;
begin
  for r in
    select p.oid::regprocedure as f
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname like '\_%'
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute'))
  loop
    execute format('revoke execute on function %s from anon, authenticated, public', r.f);
    raise notice 'fermée : %', r.f;
    n := n + 1;
  end loop;
  raise notice '% fonction(s) interne(s) refermée(s).', n;
end $$;

-- Écrire dans le registre n'est pas un droit de technicien.
--
-- journal_noter ne vérifiait que la session. Un technicien pouvait donc y
-- inscrire de fausses lignes « a exporté » — pas grand-chose en soi, mais un
-- registre que ses sujets peuvent garnir ne prouve plus rien. Seuls le back
-- office et la fiduciaire, dont c'est l'écran, y écrivent.
create or replace function public.journal_noter(
  p_token uuid, p_action text, p_cible text default '', p_detail jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'Acces refuse');
  end if;
  if p_action not in ('export') then
    return jsonb_build_object('ok', false, 'erreur', 'Action non journalisable');
  end if;
  perform public._journal(v_emp.id, p_action, left(coalesce(p_cible, ''), 120),
    jsonb_build_object('n', (p_detail->>'n')::int));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.journal_noter(uuid, text, text, jsonb) from public, authenticated;
grant execute on function public.journal_noter(uuid, text, text, jsonb) to anon;
