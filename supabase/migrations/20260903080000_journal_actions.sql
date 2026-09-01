-- Journal des actions, visible de la seule direction.
--
-- POURQUOI DES DÉCLENCHEURS ET NON DES APPELS DANS CHAQUE FONCTION
-- Instrumenter les fonctions existantes voudrait dire les réécrire une à une —
-- or plusieurs d'entre elles ont dérivé du dépôt, et la version qui tourne
-- n'est pas celle qu'on lit ici. Un déclencheur s'attache à la table sans
-- toucher au code qui l'écrit : rien à réécrire, rien à écraser.
--
-- QUI A FAIT QUOI : LA TABLE LE SAIT DÉJÀ
-- pointages.saisi_par dit qui a posé la journée, approuve_par qui l'a validée,
-- messages.auteur_id qui a écrit. Le déclencheur n'a donc pas besoin de
-- connaître la session en cours pour attribuer l'action.
--
-- LA SEULE FONCTION RÉÉCRITE
-- compta_donnees. La consultation de la fiduciaire est une lecture : aucune
-- table ne bouge, donc aucun déclencheur ne peut la voir. Sa définition a été
-- relevée sur la base avant d'être reprise ici, à la ligne près.

create table if not exists public.journal (
  id bigint generated always as identity primary key,
  quand timestamptz not null default now(),
  acteur_id uuid references public.employes(id) on delete set null,
  acteur_nom text not null default '',
  acteur_role text not null default '',
  action text not null,
  cible text not null default '',
  detail jsonb not null default '{}'::jsonb
);
create index if not exists journal_quand_idx on public.journal (quand desc);
create index if not exists journal_acteur_idx on public.journal (acteur_id, quand desc);

alter table public.journal enable row level security;
revoke all on public.journal from anon, authenticated;

comment on table public.journal is
  'Trace des actions. Lisible par la seule direction : ni le technicien, ni la '
  'fiduciaire n''y ont accès, y compris à leurs propres lignes.';

-- ---------------------------------------------------------------- helper

create or replace function public._journal(
  p_acteur uuid, p_action text, p_cible text default '', p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v_nom text; v_role text;
begin
  select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom), e.role
    into v_nom, v_role
    from public.employes e where e.id = p_acteur;

  insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
  values (p_acteur, coalesce(v_nom, 'inconnu'), coalesce(v_role, ''),
          p_action, left(coalesce(p_cible, ''), 120), coalesce(p_detail, '{}'::jsonb));
end $$;
revoke execute on function public._journal(uuid, text, text, jsonb) from anon, authenticated, public;

-- ---------------------------------------------------------------- pointages

create or replace function public._trg_journal_pointages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_qui uuid; v_action text; v_detail jsonb;
begin
  if tg_op = 'DELETE' then
    perform public._journal(old.saisi_par, 'suppression',
      to_char(old.jour, 'DD.MM.YYYY'),
      jsonb_build_object('employe', (select prenom from public.employes where id = old.employe_id)));
    return old;
  end if;

  if tg_op = 'INSERT' then
    v_qui := new.saisi_par;
    -- La colonne prerempli n'existe que si la migration du pré-remplissage a
    -- été appliquée. On la lit par le JSON de la ligne : absente, la clé vaut
    -- nul et l'action reste « saisie ». Un déclencheur qui exige une colonne
    -- optionnelle bloque toute écriture sur les bases qui ne l'ont pas.
    v_action := case when coalesce((to_jsonb(new)->>'prerempli')::boolean, false)
                     then 'preremplissage' else 'saisie' end;
  elsif old.approuve is distinct from new.approuve then
    -- En déverrouillant, la fonction remet approuve_par à nul : la ligne ne dit
    -- plus qui agit. Seule la direction peut déverrouiller — on l'inscrit comme
    -- telle plutôt que de nommer, à tort, celui qui avait validé. Ce dernier
    -- reste dans le détail, où il est une information et non une accusation.
    v_qui := new.approuve_par;
    v_action := case when new.approuve then 'validation' else 'deverrouillage' end;
  else
    v_qui := new.saisi_par;
    v_action := 'modification';
  end if;

  v_detail := jsonb_build_object(
    'employe', (select prenom from public.employes where id = new.employe_id),
    'matin', case when new.matin_type = 'travail'
                  then to_char(new.matin_debut,'HH24:MI') || '–' || to_char(new.matin_fin,'HH24:MI')
                  else new.matin_type end,
    'apres_midi', case when new.apm_type = 'travail'
                  then to_char(new.apm_debut,'HH24:MI') || '–' || to_char(new.apm_fin,'HH24:MI')
                  else new.apm_type end);
  -- La ligne pré-remplie n'a pas d'auteur : c'est le système. On l'inscrit
  -- quand même, sinon une journée apparaîtrait dans la feuille sans que le
  -- journal puisse dire d'où elle vient.
  if v_action = 'deverrouillage' then
    insert into public.journal (acteur_id, acteur_nom, acteur_role, action, cible, detail)
    values (null, 'Direction', 'admin', v_action, to_char(new.jour, 'DD.MM.YYYY'),
            v_detail || jsonb_build_object('valide_avant_par',
              (select prenom from public.employes where id = old.approuve_par)));
  else
    perform public._journal(v_qui, v_action, to_char(new.jour, 'DD.MM.YYYY'), v_detail);
  end if;
  return new;
end $$;

drop trigger if exists journal_pointages on public.pointages;
create trigger journal_pointages
  after insert or update or delete on public.pointages
  for each row execute function public._trg_journal_pointages();

-- ---------------------------------------------------------------- connexions

create or replace function public._trg_journal_sessions()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._journal(new.employe_id, 'connexion', '',
    jsonb_build_object('expire_le', to_char(new.expire_le, 'DD.MM.YYYY')));
  return new;
end $$;

drop trigger if exists journal_sessions on public.sessions;
create trigger journal_sessions
  after insert on public.sessions
  for each row execute function public._trg_journal_sessions();

-- Ouverture de l'application. L'horodatage est déjà posé par mes_pointages ;
-- on ne retient qu'une ouverture par demi-heure et par personne, sinon chaque
-- rafraîchissement d'écran remplirait le journal sans rien apprendre.
create or replace function public._trg_journal_ouverture()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if new.derniere_connexion is distinct from old.derniere_connexion
     and (old.derniere_connexion is null
          or new.derniere_connexion > old.derniere_connexion + interval '30 minutes') then
    perform public._journal(new.id, 'ouverture', '', '{}'::jsonb);
  end if;
  return new;
end $$;

drop trigger if exists journal_ouverture on public.employes;
create trigger journal_ouverture
  after update of derniere_connexion on public.employes
  for each row execute function public._trg_journal_ouverture();

-- ---------------------------------------------------------------- messages

create or replace function public._trg_journal_messages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._journal(new.auteur_id,
    case when new.automatique then 'message_auto' else 'message' end,
    coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
    jsonb_build_object('extrait', left(new.texte, 80)));
  return new;
end $$;

drop trigger if exists journal_messages on public.messages;
create trigger journal_messages
  after insert on public.messages
  for each row execute function public._trg_journal_messages();

-- ---------------------------------------------------------------- fiduciaire

-- Reprise à la ligne près de la définition relevée sur la base le 03.09.2026,
-- augmentée d'un seul appel : la consultation de la fiduciaire s'inscrit au
-- journal. C'est une lecture, aucun déclencheur ne pouvait la voir.
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

  perform public._journal(v_emp.id, 'consultation',
    lpad(p_mois::text, 2, '0') || '.' || p_annee::text,
    jsonb_build_object('ecran', 'espace fiduciaire'));

  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce(jsonb_agg(public._emp_json(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e where e.role <> 'compta';
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_compta;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl, 'moi', public._emp_json(v_emp));
end $$;
revoke execute on function public.compta_donnees(uuid, int, int) from public, authenticated;
grant execute on function public.compta_donnees(uuid, int, int) to anon;

-- ---------------------------------------------------------------- lecture

/**
 * Le journal ne se lit que depuis la direction. Ni le technicien, ni la
 * fiduciaire n'y accèdent — pas même à leurs propres lignes : savoir qu'on est
 * observé change ce qu'on observe, et c'est précisément l'habitude qu'on
 * cherche à comprendre.
 */
create or replace function public.journal_lire(
  p_token uuid, p_jours int default 30, p_limite int default 300, p_acteur uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_j int; v_l int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'Accès refusé');
  end if;
  v_j := least(greatest(coalesce(p_jours, 30), 1), 400);
  v_l := least(greatest(coalesce(p_limite, 300), 1), 2000);

  return jsonb_build_object(
    'ok', true,
    'jours', v_j,

    -- Les personnes qui ont laissé une trace sur la période, pour lire le
    -- journal de l'une d'elles seulement. La liste sort d'ici plutôt que de
    -- l'écran : elle ne doit contenir que des gens qui ont effectivement agi,
    -- sinon on propose des filtres toujours vides. Elle ignore p_acteur, sans
    -- quoi choisir quelqu'un ferait disparaître tous les autres boutons.
    'acteurs', coalesce((
      select jsonb_agg(a order by a->>'nom')
        from (
          select distinct on (j.acteur_id) jsonb_build_object(
                   'id', j.acteur_id,
                   'nom', case when j.acteur_role = 'compta' then 'La fiduciaire' else j.acteur_nom end,
                   'role', j.acteur_role,
                   'nb', count(*) over (partition by j.acteur_id)) as a
            from public.journal j
           where j.quand >= now() - make_interval(days => v_j)
             and j.acteur_id is not null
        ) t), '[]'::jsonb),

    'lignes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', j.id,
               'acteur_id', j.acteur_id,
               'jour', to_char(j.quand at time zone 'Europe/Zurich', 'DD.MM.YYYY'),
               'heure', to_char(j.quand at time zone 'Europe/Zurich', 'HH24:MI'),
               -- La fiduciaire est une fonction, pas une personne : c'est son
               -- rôle qui intéresse la direction, jamais son prénom. Et le
               -- compte peut changer de titulaire sans que le journal mente.
               'qui', case when j.acteur_role = 'compta' then 'La fiduciaire' else j.acteur_nom end,
               'role', j.acteur_role,
               'action', j.action, 'cible', j.cible, 'detail', j.detail)
             order by j.quand desc)
        from (select * from public.journal
               where quand >= now() - make_interval(days => v_j)
                 and (p_acteur is null or acteur_id = p_acteur)
               order by quand desc limit v_l) j), '[]'::jsonb));
end $$;
revoke execute on function public.journal_lire(uuid, int, int, uuid) from public, authenticated;
grant execute on function public.journal_lire(uuid, int, int, uuid) to anon;

-- Le journal grossit d'environ une ligne par action. À trois techniciens, quelques
-- milliers de lignes par an — rien à purger avant longtemps. Le jour venu :
--   delete from public.journal where quand < now() - interval '24 months';
