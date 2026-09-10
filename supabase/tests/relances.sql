-- Scénario de bout en bout des relances, à rejouer sur une base vierge.
--
--   psql -d horaires -f supabase/tests/relances.sql
--
-- Ce qu'il vérifie, dans l'ordre :
--   1. l'escalade s'arrête au bon palier selon le retard (J+7, J+21, J+35) ;
--   2. l'intérêt moratoire n'apparaît qu'à la mise en demeure (art. 104 CO) ;
--   3. une facture contestée n'est jamais relancée ;
--   4. un paiement reçu avec la référence telle que la banque la rend
--      (groupée par cinq depuis la droite) solde la facture ET éteint la
--      relance en attente ;
--   5. sans référence lisible, le repli sur le montant fonctionne s'il n'y a
--      qu'une seule facture ouverte à ce solde ;
--   6. et refuse de deviner dès qu'il y en a deux.
--
-- Les références sont celles que produit facturation/reference.mjs pour le
-- client 1047 : les deux moitiés du système doivent tomber d'accord.

\set ON_ERROR_STOP on

-- GARDE-FOU — À LIRE AVANT DE LANCER
-- Ce scénario écrit de fausses données. Joué par mégarde sur la base de
-- production, il y injecterait des clients et des documents fictifs. Il refuse
-- donc de démarrer sur une base qui contient de vrais employés ou de vrais
-- pointages : seule une base jetable passe.
do $$
begin
  if exists (select 1 from public.employes) or exists (select 1 from public.pointages) then
    raise exception 'REFUS : cette base contient des données réelles. Ce scénario ne se joue que sur une base jetable.';
  end if;
end $$;

insert into public.clients (nom, adresse, npa, ville, email)
values ('Régie Beaulieu SA','Av. de Champel 18','1206','Genève','compta@beaulieu.ch');

insert into public.factures (numero, client_id, objet, ttc, ht, tva, reference, echeance)
select v.n, c.id, v.o, v.m, round(v.m/1.081,2), round(v.m-v.m/1.081,2), v.r, current_date - v.j
  from public.clients c,
       (values ('2026-0140','Fuite colonne',  531.31,'001047002026014000000000005',10),
               ('2026-0141','Chauffe-eau',    890.00,'001047002026014100000000002',25),
               ('2026-0142','Débouchage',     420.00,'001047002026014200000000003',40),
               ('2026-0143','Litige robinet', 300.00,'001047002026014300000000007',40)
       ) as v(n,o,m,r,j);
update public.factures set bloquee_le = now(), bloquee_motif = 'Contestée par courriel du 20.08'
 where numero = '2026-0143';

select public.poser_relances()->>'nombre' as relances_posees;
select f.numero, r.niveau, r.montant_du, r.interets, (f.bloquee_le is not null) as bloquee
  from public.factures f left join public.relances r on r.facture_id = f.id order by f.numero;

select '— paiement, référence telle que la banque la rend —' as etape;
select jsonb_pretty(public.enregistrer_paiement('00 10470 02026 01420 00000 00003', 420.00));

select f.numero, f.etat, f.payee_le, r.niveau, (r.annulee_le is not null) as relance_eteinte
  from public.factures f join public.relances r on r.facture_id = f.id where f.numero='2026-0142';

select '— repli sur le montant : 890.00 sans référence lisible —' as etape;
select jsonb_pretty(public.enregistrer_paiement('***illisible***', 890.00));

select '— montant ambigu : deux factures ouvertes à 531.31 —' as etape;
insert into public.factures (numero, client_id, objet, ttc, ht, tva, reference, echeance)
select '2026-0144', c.id, 'Doublon', 531.31, 491.50, 39.81, '001047002026014400000000004', current_date
  from public.clients c;
select jsonb_pretty(public.enregistrer_paiement('***illisible***', 531.31));

select '— état final —' as etape;
select numero, etat, paye_total, ttc from public.factures order by numero;
