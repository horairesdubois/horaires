-- Un message non lu doit être trouvable, et ne doit pas se marquer lu tout seul.
--
-- DEUX DÉFAUTS, DE NATURES DIFFÉRENTES
--
-- 1. LE MESSAGE DU MOIS COURANT SE MARQUAIT LU À L'OUVERTURE DE L'APPLICATION.
--    chargerMsgEmp() est appelée au chargement des données du technicien, et
--    messages_lire marquait lu avant de compter. Un message arrivé le matin
--    était donc « lu » dès qu'il ouvrait l'application pour pointer, sans qu'il
--    ait pu le voir : la pastille ne s'allumait jamais. Le marquage quitte donc
--    la lecture pour devenir un geste explicite — messages_marquer_lus, appelée
--    quand la carte des questions est réellement à l'écran.
--
-- 2. LE MESSAGE D'UN AUTRE MOIS RESTAIT INTROUVABLE.
--    Le compteur ignore le mois ; la vue est filtrée dessus. Le technicien
--    ouvre septembre, voit une pastille rouge, et un fil vide. La direction a
--    vécu exactement la même chose dans l'autre sens. messages_lire renvoie
--    donc « autres_mois » : où sont les non-lus qu'on ne peut pas voir d'ici.

-- Le paramètre s'ajoute en recréant la fonction. Les deux ordres tiennent dans
-- la même transaction, et p_marquer vaut vrai par défaut : l'application déjà
-- publiée, qui n'envoie que quatre arguments, garde son comportement actuel
-- pendant la mise à jour de l'écran.
drop function if exists public.messages_lire(uuid, integer, integer, uuid);

create or replace function public.messages_lire(
  p_token uuid, p_annee integer, p_mois integer,
  p_employe uuid default null, p_marquer boolean default true)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_msgs jsonb; v_nl int; v_fil uuid; v_fils jsonb; v_autres jsonb;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_fil := case when v_emp.role = 'employe' then v_emp.id else p_employe end;

  if p_marquer then
    if v_emp.role = 'admin' then
      update public.messages set lu_direction = true
       where annee = p_annee and mois = p_mois and employe_id is not distinct from v_fil and not lu_direction;
    elsif v_emp.role = 'compta' then
      update public.messages set lu_compta = true
       where annee = p_annee and mois = p_mois and employe_id is not distinct from v_fil and not lu_compta;
    else
      update public.messages set lu_employe = true
       where annee = p_annee and mois = p_mois and employe_id = v_emp.id and not lu_employe;
    end if;
  end if;

  select coalesce(jsonb_agg(public._msg_json(m) order by m.cree_le), '[]'::jsonb)
    into v_msgs from public.messages m
   where m.annee = p_annee and m.mois = p_mois and m.employe_id is not distinct from v_fil;

  select count(*) into v_nl from public.messages m
   where case v_emp.role
           when 'admin'  then not m.lu_direction
           when 'compta' then not m.lu_compta
           else m.employe_id = v_emp.id and not m.lu_employe
         end;

  -- Où sont les non-lus qu'on ne peut pas atteindre depuis l'écran courant.
  -- Les plus récents d'abord : c'est presque toujours celui-là qu'on cherche.
  select coalesce(jsonb_agg(x order by (x->>'annee')::int desc, (x->>'mois')::int desc), '[]'::jsonb)
    into v_autres from (
      select jsonb_build_object('annee', m.annee, 'mois', m.mois, 'non_lus', count(*)) as x
        from public.messages m
       where (m.annee, m.mois) is distinct from (p_annee, p_mois)
         and case v_emp.role
               when 'admin'  then not m.lu_direction
               when 'compta' then not m.lu_compta
               else m.employe_id = v_emp.id and not m.lu_employe
             end
       group by m.annee, m.mois
    ) s;

  if v_emp.role in ('admin', 'compta') then
    select coalesce(jsonb_agg(x order by x->>'nom'), '[]'::jsonb) into v_fils from (
      select jsonb_build_object(
               'employe_id', m.employe_id,
               'nom', coalesce((select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom)
                                  from public.employes e where e.id = m.employe_id), 'Général'),
               'non_lus', count(*) filter (
                 where case when v_emp.role = 'admin' then not m.lu_direction else not m.lu_compta end)
             ) as x
        from public.messages m
       where m.annee = p_annee and m.mois = p_mois
       group by m.employe_id
    ) s;
  else
    v_fils := '[]'::jsonb;
  end if;

  return jsonb_build_object('ok', true, 'messages', v_msgs, 'non_lus', v_nl,
                            'fils', v_fils, 'fil', v_fil, 'autres_mois', v_autres);
end $$;
revoke execute on function public.messages_lire(uuid, integer, integer, uuid, boolean)
  from public, authenticated;
grant execute on function public.messages_lire(uuid, integer, integer, uuid, boolean) to anon;

/**
 * Marquer lu devient un geste à part, appelé quand la carte des questions est
 * réellement sous les yeux de son destinataire. Charger l'application n'est pas
 * lire.
 */
create or replace function public.messages_marquer_lus(
  p_token uuid, p_annee integer, p_mois integer, p_employe uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_fil uuid; v_n int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_fil := case when v_emp.role = 'employe' then v_emp.id else p_employe end;

  if v_emp.role = 'admin' then
    update public.messages set lu_direction = true
     where annee = p_annee and mois = p_mois and employe_id is not distinct from v_fil and not lu_direction;
  elsif v_emp.role = 'compta' then
    update public.messages set lu_compta = true
     where annee = p_annee and mois = p_mois and employe_id is not distinct from v_fil and not lu_compta;
  else
    update public.messages set lu_employe = true
     where annee = p_annee and mois = p_mois and employe_id = v_emp.id and not lu_employe;
  end if;
  get diagnostics v_n = row_count;

  select count(*) into v_n from public.messages m
   where case v_emp.role
           when 'admin'  then not m.lu_direction
           when 'compta' then not m.lu_compta
           else m.employe_id = v_emp.id and not m.lu_employe
         end;
  return jsonb_build_object('ok', true, 'non_lus', v_n);
end $$;
revoke execute on function public.messages_marquer_lus(uuid, integer, integer, uuid)
  from public, authenticated;
grant execute on function public.messages_marquer_lus(uuid, integer, integer, uuid) to anon;
