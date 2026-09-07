-- Journal complet : tout ce que quelqu'un a fait.
--
-- CE QUI MANQUAIT
-- Le journal voyait les écritures sur les pointages et les messages, les
-- connexions et les ouvertures. Il ne voyait ni les déconnexions, ni les
-- bulletins déposés, téléchargés ou supprimés, ni les modifications de fiche,
-- ni les réglages, ni le fait qu'un message ait été lu.
--
-- CE QU'UN DÉCLENCHEUR PEUT ET NE PEUT PAS DIRE
-- Il voit la ligne, donc l'action ; il ne voit pas la session, donc l'auteur —
-- sauf quand la table le porte elle-même (saisi_par, auteur_id, employe_id).
-- Pour les gestes d'administration, seule la direction peut les accomplir : on
-- inscrit « Direction » plutôt que de deviner lequel des administrateurs.
--
-- CE QUI N'EST JAMAIS ÉCRIT
-- Ni empreinte de code PIN, ni clé d'accès, ni contenu de bulletin. Le journal
-- dit qu'un secret a changé, jamais sa valeur : une trace qui recopie les
-- secrets devient elle-même la faille qu'elle surveille.

-- ---------------------------------------------------------------- déconnexion

create or replace function public._trg_journal_deconnexion()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._journal(old.employe_id, 'deconnexion', '', '{}'::jsonb);
  return old;
end $$;

drop trigger if exists journal_deconnexion on public.sessions;
create trigger journal_deconnexion
  after delete on public.sessions
  for each row execute function public._trg_journal_deconnexion();

-- ---------------------------------------------------------------- bulletins

create or replace function public._trg_journal_bulletins()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_l public.bulletins;
begin
  v_l := case when tg_op = 'DELETE' then old else new end;
  -- La table porte depose_par : l'auteur est connu, on le nomme plutôt que de
  -- se rabattre sur « Back office ».
  perform public._journal(v_l.depose_par,
    case when tg_op = 'DELETE' then 'bulletin_supprime' else 'bulletin_depose' end,
    coalesce((select prenom from public.employes where id = v_l.employe_id), '?'),
    jsonb_build_object('periode', lpad(v_l.mois::text, 2, '0') || '.' || v_l.annee::text,
                       'fichier', v_l.nom_fichier));
  return v_l;
end $$;

drop trigger if exists journal_bulletins on public.bulletins;
create trigger journal_bulletins
  after insert or delete on public.bulletins
  for each row execute function public._trg_journal_bulletins();

-- ---------------------------------------------------------------- fiches

/**
 * Modification d'une fiche collaborateur. On compare les deux versions de la
 * ligne pour ne nommer que ce qui a bougé — et on ne nomme QUE le champ, jamais
 * sa valeur, dès qu'il touche à un secret.
 */
create or replace function public._trg_journal_employe()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_champs text[]; v_detail jsonb;
begin
  select array_agg(o.key order by o.key)
    into v_champs
    from jsonb_each_text(to_jsonb(old)) o
    join jsonb_each_text(to_jsonb(new)) n on n.key = o.key
   where o.value is distinct from n.value
     and o.key not in ('derniere_connexion', 'cree_le');

  if v_champs is null then return new; end if;

  select jsonb_object_agg(c, case when c in ('pin_hash', 'cle_acces')
                                  then to_jsonb('— modifié —'::text)
                                  else to_jsonb(new_j.valeur) end)
    into v_detail
    from unnest(v_champs) as c
    join lateral (select to_jsonb(new) ->> c as valeur) new_j on true;

  insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
  values (null, 'Direction', 'admin', 'fiche_modifiee', new.prenom,
          coalesce(v_detail, '{}'::jsonb));
  return new;
end $$;

drop trigger if exists journal_employe on public.employes;
create trigger journal_employe
  after update on public.employes
  for each row execute function public._trg_journal_employe();

-- ---------------------------------------------------------------- réglages

create or replace function public._trg_journal_parametre()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if tg_op = 'UPDATE' and old.valeur is not distinct from new.valeur then
    return new;
  end if;
  insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
  values (null, 'Direction', 'admin', 'reglage_modifie', new.cle,
          -- Un secret de contrôle ne se recopie pas dans le journal.
          case when new.cle like '%secret%' or new.cle like '%cle%'
               then jsonb_build_object('valeur', '— modifiée —')
               else jsonb_build_object('valeur', left(new.valeur, 80)) end);
  return new;
end $$;

drop trigger if exists journal_parametre on public.parametres;
create trigger journal_parametre
  after insert or update on public.parametres
  for each row execute function public._trg_journal_parametre();

-- ---------------------------------------------------------------- messages lus

-- Savoir qu'un message a été lu, et par qui, referme la boucle : la direction
-- cesse de se demander si le technicien l'a vu.
create or replace function public._trg_journal_messages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if tg_op = 'UPDATE' then
    if new.texte is distinct from old.texte or new.jour is distinct from old.jour then
      perform public._journal(new.auteur_id, 'message_modifie',
        coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
        jsonb_build_object('avant', left(old.texte, 80), 'apres', left(new.texte, 80)));
      return new;
    end if;
    if not old.lu_employe and new.lu_employe and new.employe_id is not null then
      perform public._journal(new.employe_id, 'message_lu', '',
        jsonb_build_object('extrait', left(new.texte, 80)));
    elsif not old.lu_direction and new.lu_direction then
      insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
      values (null, 'Direction', 'admin', 'message_lu',
              coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
              jsonb_build_object('extrait', left(new.texte, 80)));
    elsif not old.lu_compta and new.lu_compta then
      insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
      values (null, 'La fiduciaire', 'compta', 'message_lu',
              coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
              jsonb_build_object('extrait', left(new.texte, 80)));
    end if;
    return new;
  end if;
  perform public._journal(new.auteur_id,
    case when new.automatique then 'message_auto' else 'message' end,
    coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
    jsonb_build_object('extrait', left(new.texte, 80)));
  return new;
end $$;

-- ---------------------------------------------------------------- lecture

/**
 * Fenêtre en jours civils genevois, et non en tranches de vingt-quatre heures :
 * « aujourd'hui » doit vouloir dire depuis minuit, pas depuis hier à la même
 * heure. p_jours = 1 rend la journée en cours.
 */
create or replace function public.journal_lire(
  p_token uuid, p_jours int default 30, p_limite int default 300, p_acteur uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_j int; v_l int; v_depuis timestamptz;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'Accès refusé');
  end if;
  v_j := least(greatest(coalesce(p_jours, 30), 1), 400);
  v_l := least(greatest(coalesce(p_limite, 300), 1), 2000);
  v_depuis := (date_trunc('day', now() at time zone 'Europe/Zurich')
               - make_interval(days => v_j - 1)) at time zone 'Europe/Zurich';

  return jsonb_build_object(
    'ok', true, 'jours', v_j,
    'acteurs', coalesce((
      select jsonb_agg(a order by a->>'nom')
        from (
          select distinct on (j.acteur_id) jsonb_build_object(
                   'id', j.acteur_id,
                   'nom', case when j.acteur_role = 'compta' then 'La fiduciaire' else j.acteur_nom end,
                   'role', j.acteur_role,
                   'nb', count(*) over (partition by j.acteur_id)) as a
            from public.journal j
           where j.quand >= v_depuis and j.acteur_id is not null
        ) t), '[]'::jsonb),
    'lignes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', j.id, 'acteur_id', j.acteur_id,
               'jour', to_char(j.quand at time zone 'Europe/Zurich', 'DD.MM.YYYY'),
               'heure', to_char(j.quand at time zone 'Europe/Zurich', 'HH24:MI'),
               'qui', case when j.acteur_role = 'compta' then 'La fiduciaire' else j.acteur_nom end,
               'role', j.acteur_role,
               'action', j.action, 'cible', j.cible, 'detail', j.detail)
             order by j.quand desc)
        from (select * from public.journal
               where quand >= v_depuis
                 and (p_acteur is null or acteur_id = p_acteur)
               order by quand desc limit v_l) j), '[]'::jsonb));
end $$;
revoke execute on function public.journal_lire(uuid, int, int, uuid) from public, authenticated;
grant execute on function public.journal_lire(uuid, int, int, uuid) to anon;
