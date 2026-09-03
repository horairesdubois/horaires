-- Modifier son propre message.
--
-- POURQUOI UNE TRACE PLUTÔT QU'UNE INTERDICTION
-- Un message déjà lu qu'on récrit en silence réécrit l'histoire : le
-- destinataire a répondu à une question qui n'existe plus. On autorise donc la
-- correction — c'est utile, et l'interdire pousse à envoyer un second message
-- qui contredit le premier — mais elle laisse une marque visible et une ligne
-- au journal.
--
-- QUI PEUT MODIFIER QUOI
-- Son propre message, et rien d'autre. Un rappel automatique n'est modifiable
-- par personne : il n'a pas d'auteur au sens où on l'entend ici.

alter table public.messages add column if not exists modifie_le timestamptz;

create or replace function public._msg_json(m public.messages)
returns jsonb language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', m.id, 'annee', m.annee, 'mois', m.mois, 'employe_id', m.employe_id,
    'auteur_id', m.auteur_id,
    'auteur', case when m.automatique then 'Back Office'
                   else (select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom)
                           from public.employes e where e.id = m.auteur_id) end,
    'role', case when m.automatique then 'systeme'
                 else (select e.role from public.employes e where e.id = m.auteur_id) end,
    'automatique', m.automatique,
    'texte', m.texte,
    'jour', to_char(m.jour, 'YYYY-MM-DD'),
    'modifie', m.modifie_le is not null,
    'quand', to_char(m.cree_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'))
$$;

create or replace function public.message_modifier(
  p_token uuid, p_id uuid, p_texte text, p_jour date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_txt text; v_m public.messages;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;

  select * into v_m from public.messages where id = p_id;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Message introuvable');
  end if;
  if v_m.automatique then
    return jsonb_build_object('ok', false, 'erreur', 'Un rappel automatique ne se modifie pas');
  end if;
  if v_m.auteur_id is distinct from v_emp.id then
    return jsonb_build_object('ok', false, 'erreur', 'Vous ne pouvez modifier que vos propres messages');
  end if;

  v_txt := trim(coalesce(p_texte, ''));
  if v_txt = '' then return jsonb_build_object('ok', false, 'erreur', 'Message vide'); end if;
  if length(v_txt) > 2000 then
    return jsonb_build_object('ok', false, 'erreur', 'Message trop long (2000 caractères maximum)');
  end if;
  if p_jour is not null
     and (extract(year from p_jour)::int <> v_m.annee or extract(month from p_jour)::int <> v_m.mois) then
    return jsonb_build_object('ok', false, 'erreur', 'La date doit appartenir au mois du fil');
  end if;

  update public.messages
     set texte = v_txt, jour = p_jour, modifie_le = now()
   where id = p_id;

  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.message_modifier(uuid, uuid, text, date) from public, authenticated;
grant execute on function public.message_modifier(uuid, uuid, text, date) to anon;

-- Le journal suit aussi les corrections : sans quoi un message pourrait changer
-- de sens entre le moment où il est lu et celui où on le relit.
create or replace function public._trg_journal_messages()
returns trigger language plpgsql security definer set search_path = public, extensions
as $$
begin
  if tg_op = 'UPDATE' then
    if new.texte is distinct from old.texte or new.jour is distinct from old.jour then
      perform public._journal(new.auteur_id, 'message_modifie',
        coalesce((select prenom from public.employes where id = new.employe_id), 'tous'),
        jsonb_build_object('avant', left(old.texte, 80), 'apres', left(new.texte, 80)));
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
  after insert or update on public.messages
  for each row execute function public._trg_journal_messages();
