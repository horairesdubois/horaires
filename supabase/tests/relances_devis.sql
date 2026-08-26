-- Scénario des relances de devis, et de la file unifiée devis + factures.
--
--   psql -d horaires -f supabase/tests/relances_devis.sql
--
-- Vérifie :
--   1. l'escalade s'arrête au bon palier (J+5, J+15) ;
--   2. un devis déjà répondu n'est jamais relancé ;
--   3. un devis dont la validité est passée se classe « expiré » au lieu d'être relancé ;
--   4. accepter un devis éteint la relance en attente, dans la même transaction ;
--   5. la file unifiée rend les deux natures de document au back office.

insert into public.clients (nom, adresse, npa, ville, email)
values ('Régie Beaulieu SA','Av. de Champel 18','1206','Genève','compta@beaulieu.ch');

insert into public.devis (numero, client_id, objet, ttc, ht, tva, etat, envoye_le,
                          valable_jusqu_au, repondu_le)
select v.n, c.id, v.o, v.m, round(v.m/1.081,2), round(v.m-v.m/1.081,2), 'envoye',
       now() - (v.j || ' days')::interval,
       current_date + v.validite,
       case when v.repondu then now() else null end
  from public.clients c,
       (values ('D-2026-051','Remplacement chauffe-eau', 2400.00,  2, 28, false),
               ('D-2026-052','Réfection colonne',        8600.00,  8, 22, false),
               ('D-2026-053','Mise aux normes tableau',  3100.00, 20, 10, false),
               ('D-2026-054','Détartrage installation',   780.00, 20, 10, true),
               ('D-2026-055','Pompe de relevage',        1950.00, 20, -3, false)
       ) as v(n,o,m,j,validite,repondu);

select '— 1. pose des relances de devis —' as etape;
select jsonb_pretty(public.poser_relances_devis());

select '— 2. état de chaque devis —' as etape;
select d.numero, d.etat, r.niveau,
       current_date - (d.envoye_le at time zone 'Europe/Zurich')::date as jours,
       (d.repondu_le is not null) as repondu
  from public.devis d left join public.relances r on r.devis_id = d.id
 order by d.numero;

select '— 3. le client accepte le D-2026-053 —' as etape;
insert into public.employes (prenom, nom, pin_hash, role)
values ('Back', 'office', 'x', 'admin');
insert into public.sessions (token, employe_id)
select '11111111-1111-1111-1111-111111111111', id from public.employes where prenom='Back';

select jsonb_pretty(public.repondre_devis(
  '11111111-1111-1111-1111-111111111111',
  (select id from public.devis where numero='D-2026-053'), 'accepte'));

select d.numero, d.etat, (r.annulee_le is not null) as relance_eteinte
  from public.devis d join public.relances r on r.devis_id = d.id
 where d.numero = 'D-2026-053';

select '— 4. une facture échue, pour vérifier la file unifiée —' as etape;
insert into public.factures (numero, client_id, objet, ttc, ht, tva, reference, echeance)
select '2026-0140', c.id, 'Fuite colonne', 531.31, 491.50, 39.81,
       '001047002026014000000000005', current_date - 10 from public.clients c;
select public.poser_relances()->>'nombre' as relances_factures;

select '— 5. file unifiée telle que la lit le travailleur —' as etape;
select r->>'cible' as cible, r->>'niveau' as niveau,
       r->'document'->>'numero' as document, r->>'montant_du' as montant
  from jsonb_array_elements(
         public.relances_a_envoyer('11111111-1111-1111-1111-111111111111')->'relances') r;
