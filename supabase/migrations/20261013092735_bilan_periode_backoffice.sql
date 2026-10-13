-- Lecture d'une période indépendante du mois affiché, réservée au back-office.
create or replace function public.admin_bilan_periode(p_token uuid,p_employe uuid,p_debut date,p_fin date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare acteur public.employes; lignes jsonb;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role<>'admin' then
  return jsonb_build_object('ok',false,'erreur','Accès réservé au back-office');
 end if;
 if p_debut is null or p_fin is null or p_debut>p_fin or p_debut<date '2020-01-01'
    or p_fin>date '2100-12-31' or p_fin-p_debut>3660 then
  return jsonb_build_object('ok',false,'erreur','Choisissez une période valide de dix ans maximum, entre 2020 et 2100');
 end if;
 if not exists(select 1 from public.employes where id=p_employe and role<>'compta' and not coalesce(demo,false)) then
  return jsonb_build_object('ok',false,'erreur','Collaborateur introuvable');
 end if;
 select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour),'[]'::jsonb) into lignes
 from public.pointages p where p.employe_id=p_employe and p.jour between p_debut and p_fin;
 return jsonb_build_object('ok',true,'employe_id',p_employe,'debut',p_debut,'fin',p_fin,
  'aujourdhui',(clock_timestamp() at time zone 'Europe/Zurich')::date,'pointages',lignes);
end $$;
revoke all on function public.admin_bilan_periode(uuid,uuid,date,date) from public,authenticated;
grant execute on function public.admin_bilan_periode(uuid,uuid,date,date) to anon;
