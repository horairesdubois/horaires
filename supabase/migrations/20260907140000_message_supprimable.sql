-- Supprimer un message écrit par erreur.
--
-- CE QUE LA DIRECTION A DEMANDÉ
-- « Si je fais une erreur, je dois pouvoir être en mesure de supprimer un
-- message », et sans que l'autre partie le voie. Donc pas de pierre tombale,
-- pas de « message supprimé » dans le fil : la ligne s'en va pour de bon.
--
-- POURQUOI UNE SUPPRESSION FRANCHE ET NON UN MASQUAGE
-- Un message masqué reste une ligne : il continue de compter dans les non-lus,
-- il ressort des exports, et il réapparaît le jour où quelqu'un oublie le
-- filtre. La demande est de le faire disparaître ; on le fait vraiment.
--
-- QUI PEUT SUPPRIMER QUOI
-- Le back office, et seulement ses propres messages. Effacer les mots d'un
-- technicien ne serait plus corriger une erreur, ce serait récrire ce qu'il a
-- dit — et sur des questions d'heures de travail, c'est exactement ce qu'un
-- registre est censé empêcher.
--
-- CE QUI RESTE, ET OÙ
-- Une ligne au journal, avec le texte supprimé. Le journal ne se lit que depuis
-- le back office : le technicien ne voit rien, ni le message, ni sa
-- disparition. Sans cette ligne, un accès administrateur pourrait effacer une
-- conversation sans laisser de trace nulle part — et le journal ne vaudrait
-- plus rien.

create or replace function public.message_supprimer(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_m public.messages;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if v_emp.role <> 'admin' then
    return jsonb_build_object('ok', false, 'erreur', 'Acces refuse');
  end if;

  select * into v_m from public.messages where id = p_id;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Message introuvable');
  end if;
  if v_m.auteur_id is distinct from v_emp.id then
    return jsonb_build_object('ok', false, 'erreur',
      'Vous ne pouvez supprimer que vos propres messages');
  end if;

  delete from public.messages where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.message_supprimer(uuid, uuid) from public, authenticated;
grant execute on function public.message_supprimer(uuid, uuid) to anon;

-- Le journal apprend la suppression. Il gardait déjà l'écriture, la lecture et
-- la correction ; sans la suppression, la dernière opération capable de faire
-- disparaître une conversation serait justement la seule qui ne laisse rien.
create or replace function public._trg_journal_messages()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
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

drop trigger if exists journal_messages on public.messages;
create trigger journal_messages
  after insert or update or delete on public.messages
  for each row execute function public._trg_journal_messages();
