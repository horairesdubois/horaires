-- Devis, factures QR et relances autonomes.
--
-- Le module reprend le geste qui a fait ses preuves avec le pointage : l'objet
-- existe en base, et la relance n'est plus qu'une conséquence. Trois principes
-- portent tout ce qui suit.
--
-- 1. LA RÉFÉRENCE EST IMMUABLE
--    La référence QRR est calculée une fois, à l'émission, et ne change plus —
--    ni au rappel, ni à la mise en demeure. C'est elle qui permet au camt.054
--    de la banque de dire quelle facture a été payée. Une référence qui change
--    en cours de route, c'est un client relancé après avoir payé.
--
-- 2. LE PAIEMENT ÉTEINT LA RELANCE AVANT TOUT
--    enregistrer_paiement() solde la facture ET annule les relances en attente
--    dans la même transaction. L'ordre compte : l'inverse laisse passer un
--    rappel pour une facture encaissée le matin même.
--
-- 3. RELANCER RESTE RÉVOCABLE
--    Une facture contestée se bloque (bloquee_le, bloquee_motif). Le litige est
--    la situation où une relance automatique coûte le plus cher — un client qui
--    a écrit et qu'on relance quand même ne revient pas.
--
-- L'ordonnanceur décide, il n'envoie pas : poser_relances() inscrit ce qui est
-- dû, le travailleur applicatif fabrique le PDF et l'expédie. La base ne sort
-- jamais sur le réseau, pour la raison apprise en août — le classificateur de
-- sécurité refuse les appels HTTPS sortants.

create extension if not exists pg_cron with schema extensions;

-- ---------------------------------------------------------------- paramètres

insert into public.parametres (cle, valeur) values
  ('facturation_iban',        ''),           -- QR-IBAN de la banque
  ('facturation_tva_numero',  ''),           -- CHE-xxx.xxx.xxx TVA
  ('facturation_tva_taux',    '8.1'),
  ('facturation_delai_jours', '30'),
  ('relance_j1',              '7'),          -- jours après échéance
  ('relance_j2',              '21'),
  ('relance_j3',              '35'),         -- mise en demeure
  ('relance_interet_taux',    '5')           -- art. 104 al. 1 CO
on conflict (cle) do nothing;

-- ---------------------------------------------------------------- tables

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  numero int generated always as identity (start with 1000) unique,
  nom text not null,
  adresse text not null default '',
  npa text not null default '',
  ville text not null default '',
  email text not null default '',
  telephone text not null default '',
  genre text not null default 'particulier'
    check (genre in ('particulier','regie','gerance','entreprise')),
  delai_jours int not null default 30 check (delai_jours between 0 and 120),
  actif boolean not null default true,
  cree_le timestamptz not null default now()
);
create index clients_nom_idx on public.clients (lower(nom));

-- Les lignes sont stockées en JSON : un devis est un document figé au moment de
-- l'envoi, pas une vue sur un catalogue qui bougera. Le prix pratiqué doit
-- rester lisible dix ans plus tard.
create table public.devis (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  client_id uuid not null references public.clients(id) on delete restrict,
  objet text not null default '',
  lieu text not null default '',
  lignes jsonb not null default '[]'::jsonb,
  ht numeric(10,2) not null default 0,
  tva numeric(10,2) not null default 0,
  ttc numeric(10,2) not null default 0,
  etat text not null default 'brouillon'
    check (etat in ('brouillon','envoye','accepte','refuse','expire')),
  valable_jusqu_au date,
  envoye_le timestamptz,
  repondu_le timestamptz,
  relance_devis_le timestamptz,
  redige_par_ia boolean not null default false,
  cree_le timestamptz not null default now()
);
create index devis_etat_idx on public.devis (etat, envoye_le);

create table public.factures (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  client_id uuid not null references public.clients(id) on delete restrict,
  devis_id uuid references public.devis(id) on delete set null,
  objet text not null default '',
  lieu text not null default '',
  lignes jsonb not null default '[]'::jsonb,
  ht numeric(10,2) not null default 0,
  tva numeric(10,2) not null default 0,
  ttc numeric(10,2) not null default 0,
  -- Calculée à l'émission, jamais recalculée. Voir principe 1 en tête de fichier.
  reference text not null unique,
  reference_type text not null default 'QRR' check (reference_type in ('QRR','SCOR')),
  emise_le date not null default current_date,
  echeance date not null,
  etat text not null default 'emise'
    check (etat in ('brouillon','emise','payee','annulee')),
  paye_total numeric(10,2) not null default 0,
  payee_le date,
  bloquee_le timestamptz,
  bloquee_motif text not null default '',
  cree_le timestamptz not null default now()
);
create index factures_impayees_idx on public.factures (echeance)
  where etat = 'emise';

create table public.paiements (
  id bigint generated always as identity primary key,
  facture_id uuid references public.factures(id) on delete set null,
  montant numeric(10,2) not null,
  date_valeur date not null default current_date,
  reference_lue text not null default '',
  source text not null default 'camt054' check (source in ('camt054','manuel')),
  enregistre_le timestamptz not null default now()
);
create index paiements_facture_idx on public.paiements (facture_id);

create table public.relances (
  id bigint generated always as identity primary key,
  facture_id uuid not null references public.factures(id) on delete cascade,
  niveau int not null check (niveau between 1 and 3),
  montant_du numeric(10,2) not null,
  interets numeric(10,2) not null default 0,
  posee_le timestamptz not null default now(),
  envoyee_le timestamptz,
  annulee_le timestamptz,
  unique (facture_id, niveau)
);
create index relances_a_envoyer_idx on public.relances (posee_le)
  where envoyee_le is null and annulee_le is null;

alter table public.clients   enable row level security;
alter table public.devis     enable row level security;
alter table public.factures  enable row level security;
alter table public.paiements enable row level security;
alter table public.relances  enable row level security;

revoke all on public.clients, public.devis, public.factures,
              public.paiements, public.relances
  from anon, authenticated;

-- ---------------------------------------------------------------- helpers

create or replace function public._facture_json(f public.factures)
returns jsonb
language sql stable set search_path = public, extensions
as $$
  select jsonb_build_object(
    'id', f.id, 'numero', f.numero, 'objet', f.objet, 'lieu', f.lieu,
    'client', (select c.nom from public.clients c where c.id = f.client_id),
    'lignes', f.lignes, 'ht', f.ht, 'tva', f.tva, 'ttc', f.ttc,
    'reference', f.reference, 'reference_type', f.reference_type,
    'emise_le', to_char(f.emise_le, 'DD.MM.YYYY'),
    'echeance', to_char(f.echeance, 'DD.MM.YYYY'),
    'etat', f.etat,
    'reste_du', round(f.ttc - f.paye_total, 2),
    'jours_de_retard', greatest(0, current_date - f.echeance),
    'bloquee', f.bloquee_le is not null,
    'bloquee_motif', f.bloquee_motif,
    'relances', (select coalesce(max(r.niveau), 0) from public.relances r
                  where r.facture_id = f.id and r.annulee_le is null))
$$;

/**
 * Intérêt moratoire, art. 104 al. 1 CO : 5 % l'an, base 360 jours.
 * Il n'est dû qu'à partir de la mise en demeure — d'où le niveau 3 seul
 * appelant, plus bas. Le facturer plus tôt est juridiquement fragile.
 */
create or replace function public._interet_moratoire(
  p_montant numeric, p_depuis date, p_jusqua date default current_date)
returns numeric
language sql stable set search_path = public, extensions
as $$
  select round(
    p_montant
    * (coalesce((select valeur::numeric from public.parametres
                  where cle = 'relance_interet_taux'), 5) / 100)
    * (greatest(0, p_jusqua - p_depuis)::numeric / 360), 2)
$$;

-- ---------------------------------------------------------------- paiements

/**
 * Rapprochement d'un encaissement. Appelée pour chaque écriture du camt.054.
 * La référence lue sur l'extrait fait foi ; à défaut, on retombe sur le solde
 * exact d'une facture ouverte — et seulement s'il n'y en a qu'une. Si le doute
 * subsiste, on ne devine pas : l'écriture est conservée sans facture et attend
 * un humain, la facture reste ouverte.
 */
create or replace function public.enregistrer_paiement(
  p_reference text, p_montant numeric, p_date date default current_date,
  p_source text default 'camt054')
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_f public.factures; v_reste numeric; v_ref text; v_n int;
begin
  -- Les banques ne rendent pas la référence telle qu'on l'a émise : espaces par
  -- groupes de cinq, parfois des tirets, parfois en minuscules pour un SCOR.
  -- On compare donc sur la forme nue, des deux côtés.
  v_ref := upper(regexp_replace(coalesce(p_reference, ''), '[^A-Za-z0-9]', '', 'g'));

  select * into v_f from public.factures
   where upper(regexp_replace(reference, '[^A-Za-z0-9]', '', 'g')) = v_ref
     and etat <> 'annulee';

  -- Repli : une seule facture ouverte dont le solde correspond au centime près.
  -- S'il y en a deux, on ne devine pas — deviner produit un client relancé pour
  -- une facture que quelqu'un d'autre a payée.
  if v_f.id is null and p_montant > 0 then
    select count(*) into v_n from public.factures
     where etat = 'emise' and abs(ttc - paye_total - p_montant) <= 0.05;
    if v_n = 1 then
      select * into v_f from public.factures
       where etat = 'emise' and abs(ttc - paye_total - p_montant) <= 0.05;
    end if;
  end if;

  if v_f.id is null then
    insert into public.paiements (facture_id, montant, date_valeur, reference_lue, source)
    values (null, p_montant, p_date, coalesce(p_reference, ''), p_source);
    return jsonb_build_object('ok', false,
      'erreur', 'Référence inconnue et montant non concluant — à rapprocher à la main');
  end if;

  insert into public.paiements (facture_id, montant, date_valeur, reference_lue, source)
  values (v_f.id, p_montant, p_date, coalesce(p_reference, ''), p_source);

  update public.factures
     set paye_total = paye_total + p_montant,
         etat    = case when paye_total + p_montant >= ttc - 0.05 then 'payee' else etat end,
         payee_le = case when paye_total + p_montant >= ttc - 0.05 then p_date else payee_le end
   where id = v_f.id
   returning ttc - paye_total into v_reste;

  -- Principe 2 : on éteint les relances en attente dans la même transaction.
  if v_reste <= 0.05 then
    update public.relances
       set annulee_le = now()
     where facture_id = v_f.id and envoyee_le is null and annulee_le is null;
  end if;

  return jsonb_build_object('ok', true, 'facture', v_f.numero,
    'reste_du', round(greatest(v_reste, 0), 2),
    'soldee', v_reste <= 0.05,
    'par_reference', v_ref = upper(regexp_replace(v_f.reference, '[^A-Za-z0-9]', '', 'g')));
end $$;
revoke execute on function public.enregistrer_paiement(text, numeric, date, text)
  from anon, authenticated, public;

-- ---------------------------------------------------------------- relances

/**
 * Inscrit les relances dues, sans rien envoyer. Le travailleur applicatif lit
 * ensuite les lignes non envoyées, fabrique le PDF avec la même référence et
 * expédie — puis repasse marquer envoyee_le.
 *
 * Les quatre garde-fous, dans l'ordre où ils écartent une facture :
 *   • déjà payée ou annulée ;
 *   • bloquée pour litige ;
 *   • le délai du palier n'est pas atteint ;
 *   • une relance de ce niveau existe déjà (contrainte d'unicité).
 */
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
        -- L'intérêt moratoire n'apparaît qu'à la mise en demeure.
        case when v_niveau = 3
             then public._interet_moratoire(v_f.ttc - v_f.paye_total, v_f.echeance)
             else 0 end)
      on conflict (facture_id, niveau) do nothing;

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

/** File d'attente lue par le travailleur applicatif, la plus ancienne d'abord. */
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
             'id', r.id, 'niveau', r.niveau,
             'montant_du', r.montant_du, 'interets', r.interets,
             'facture', public._facture_json(f),
             'client_email', c.email, 'client_numero', c.numero)
           order by r.posee_le)
      from public.relances r
      join public.factures f on f.id = r.facture_id
      join public.clients c on c.id = f.client_id
     where r.envoyee_le is null and r.annulee_le is null), '[]'::jsonb));
end $$;
revoke execute on function public.relances_a_envoyer(uuid) from public, authenticated;
grant execute on function public.relances_a_envoyer(uuid) to anon;

/** Bloque ou débloque une facture contestée — principe 3. */
create or replace function public.bloquer_facture(
  p_token uuid, p_facture uuid, p_motif text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare v_emp public.employes;
begin
  v_emp := public._auth(p_token);
  if v_emp.id is null or v_emp.role not in ('admin', 'compta') then
    return jsonb_build_object('ok', false, 'erreur', 'Accès refusé');
  end if;

  update public.factures
     set bloquee_le = case when trim(coalesce(p_motif, '')) = '' then null else now() end,
         bloquee_motif = left(trim(coalesce(p_motif, '')), 200)
   where id = p_facture;

  update public.relances set annulee_le = now()
   where facture_id = p_facture and envoyee_le is null and annulee_le is null
     and trim(coalesce(p_motif, '')) <> '';

  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.bloquer_facture(uuid, uuid, text) from public, authenticated;
grant execute on function public.bloquer_facture(uuid, uuid, text) to anon;

-- Planification (à poser une seule fois, comme la relance des saisies) :
--   select cron.schedule('poser-relances', '30 6 * * 1-5',
--                        $$select public.poser_relances();$$);
-- Du lundi au vendredi à 6h30 UTC, soit 8h30 à Genève l'été. Jamais le week-end :
-- une mise en demeure reçue un samedi ne se règle pas plus vite, et se retient.
