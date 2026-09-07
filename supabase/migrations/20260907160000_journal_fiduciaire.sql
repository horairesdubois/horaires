-- La fiduciaire dans le journal — et le back office avec elle.
--
-- CE QU'ON CHERCHAIT, ET CE QU'ON A TROUVÉ
-- Le journal ne montrait aucune ligne pour la fiduciaire. Première explication,
-- la bonne : elle n'a pas ouvert l'application depuis le 27 août, et le journal
-- date du 1er septembre. Il n'y avait rien à montrer.
--
-- Mais en vérifiant, trois défauts sont apparus.
--
-- 1. COMPTA_DONNEES ÉCRIVAIT UNE LIGNE À CHAQUE APPEL
--    L'écran se rafraîchit toutes les minutes. Une fiduciaire qui laisse son
--    onglet ouvert une journée aurait donc posé près de cinq cents lignes
--    « consultation », toutes identiques. Le journal se serait noyé le jour même
--    où il aurait enfin servi.
--
-- 2. LE BACK OFFICE N'ÉTAIT PAS TRACÉ DU TOUT
--    admin_donnees n'écrit rien et ne touche pas derniere_connexion. On voyait
--    donc ce que la direction faisait, jamais quand elle arrivait — et comparer
--    des habitudes suppose de regarder les deux côtés de la même façon.
--
-- 3. « MESSAGE LU » N'AVAIT PAS D'AUTEUR
--    Le déclencheur ne peut pas deviner qui a lu : il ne voit que la ligne. Il
--    inscrivait donc « Direction » ou « La fiduciaire » sans identifiant, et ces
--    lignes échappaient au classement par personne, celui-là même qui fait sens
--    du journal.
--
-- CE QUI EST POSÉ ICI
-- Une présence relevée comme celle des techniciens (une ouverture par
-- demi-heure), la consultation ramenée au mois regardé, l'export enfin visible,
-- et un auteur sur les lectures de messages.

-- ---------------------------------------------------------------- index

-- Le filtre par personne et la limite de fréquence lisent tous deux le journal
-- par acteur et par date. Sans index, chaque ouverture d'écran le parcourrait
-- en entier — et il ne fait que grandir.
create index if not exists journal_acteur_quand on public.journal (acteur_id, quand desc);

-- ---------------------------------------------------------------- présence

/**
 * Une ligne « consultation » au plus par demi-heure et par mois regardé.
 *
 * Le mois fait partie de la clé, volontairement : rester sur septembre pendant
 * deux heures n'apprend rien de plus, mais passer de septembre à juin est
 * précisément ce qu'on cherche à voir.
 *
 * derniere_connexion est touchée au passage : le déclencheur d'ouverture, lui,
 * ne retient qu'un passage par demi-heure, et la direction comme la fiduciaire
 * apparaissent enfin dans la même colonne que les techniciens.
 */
create or replace function public._presence(p_emp public.employes, p_annee int, p_mois int)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v_cible text; v_dernier timestamptz;
begin
  if p_emp.id is null then return; end if;
  v_cible := lpad(p_mois::text, 2, '0') || '.' || p_annee::text;

  select max(j.quand) into v_dernier
    from public.journal j
   where j.acteur_id = p_emp.id and j.action = 'consultation' and j.cible = v_cible;

  if v_dernier is null or v_dernier < now() - interval '30 minutes' then
    perform public._journal(p_emp.id, 'consultation', v_cible,
      jsonb_build_object('ecran', case p_emp.role
                                    when 'compta' then 'espace fiduciaire'
                                    when 'admin'  then 'back office'
                                    else 'application' end));
  end if;

  update public.employes set derniere_connexion = now() where id = p_emp.id;
end $$;
revoke execute on function public._presence(public.employes, int, int) from anon, authenticated, public;

-- ---------------------------------------------------------------- écrans

-- Recréées à l'identique de la production, à la ligne de présence près.
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
    into v_emps from public.employes e where e.role <> 'compta';
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_compta;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl, 'moi', public._emp_json(v_emp));
end $$;

create or replace function public.admin_donnees(p_token uuid, p_annee integer, p_mois integer)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_emp public.employes; v_debut date; v_emps jsonb; v_ptgs jsonb;
  v_entreprise text; v_nl int; v_depuis date;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  perform public._presence(v_emp, p_annee, p_mois);
  v_debut := make_date(p_annee, p_mois, 1);
  select coalesce((select valeur::date from public.parametres where cle = 'tracabilite_depuis'),
                  current_date) into v_depuis;
  select coalesce(jsonb_agg(public._emp_json_admin(e) order by e.actif desc, e.prenom, e.nom), '[]'::jsonb)
    into v_emps from public.employes e;
  select coalesce(jsonb_agg(public._ptg_json(p) order by p.jour), '[]'::jsonb)
    into v_ptgs from public.pointages p
   where p.jour >= v_debut and p.jour < v_debut + interval '1 month';
  select valeur into v_entreprise from public.parametres where cle = 'entreprise';
  select count(*) into v_nl from public.messages m where not m.lu_direction;
  return jsonb_build_object('ok', true, 'entreprise', coalesce(v_entreprise, ''),
    'employes', v_emps, 'pointages', v_ptgs, 'msg_non_lus', v_nl,
    'tracabilite_depuis', to_char(v_depuis, 'YYYY-MM-DD'),
    'aujourdhui', to_char((now() at time zone 'Europe/Zurich')::date, 'YYYY-MM-DD'));
end $$;

-- ---------------------------------------------------------------- export

/**
 * L'export est fabriqué dans le navigateur : la base ne le voit pas passer.
 * C'est pourtant le geste central de la fiduciaire — ce qu'elle emporte, et
 * quand. L'écran le déclare donc explicitement.
 *
 * La liste des actions acceptées est fermée : une fonction ouverte laisserait
 * n'importe quel porteur de la clé publique écrire ce qu'il veut dans le
 * registre, et un registre qu'on peut remplir à volonté ne prouve plus rien.
 */
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
  if p_action not in ('export') then
    return jsonb_build_object('ok', false, 'erreur', 'Action non journalisable');
  end if;
  perform public._journal(v_emp.id, p_action, left(coalesce(p_cible, ''), 120),
    jsonb_build_object('n', (p_detail->>'n')::int));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.journal_noter(uuid, text, text, jsonb) from public, authenticated;
grant execute on function public.journal_noter(uuid, text, text, jsonb) to anon;

-- ---------------------------------------------------------------- qui a lu

-- Le déclencheur ne voit que la ligne, jamais l'appelant. Les fonctions qui
-- marquent lu déposent donc leur identité dans un réglage de transaction, que
-- le déclencheur relit. Sans cela, « message lu » restait anonyme et échappait
-- au classement par personne.
create or replace function public._trg_journal_messages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
declare v_acteur uuid; v_cible text;
begin
  if tg_op = 'DELETE' then
    perform public._journal(old.auteur_id, 'message_supprime',
      coalesce((select prenom from public.employes where id = old.employe_id), 'la fiduciaire'),
      jsonb_build_object(
        'texte', left(old.texte, 200),
        'ecrit_le', to_char(old.cree_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'),
        'mois', to_char(make_date(old.annee, old.mois, 1), 'MM.YYYY'),
        'deja_lu', case when old.employe_id is not null then old.lu_employe else old.lu_compta end));
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if new.texte is distinct from old.texte or new.jour is distinct from old.jour then
      perform public._journal(new.auteur_id, 'message_modifie',
        coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
        jsonb_build_object('avant', left(old.texte, 80), 'apres', left(new.texte, 80)));
      return new;
    end if;

    v_acteur := nullif(current_setting('horaires.acteur', true), '')::uuid;
    -- « a lu le message de … » : on nomme celui qui l'a écrit, pas le fil. Dans
    -- le fil partagé, direction et fiduciaire s'y lisent l'un l'autre — mettre
    -- le nom du fil ferait dire à la fiduciaire qu'elle s'est lue elle-même.
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

drop trigger if exists journal_messages on public.messages;
create trigger journal_messages
  after insert or update or delete on public.messages
  for each row execute function public._trg_journal_messages();

-- Les deux chemins qui marquent lu déposent leur identité avant d'écrire. Le
-- troisième argument de set_config vaut vrai : le réglage meurt avec la
-- transaction, il ne fuit pas d'un appel à l'autre.
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
  perform set_config('horaires.acteur', v_emp.id::text, true);

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
    perform set_config('horaires.acteur', v_emp.id::text, true);
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
