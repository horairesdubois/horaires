-- Catalogue de prestations, et relances des devis restés sans réponse.
--
-- POURQUOI UN CATALOGUE EN BASE
-- L'IA rédige les lignes d'un devis à partir du rapport dicté par le technicien.
-- Sans catalogue, elle invente des prix — plausibles, cohérents, et faux. Le
-- catalogue est la seule source de vérité tarifaire : le module de facturation
-- recalcule chaque ligne contre lui et marque à valider tout ce qui n'y figure
-- pas. L'IA choisit quoi facturer et combien d'unités ; elle ne choisit jamais
-- le prix, ni le format du document.
--
-- POURQUOI RELANCER AUSSI LES DEVIS
-- Un devis sans réponse n'est pas un refus, c'est un oubli. C'est le poste où
-- une relance rapporte le plus, parce qu'elle ramène du chiffre d'affaires au
-- lieu d'aller le rechercher. Deux paliers suffisent, puis on classe : au-delà,
-- insister abîme la relation sans rien changer.

-- ---------------------------------------------------------------- paramètres

insert into public.parametres (cle, valeur) values
  ('relance_devis_j1',      '5'),    -- jours après envoi
  ('relance_devis_j2',      '15'),
  ('devis_validite_jours',  '30')
on conflict (cle) do nothing;

-- ---------------------------------------------------------------- catalogue

create table public.prestations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  designation text not null,
  unite text not null default 'heure'
    check (unite in ('heure','forfait','piece','metre','jour','kilometre')),
  prix numeric(10,2) not null check (prix >= 0),
  famille text not null default 'divers',
  actif boolean not null default true,
  modifie_le timestamptz not null default now()
);
create index prestations_actives_idx on public.prestations (famille, code) where actif;

alter table public.prestations enable row level security;
revoke all on public.prestations from anon, authenticated;

-- Le catalogue de départ. Les prix sont à ajuster — ce sont des ordres de
-- grandeur, pas les vôtres.
insert into public.prestations (code, designation, unite, prix, famille) values
  ('MO-STD',   'Main-d''œuvre, heure ouvrable',              'heure',     125.00, 'main-d''oeuvre'),
  ('MO-SAM',   'Main-d''œuvre, samedi',                      'heure',     165.00, 'main-d''oeuvre'),
  ('MO-NUIT',  'Main-d''œuvre, nuit et dimanche',            'heure',     190.00, 'main-d''oeuvre'),
  ('DEP-GE',   'Déplacement, zone Genève',                   'forfait',    90.00, 'deplacement'),
  ('DEP-HORS', 'Déplacement hors canton',                    'kilometre',   1.20, 'deplacement'),
  ('URG-2H',   'Majoration urgence, intervention sous 2 h',  'forfait',   120.00, 'majoration'),
  ('DIAG',     'Diagnostic et devis sur place',              'forfait',    80.00, 'diagnostic')
on conflict (code) do nothing;

create or replace function public.catalogue(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'session');
  end if;
  return jsonb_build_object('ok', true, 'prestations', coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', p.code, 'designation', p.designation,
             'unite', p.unite, 'prix', p.prix, 'famille', p.famille)
           order by p.famille, p.code)
      from public.prestations p where p.actif), '[]'::jsonb));
end $$;
revoke execute on function public.catalogue(uuid) from public, authenticated;
grant execute on function public.catalogue(uuid) to anon;

-- ---------------------------------------------------------------- relances devis

-- Une relance porte désormais sur une facture OU sur un devis, jamais les deux.
alter table public.relances
  alter column facture_id drop not null,
  add column devis_id uuid references public.devis(id) on delete cascade,
  add constraint relances_une_cible check (
    (facture_id is not null and devis_id is null) or
    (facture_id is null and devis_id is not null));

-- L'unicité par niveau valait pour les factures ; il en faut l'équivalent pour
-- les devis, et l'ancienne contrainte doit tolérer un facture_id nul.
alter table public.relances drop constraint if exists relances_facture_id_niveau_key;
create unique index relances_facture_niveau_idx
  on public.relances (facture_id, niveau) where facture_id is not null;
create unique index relances_devis_niveau_idx
  on public.relances (devis_id, niveau) where devis_id is not null;

create or replace function public._devis_json(d public.devis)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', d.id, 'numero', d.numero, 'objet', d.objet, 'lieu', d.lieu,
    'client', (select c.nom from public.clients c where c.id = d.client_id),
    'lignes', d.lignes, 'ht', d.ht, 'tva', d.tva, 'ttc', d.ttc,
    'etat', d.etat,
    'envoye_le', to_char(d.envoye_le at time zone 'Europe/Zurich', 'DD.MM.YYYY'),
    'valable_jusqu_au', to_char(d.valable_jusqu_au, 'DD.MM.YYYY'),
    'jours_sans_reponse', case when d.envoye_le is null then null
      else (current_date - (d.envoye_le at time zone 'Europe/Zurich')::date) end,
    'redige_par_ia', d.redige_par_ia,
    'relances', (select coalesce(max(r.niveau), 0) from public.relances r
                  where r.devis_id = d.id and r.annulee_le is null))
$$;

/**
 * Relance des devis envoyés et restés sans réponse. Deux paliers, puis on
 * classe en « expiré » — insister au-delà abîme la relation sans rien changer.
 * Un devis répondu, accepté ou refusé, sort du cycle immédiatement.
 */
create or replace function public.poser_relances_devis()
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_posees jsonb := '[]'::jsonb; v_j int[]; v_niveau int; v_d record;
begin
  select array[
    (select valeur::int from public.parametres where cle = 'relance_devis_j1'),
    (select valeur::int from public.parametres where cle = 'relance_devis_j2')]
    into v_j;

  -- Un devis dont la validité est passée se classe, il ne se relance plus.
  update public.devis
     set etat = 'expire'
   where etat = 'envoye' and valable_jusqu_au is not null
     and valable_jusqu_au < current_date;

  for v_niveau in reverse 2 .. 1 loop
    for v_d in
      select d.* from public.devis d
       where d.etat = 'envoye'
         and d.envoye_le is not null
         and d.repondu_le is null
         and current_date >= (d.envoye_le at time zone 'Europe/Zurich')::date + v_j[v_niveau]
         and not exists (select 1 from public.relances r
                          where r.devis_id = d.id and r.niveau >= v_niveau
                            and r.annulee_le is null)
    loop
      insert into public.relances (devis_id, niveau, montant_du, interets)
      values (v_d.id, v_niveau, v_d.ttc, 0)
      on conflict (devis_id, niveau) where devis_id is not null do nothing;

      v_posees := v_posees || jsonb_build_object(
        'devis', v_d.numero, 'niveau', v_niveau, 'montant', v_d.ttc,
        'sans_reponse_depuis', current_date - (v_d.envoye_le at time zone 'Europe/Zurich')::date);
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'posees', v_posees,
    'nombre', jsonb_array_length(v_posees));
end $$;
revoke execute on function public.poser_relances_devis() from anon, authenticated, public;

/**
 * Réponse du client à un devis. Comme pour un paiement, la réponse éteint la
 * relance en attente dans la même transaction : un devis accepté le matin ne
 * doit pas être relancé l'après-midi.
 */
create or replace function public.repondre_devis(
  p_token uuid, p_devis uuid, p_reponse text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'Accès refusé');
  end if;
  if p_reponse not in ('accepte', 'refuse') then
    return jsonb_build_object('ok', false, 'erreur', 'Réponse invalide');
  end if;

  update public.devis set etat = p_reponse, repondu_le = now()
   where id = p_devis and etat in ('envoye', 'expire');

  update public.relances set annulee_le = now()
   where devis_id = p_devis and envoyee_le is null and annulee_le is null;

  return jsonb_build_object('ok', true, 'etat', p_reponse);
end $$;
revoke execute on function public.repondre_devis(uuid, uuid, text) from public, authenticated;
grant execute on function public.repondre_devis(uuid, uuid, text) to anon;

-- Conséquence du passage à des index partiels : poser_relances() visait la
-- contrainte relances_facture_id_niveau_key, qui n'existe plus. Une inférence
-- ON CONFLICT ne peut pas désigner un index partiel sans en répéter la
-- condition — sans quoi la pose des relances de factures échoue à l'exécution,
-- pas à la migration. On redéfinit donc la fonction ici, dans la migration qui
-- casse l'ancienne, plutôt que de laisser un piège pour le prochain déploiement.
create or replace function public.poser_relances()
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_posees jsonb := '[]'::jsonb; v_j int[]; v_niveau int; v_f record;
begin
  select array[
    (select valeur::int from public.parametres where cle = 'relance_j1'),
    (select valeur::int from public.parametres where cle = 'relance_j2'),
    (select valeur::int from public.parametres where cle = 'relance_j3')]
    into v_j;

  for v_niveau in reverse 3 .. 1 loop
    for v_f in
      select f.* from public.factures f
       where f.etat = 'emise'
         and f.bloquee_le is null
         and f.ttc - f.paye_total > 0.05
         and current_date >= f.echeance + v_j[v_niveau]
         and not exists (select 1 from public.relances r
                          where r.facture_id = f.id and r.niveau >= v_niveau
                            and r.annulee_le is null)
    loop
      insert into public.relances (facture_id, niveau, montant_du, interets)
      values (
        v_f.id, v_niveau, round(v_f.ttc - v_f.paye_total, 2),
        case when v_niveau = 3
             then public._interet_moratoire(v_f.ttc - v_f.paye_total, v_f.echeance)
             else 0 end)
      on conflict (facture_id, niveau) where facture_id is not null do nothing;

      v_posees := v_posees || jsonb_build_object(
        'facture', v_f.numero, 'niveau', v_niveau,
        'retard', current_date - v_f.echeance,
        'montant', round(v_f.ttc - v_f.paye_total, 2));
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'quand', to_char(now(), 'DD.MM.YYYY HH24:MI'),
    'posees', v_posees, 'nombre', jsonb_array_length(v_posees));
end $$;
revoke execute on function public.poser_relances() from anon, authenticated, public;

-- ------------------------------------------------- file d'attente unifiée

-- Remplace la version « factures seules » : le travailleur applicatif lit une
-- seule file et sait, pour chaque ligne, s'il fabrique un rappel de facture ou
-- une relance de devis.
create or replace function public.relances_a_envoyer(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'Accès refusé');
  end if;

  return jsonb_build_object('ok', true, 'relances', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id,
             'cible', case when r.facture_id is not null then 'facture' else 'devis' end,
             'niveau', r.niveau,
             'montant_du', r.montant_du, 'interets', r.interets,
             'document', case when f.id is not null
                              then public._facture_json(f)
                              else public._devis_json(d) end,
             'client_email', c.email, 'client_numero', c.numero)
           order by r.posee_le)
      from public.relances r
      left join public.factures f on f.id = r.facture_id
      left join public.devis    d on d.id = r.devis_id
      join public.clients c on c.id = coalesce(f.client_id, d.client_id)
     where r.envoyee_le is null and r.annulee_le is null), '[]'::jsonb));
end $$;
revoke execute on function public.relances_a_envoyer(uuid) from public, authenticated;
grant execute on function public.relances_a_envoyer(uuid) to anon;

/** Marque une relance expédiée. Appelée par le travailleur après l'envoi réel. */
create or replace function public.marquer_relance_envoyee(p_token uuid, p_relance bigint)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'Accès refusé');
  end if;
  update public.relances set envoyee_le = now()
   where id = p_relance and envoyee_le is null and annulee_le is null;
  return jsonb_build_object('ok', found);
end $$;
revoke execute on function public.marquer_relance_envoyee(uuid, bigint) from public, authenticated;
grant execute on function public.marquer_relance_envoyee(uuid, bigint) to anon;

-- Planification (à poser une seule fois) :
--   select cron.schedule('poser-relances-devis', '45 6 * * 1-5',
--                        $$select public.poser_relances_devis();$$);
-- Un quart d'heure après les factures, pour que les deux files arrivent
-- ensemble au back office plutôt qu'en deux vagues.
