-- Export partiel : aucune modification des pointages ni du verrouillage du mois.
create or replace function public.pointage_exporter_valides(p_token uuid,p_annee integer,p_mois integer,p_employes uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acteur public.employes; debut date; fin date; donnees jsonb;
 auj date := (clock_timestamp() at time zone 'Europe/Zurich')::date;
begin
 acteur:=public._auth(p_token);
 if acteur.id is null or acteur.role not in ('admin','compta') then return jsonb_build_object('ok',false,'erreur','Accès refusé'); end if;
 debut:=make_date(p_annee,p_mois,1); fin:=(debut+interval '1 month')::date;
 select coalesce(jsonb_agg(public._ptg_json(p) order by p.employe_id,p.jour),'[]'::jsonb)
 into donnees
 from public.pointages p join public.employes e on e.id=p.employe_id
 where p.jour>=debut and p.jour<fin and p.jour<=auj
 and p.employe_id=any(p_employes) and not e.demo and p.approuve
 and (p.pointe_etat is null or p.pointe_etat='termine')
 and not (p.matin_type='travail' and (p.matin_debut is null)<>(p.matin_fin is null))
 and not (p.apm_type='travail' and (p.apm_debut is null)<>(p.apm_fin is null))
 and not exists(select 1 from public.pointage_corrections c where c.employe_id=p.employe_id and c.jour=p.jour and c.etat='attente');
 return jsonb_build_object('ok',true,'pointages',donnees,'aujourdhui',auj,'instantane',clock_timestamp());
end $$;
revoke all on function public.pointage_exporter_valides(uuid,integer,integer,uuid[]) from public,authenticated;
grant execute on function public.pointage_exporter_valides(uuid,integer,integer,uuid[]) to anon;
