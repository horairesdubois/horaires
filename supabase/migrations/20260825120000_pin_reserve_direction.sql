-- Le code PIN devient un accès de secours réservé à la direction.
--
-- Tout le monde se connecte par lien personnel (128 bits, hors de portée d'une
-- force brute). Le PIN, lui, s'attaque : connexion() compare le code à tous les
-- comptes autorisés, donc chaque compte gardant un PIN élargit la surface.
-- En le réservant à la direction — seule à avoir besoin d'un secours, puisque
-- personne d'autre ne peut lui régénérer son lien — on ramène cette surface
-- d'un espace partagé par quatre comptes à un seul compte.
--
-- La colonne pin_actif garde le réglage modifiable compte par compte si le
-- besoin change, plutôt que de figer la règle dans le code de connexion.

alter table public.employes add column if not exists pin_actif boolean not null default false;
update public.employes set pin_actif = (role = 'admin');

create or replace function public.connexion(p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_token uuid;
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
    -- Message volontairement identique dans tous les cas : il ne doit pas
    -- révéler quels comptes disposent encore d'un code.
    return jsonb_build_object('ok', false, 'erreur', 'Code PIN incorrect');
  end if;
  delete from public.sessions where expire_le < now();
  insert into public.sessions (employe_id) values (v_emp.id) returning token into v_token;
  return jsonb_build_object('ok', true, 'token', v_token, 'employe', public._emp_json(v_emp));
end $$;
