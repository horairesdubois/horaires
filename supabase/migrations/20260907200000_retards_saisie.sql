-- Savoir qui a décroché, sans écrire à personne.
--
-- POURQUOI PAS UN RAPPEL
-- Les rappels automatiques ont été coupés, et à raison : ils harcelaient les
-- techniciens tous les jours pour un oubli d'une demi-journée. Mais le suivi
-- quotidien reste nécessaire — savoir qui avance, et qui a décroché.
--
-- La réponse n'est donc pas un message de plus. C'est un indicateur muet, dans
-- l'écran du back office et nulle part ailleurs : le technicien ne le voit pas,
-- ne reçoit rien, et n'apprend même pas qu'il existe. C'est au back office de
-- décider s'il faut en parler, et comment.
--
-- CE QU'ON COMPTE, ET CE QU'ON NE COMPTE PAS
-- Des jours OUVRÉS, jamais des jours civils : sans cela, tout le monde serait
-- « en retard de deux jours » chaque lundi matin. Les samedis, dimanches et
-- jours fériés genevois sont donc écartés, et le jour même aussi — un technicien
-- saisit sa journée le soir, la lui reprocher à midi n'aurait aucun sens.
--
-- La fenêtre est de trois semaines. Au-delà, ce n'est plus un oubli à rattraper
-- mais une absence dont le back office est déjà au courant.

create or replace function public.retards_saisie(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_auj date; v_debut date; v_r jsonb;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'Acces refuse');
  end if;

  v_auj := (now() at time zone 'Europe/Zurich')::date;
  v_debut := v_auj - 21;

  select coalesce(jsonb_agg(x order by (x->>'manquants')::int desc, x->>'prenom'), '[]'::jsonb)
    into v_r
    from (
      select jsonb_build_object(
               'employe_id', e.id,
               'prenom',     e.prenom,
               'manquants',  (select count(*)
                                from generate_series(v_debut, v_auj - 1, interval '1 day') g(j)
                               where extract(isodow from g.j) between 1 and 5
                                 and g.j::date not in (
                                       select public.feries_ge(extract(year from g.j)::int))
                                 and not exists (select 1 from public.pointages p
                                                  where p.employe_id = e.id and p.jour = g.j::date)),
               'dernier',    (select to_char(max(p.jour), 'YYYY-MM-DD')
                                from public.pointages p where p.employe_id = e.id)
             ) as x
        from public.employes e
       where e.role = 'employe' and e.actif
    ) s
   where (x->>'manquants')::int > 0;

  return jsonb_build_object('ok', true, 'retards', v_r,
                            'aujourdhui', to_char(v_auj, 'YYYY-MM-DD'));
end $$;
revoke execute on function public.retards_saisie(uuid) from public, authenticated;
grant execute on function public.retards_saisie(uuid) to anon;
