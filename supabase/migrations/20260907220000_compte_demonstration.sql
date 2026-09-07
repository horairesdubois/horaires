-- Un compte de démonstration, que le journal ne voit pas.
--
-- LE BESOIN
-- Ouvrir le lien d'un technicien pour vérifier un écran, c'est se faire passer
-- pour lui : la connexion, l'ouverture, la saisie, tout part au journal sous son
-- nom. On ne peut plus distinguer ce qu'il a fait de ce qu'on a fait à sa place,
-- et le registre perd exactement ce qui en fait la valeur.
--
-- LA RÉPONSE
-- Un compte marqué « démonstration ». Il se connecte comme un technicien, il en
-- a tous les écrans — mais rien de ce qu'il fait n'est inscrit au journal, et il
-- est tenu à l'écart de tout ce qui compte : l'export comptable, la vue de la
-- fiduciaire, et le relevé des saisies en retard.
--
-- OÙ LE SILENCE EST POSÉ
-- Dans _journal, donc pour tous les déclencheurs qui passent par elle. Et dans
-- les quelques déclencheurs qui écrivent en direct, où il faut le dire à la
-- main. Le silence vaut dans les deux sens : ni ce que le compte de démo fait,
-- ni ce qu'on fait sur lui — sans quoi une question posée à la démo laisserait
-- une trace « a écrit à Démo » au milieu des vraies.

alter table public.employes add column if not exists demo boolean not null default false;

-- Un seul endroit pour répondre à la question, et tout le reste s'y réfère.
create or replace function public._demo(p_id uuid)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$ select coalesce((select e.demo from public.employes e where e.id = p_id), false) $$;
revoke execute on function public._demo(uuid) from anon, authenticated, public;

-- Le silence, à la source.
create or replace function public._journal(
  p_acteur uuid, p_action text, p_cible text default '', p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v_nom text; v_role text; v_demo boolean;
begin
  select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom), e.role, e.demo
    into v_nom, v_role, v_demo
    from public.employes e where e.id = p_acteur;

  if coalesce(v_demo, false) then return; end if;   -- la démonstration ne laisse rien

  insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
  values (p_acteur, coalesce(v_nom, 'inconnu'), coalesce(v_role, ''),
          p_action, left(coalesce(p_cible, ''), 120), coalesce(p_detail, '{}'::jsonb));
end $$;
revoke execute on function public._journal(uuid, text, text, jsonb) from anon, authenticated, public;

-- Les fiches : ne pas inscrire les retouches d'un compte de démonstration.
create or replace function public._trg_journal_employe()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_champs text[]; v_detail jsonb;
begin
  if new.demo or old.demo then return new; end if;

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

-- Les pointages : ni la saisie du compte de démonstration, ni celle qu'on ferait
-- pour lui depuis le back office.
create or replace function public._trg_journal_pointages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_qui uuid; v_action text; v_detail jsonb; v_par text; v_horaire text;
begin
  if tg_op = 'DELETE' then
    if public._demo(old.employe_id) or public._demo(old.saisi_par) then return old; end if;
    perform public._journal(old.saisi_par, 'suppression',
      to_char(old.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', (select prenom from public.employes where id = old.employe_id)));
    return old;
  end if;

  if public._demo(new.employe_id) or public._demo(new.saisi_par) then return new; end if;

  v_qui := new.saisi_par;
  v_action := case when tg_op = 'INSERT' then 'saisie' else 'modification' end;
  v_par := case when new.saisi_par = new.employe_id then 'technicien' else 'back office' end;
  v_horaire := case
    when coalesce((to_jsonb(new)->>'prerempli')::boolean, false) then 'type'
    else 'tapé' end;
  v_detail := jsonb_build_object(
    'employe', (select prenom from public.employes where id = new.employe_id),
    'par', v_par, 'horaire', v_horaire);
  perform public._journal(v_qui, v_action, to_char(new.jour, 'DD.MM.YYYY'), v_detail);
  return new;
end $$;

-- Les messages : ni ceux du compte de démonstration, ni ceux qu'on lui adresse.
create or replace function public._trg_journal_messages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_acteur uuid; v_cible text;
begin
  if tg_op = 'DELETE' then
    if public._demo(old.auteur_id) or public._demo(old.employe_id) then return old; end if;
    perform public._journal(old.auteur_id, 'message_supprime',
      coalesce((select prenom from public.employes where id = old.employe_id), 'la fiduciaire'),
      jsonb_build_object(
        'texte', left(old.texte, 200),
        'ecrit_le', to_char(old.cree_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'),
        'mois', to_char(make_date(old.annee, old.mois, 1), 'MM.YYYY'),
        'deja_lu', case when old.employe_id is not null then old.lu_employe else old.lu_compta end));
    return old;
  end if;

  if public._demo(new.auteur_id) or public._demo(new.employe_id) then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.texte is distinct from old.texte or new.jour is distinct from old.jour then
      perform public._journal(new.auteur_id, 'message_modifie',
        coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
        jsonb_build_object('avant', left(old.texte, 80), 'apres', left(new.texte, 80)));
      return new;
    end if;

    v_acteur := nullif(current_setting('horaires.acteur', true), '')::uuid;
    v_cible := coalesce(
      (select prenom from public.employes where id = new.employe_id),
      (select case when e.role = 'compta' then 'la fiduciaire' else 'la direction' end
         from public.employes e where e.id = new.auteur_id),
      'la fiduciaire');

    if not old.lu_employe and new.lu_employe and new.employe_id is not null then
      perform public._journal(new.employe_id, 'message_lu', '',
        jsonb_build_object('extrait', left(new.texte, 80)));
    elsif not old.lu_direction and new.lu_direction then
      if v_acteur is not null then
        perform public._journal(v_acteur, 'message_lu', v_cible,
          jsonb_build_object('extrait', left(new.texte, 80)));
      else
        insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
        values (null, 'Direction', 'admin', 'message_lu', v_cible,
                jsonb_build_object('extrait', left(new.texte, 80)));
      end if;
    elsif not old.lu_compta and new.lu_compta then
      if v_acteur is not null then
        perform public._journal(v_acteur, 'message_lu', v_cible,
          jsonb_build_object('extrait', left(new.texte, 80)));
      else
        insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
        values (null, 'La fiduciaire', 'compta', 'message_lu', v_cible,
                jsonb_build_object('extrait', left(new.texte, 80)));
      end if;
    end if;
    return new;
  end if;

  perform public._journal(new.auteur_id,
    case when new.automatique then 'message_auto' else 'message' end,
    coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
    jsonb_build_object('extrait', left(new.texte, 80)));
  return new;
end $$;

-- ---------------------------------------------------------------- à l'écart

-- L'écran connaît le drapeau : c'est lui qui écarte la démonstration de l'export
-- et la signale dans la liste des accès.
create or replace function public._emp_json(e public.employes)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'id', e.id, 'prenom', e.prenom, 'nom', e.nom, 'metier', e.metier,
    'role', e.role, 'actif', e.actif, 'demo', e.demo,
    'matin_debut_def', to_char(e.matin_debut_def, 'HH24:MI'),
    'matin_fin_def',   to_char(e.matin_fin_def, 'HH24:MI'),
    'apm_debut_def',   to_char(e.apm_debut_def, 'HH24:MI'),
    'apm_fin_def',     to_char(e.apm_fin_def, 'HH24:MI'))
$$;

-- La fiduciaire ne voit pas la démonstration : ses écrans ne servent qu'à
-- préparer la paie, un faux technicien n'y a rien à faire.
create or replace function public.compta_donnees(p_token uuid, p_annee integer, p_mois integer)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb; v_entreprise text; v_nl int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'compta' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  perform public._presence(v_emp, p_annee, p_mois);
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._emp_json(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e where e.role <> 'compta' and not e.demo;
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month'
     and not public._demo(p.employe_id);
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_compta;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl, 'moi', public._emp_json(v_emp));
end $$;

-- Et le relevé des saisies en retard ne réclame rien à un compte fictif.
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
       where e.role = 'employe' and e.actif and not e.demo
    ) s
   where (x->>'manquants')::int > 0;

  return jsonb_build_object('ok', true, 'retards', v_r,
                            'aujourdhui', to_char(v_auj, 'YYYY-MM-DD'));
end $$;
