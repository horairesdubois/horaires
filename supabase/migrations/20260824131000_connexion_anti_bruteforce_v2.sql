-- Durcit le garde-fou anti-force-brute de connexion() :
-- 1. le compteur est cloisonné par adresse IP (un attaquant ne bloque plus
--    les connexions de toute l'entreprise) avec un plafond global en filet ;
-- 2. la tentative est insérée AVANT le comptage (le comptage inclut donc
--    toujours la requête courante : plus de contournement par concurrence).

alter table public.tentatives add column if not exists ip text not null default '';
create index if not exists tentatives_quand_idx on public.tentatives (quand);

create or replace function public.connexion(p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_token uuid; v_ip text; v_recentes int; v_total int;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok', false, 'erreur', 'Le code PIN doit comporter 4 à 8 chiffres');
  end if;
  v_ip := coalesce((current_setting('request.headers', true))::json->>'x-forwarded-for', '');
  insert into public.tentatives (ip) values (v_ip);
  delete from public.tentatives where quand < now() - interval '1 day';
  select count(*) into v_recentes from public.tentatives
   where quand > now() - interval '1 minute' and ip = v_ip;
  select count(*) into v_total from public.tentatives
   where quand > now() - interval '1 minute';
  if v_recentes > 20 or v_total > 200 then
    return jsonb_build_object('ok', false, 'erreur', 'Trop de tentatives. Réessayez dans une minute.');
  end if;
  select e.* into v_emp from public.employes e
   where e.actif and e.pin_hash = extensions.crypt(p_pin, e.pin_hash)
   limit 1;
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Code PIN incorrect');
  end if;
  delete from public.sessions where expire_le < now();
  insert into public.sessions (employe_id) values (v_emp.id) returning token into v_token;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $$;
