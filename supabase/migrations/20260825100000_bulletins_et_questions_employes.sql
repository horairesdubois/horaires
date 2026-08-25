-- Bulletins de salaire (PDF) et ouverture des questions aux employés.
--
-- 1. BULLETINS
--    La fiduciaire dépose un bulletin PDF par employé et par mois ; l'employé
--    le retrouve dans son espace et le télécharge. Le fichier est stocké dans
--    la base (colonne bytea) plutôt que dans Supabase Storage : l'application
--    n'utilise pas Supabase Auth mais ses propres jetons de session, et les
--    règles d'accès de Storage ne sauraient pas identifier nos utilisateurs.
--    En base, les mêmes fonctions SECURITY DEFINER contrôlent tout.
--    Volume : un bulletin pèse ~100 Ko, soit ~4 Mo par an pour trois employés.
--
-- 2. QUESTIONS
--    La table messages portait un seul fil par mois, réservé à la direction et
--    à la fiduciaire. Elle gagne une colonne employe_id :
--      - NULL          → fil général direction ↔ fiduciaire (comportement actuel)
--      - un identifiant → fil concernant cet employé, qu'il peut lire et où il
--                         peut écrire ; direction et fiduciaire y répondent.
--    Un employé ne voit jamais le fil d'un autre.

-- ---------------------------------------------------------------- BULLETINS
create table if not exists public.bulletins (
  id uuid primary key default gen_random_uuid(),
  employe_id uuid not null references public.employes(id) on delete cascade,
  annee int not null,
  mois int not null,
  nom_fichier text not null,
  contenu bytea not null,
  taille int not null,
  depose_par uuid references public.employes(id),
  depose_le timestamptz not null default now(),
  unique (employe_id, annee, mois)
);
alter table public.bulletins enable row level security;
revoke all on public.bulletins from anon, authenticated;
create index if not exists bulletins_employe_idx on public.bulletins (employe_id, annee desc, mois desc);

-- Métadonnées d'un bulletin, sans le fichier lui-même.
create or replace function public._bulletin_json(b public.bulletins)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', b.id, 'employe_id', b.employe_id, 'annee', b.annee, 'mois', b.mois,
    'nom', b.nom_fichier, 'taille', b.taille,
    'depose_le', to_char(b.depose_le at time zone 'Europe/Zurich', 'DD.MM.YYYY'))
$$;
revoke execute on function public._bulletin_json(public.bulletins) from anon, authenticated, public;

-- Dépôt d'un bulletin : fiduciaire ou direction uniquement.
create or replace function public.bulletin_deposer(
  p_token uuid, p_employe uuid, p_annee int, p_mois int,
  p_nom text, p_base64 text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_bin bytea; v_cible public.employes; v_nom text;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('compta', 'admin') then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  select * into v_cible from public.employes where id = p_employe and role = 'employe';
  if v_cible.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Employé introuvable');
  end if;
  if p_base64 is null or p_base64 = '' then
    return jsonb_build_object('ok', false, 'erreur', 'Fichier vide');
  end if;
  begin
    v_bin := decode(p_base64, 'base64');
  exception when others then
    return jsonb_build_object('ok', false, 'erreur', 'Fichier illisible');
  end;
  if length(v_bin) > 3145728 then
    return jsonb_build_object('ok', false, 'erreur', 'Fichier trop lourd (3 Mo maximum)');
  end if;
  -- Un bulletin de salaire est un PDF : on refuse tout autre format.
  if substring(v_bin from 1 for 4) <> '\x25504446'::bytea then
    return jsonb_build_object('ok', false, 'erreur', 'Seuls les fichiers PDF sont acceptés');
  end if;
  v_nom := nullif(trim(coalesce(p_nom, '')), '');
  if v_nom is null then v_nom := 'bulletin.pdf'; end if;
  if length(v_nom) > 120 then v_nom := left(v_nom, 120); end if;

  insert into public.bulletins (employe_id, annee, mois, nom_fichier, contenu, taille, depose_par)
  values (p_employe, p_annee, p_mois, v_nom, v_bin, length(v_bin), v_emp.id)
  on conflict (employe_id, annee, mois) do update
    set nom_fichier = excluded.nom_fichier, contenu = excluded.contenu,
        taille = excluded.taille, depose_par = excluded.depose_par, depose_le = now();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.bulletin_deposer(uuid, uuid, int, int, text, text) from public, authenticated;
grant execute on function public.bulletin_deposer(uuid, uuid, int, int, text, text) to anon;

-- Liste des bulletins : l'employé ne voit que les siens.
create or replace function public.bulletins_lister(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_liste jsonb;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  select coalesce(jsonb_agg(public._bulletin_json(b) order by b.annee desc, b.mois desc), '[]'::jsonb)
    into v_liste from public.bulletins b
   where v_emp.role in ('compta', 'admin') or b.employe_id = v_emp.id;
  return jsonb_build_object('ok', true, 'bulletins', v_liste);
end $$;
revoke execute on function public.bulletins_lister(uuid) from public, authenticated;
grant execute on function public.bulletins_lister(uuid) to anon;

-- Téléchargement : l'employé ne peut demander que son propre bulletin.
create or replace function public.bulletin_telecharger(p_token uuid, p_bulletin uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_b public.bulletins;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  select * into v_b from public.bulletins where id = p_bulletin;
  if v_b.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'Bulletin introuvable');
  end if;
  if v_emp.role not in ('compta', 'admin') and v_b.employe_id <> v_emp.id then
    return jsonb_build_object('ok', false, 'erreur', 'Bulletin introuvable');
  end if;
  return jsonb_build_object('ok', true, 'nom', v_b.nom_fichier,
    'contenu', encode(v_b.contenu, 'base64'));
end $$;
revoke execute on function public.bulletin_telecharger(uuid, uuid) from public, authenticated;
grant execute on function public.bulletin_telecharger(uuid, uuid) to anon;

-- Suppression : fiduciaire ou direction.
create or replace function public.bulletin_supprimer(p_token uuid, p_bulletin uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_n int;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('compta', 'admin') then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  delete from public.bulletins where id = p_bulletin;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'erreur', 'Bulletin introuvable'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.bulletin_supprimer(uuid, uuid) from public, authenticated;
grant execute on function public.bulletin_supprimer(uuid, uuid) to anon;

-- ---------------------------------------------------------------- QUESTIONS
alter table public.messages add column if not exists employe_id uuid references public.employes(id) on delete cascade;
alter table public.messages add column if not exists lu_employe boolean not null default true;
create index if not exists messages_fil_idx on public.messages (annee, mois, employe_id);

create or replace function public._msg_json(m public.messages)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', m.id, 'annee', m.annee, 'mois', m.mois, 'employe_id', m.employe_id,
    'auteur', (select coalesce(nullif(trim(e.prenom || ' ' || e.nom), ''), e.prenom)
                 from public.employes e where e.id = m.auteur_id),
    'role', (select e.role from public.employes e where e.id = m.auteur_id),
    'texte', m.texte,
    'quand', to_char(m.cree_le at time zone 'Europe/Zurich', 'DD.MM.YYYY HH24:MI'))
$$;

-- Écriture d'un message. p_employe désigne le fil :
--   NULL → fil général (direction ↔ fiduciaire) ; un employé est toujours
--   ramené à son propre fil, quoi qu'il envoie.
create or replace function public.message_ecrire(
  p_token uuid, p_annee int, p_mois int, p_texte text, p_employe uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_txt text; v_fil uuid;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_txt := trim(coalesce(p_texte, ''));
  if v_txt = '' then return jsonb_build_object('ok', false, 'erreur', 'Message vide'); end if;
  if length(v_txt) > 2000 then
    return jsonb_build_object('ok', false, 'erreur', 'Message trop long (2000 caractères maximum)');
  end if;

  if v_emp.role = 'employe' then
    v_fil := v_emp.id;                      -- un employé écrit toujours dans son fil
  else
    v_fil := p_employe;                     -- direction / fiduciaire : fil choisi
    if v_fil is not null and not exists (
         select 1 from public.employes e where e.id = v_fil and e.role = 'employe') then
      return jsonb_build_object('ok', false, 'erreur', 'Employé introuvable');
    end if;
  end if;

  insert into public.messages (annee, mois, auteur_id, texte, employe_id,
                               lu_direction, lu_compta, lu_employe)
  values (p_annee, p_mois, v_emp.id, v_txt, v_fil,
          v_emp.role = 'admin', v_emp.role = 'compta',
          v_fil is null or v_emp.role = 'employe');
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.message_ecrire(uuid, int, int, text, uuid) from public, authenticated;
grant execute on function public.message_ecrire(uuid, int, int, text, uuid) to anon;

-- Lecture d'un fil : l'employé est toujours ramené au sien.
create or replace function public.messages_lire(
  p_token uuid, p_annee int, p_mois int, p_employe uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes; v_msgs jsonb; v_nl int; v_fil uuid; v_fils jsonb;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  if p_annee is null or p_mois is null or p_annee < 2020 or p_annee > 2100 or p_mois < 1 or p_mois > 12 then
    return jsonb_build_object('ok', false, 'erreur', 'Mois invalide');
  end if;
  v_fil := case when v_emp.role = 'employe' then v_emp.id else p_employe end;

  -- Marque le fil consulté comme lu pour celui qui le lit.
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

  select coalesce(jsonb_agg(public._msg_json(m) order by m.cree_le), '[]'::jsonb)
    into v_msgs from public.messages m
   where m.annee = p_annee and m.mois = p_mois and m.employe_id is not distinct from v_fil;

  -- Compteur global de non-lus, tous fils et tous mois confondus.
  select count(*) into v_nl from public.messages m
   where case v_emp.role
           when 'admin'  then not m.lu_direction
           when 'compta' then not m.lu_compta
           else m.employe_id = v_emp.id and not m.lu_employe
         end;

  -- Pour la direction et la fiduciaire : les fils qui contiennent des messages,
  -- avec leur nombre de non-lus, afin d'afficher un sélecteur.
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
                            'fils', v_fils, 'fil', v_fil);
end $$;
revoke execute on function public.messages_lire(uuid, int, int, uuid) from public, authenticated;
grant execute on function public.messages_lire(uuid, int, int, uuid) to anon;

-- Les anciennes signatures sans p_employe ne doivent plus subsister.
drop function if exists public.message_ecrire(uuid, int, int, text);
drop function if exists public.messages_lire(uuid, int, int);
