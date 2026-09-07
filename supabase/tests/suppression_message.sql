\set ON_ERROR_STOP on

-- GARDE-FOU — ce scénario écrit puis détruit de faux messages.
do $$
begin
  if exists (select 1 from public.pointages) then
    raise exception 'REFUS : cette base contient des pointages réels. Ce scénario ne se joue que sur une base jetable.';
  end if;
end $$;

-- Les comptes existent déjà (posés avant la migration qui vise « Alen »).
create temporary view jetons as
  select e.prenom, e.role, e.id, s.token
    from public.sessions s join public.employes e on e.id = s.employe_id;
insert into public.sessions (employe_id) select id from public.employes;

select '— 1. la direction écrit à Sami, Sami répond —' as etape;
select public.message_ecrire((select token from jetons where prenom='Hugo'), 2026, 9,
         'Bonjour Sami, question sur vos heures du 3.', (select id from jetons where prenom='Sami'));
select public.message_ecrire((select token from jetons where prenom='Hugo'), 2026, 9,
         'Oups, message envoyé par erreur.', (select id from jetons where prenom='Sami'));
select public.message_ecrire((select token from jetons where prenom='Sami'), 2026, 9, 'Bien reçu.');
select count(*) as messages_dans_le_fil from public.messages;

select '— 2. un technicien ne peut rien supprimer —' as etape;
select public.message_supprimer((select token from jetons where prenom='Sami'),
         (select id from public.messages where texte like 'Oups%')) as refus_technicien;

select '— 3. la fiduciaire non plus —' as etape;
select public.message_supprimer((select token from jetons where prenom='Fidu'),
         (select id from public.messages where texte like 'Oups%')) as refus_fiduciaire;

select '— 4. la direction ne peut pas supprimer le message de Sami —' as etape;
select public.message_supprimer((select token from jetons where prenom='Hugo'),
         (select id from public.messages where texte = 'Bien reçu.')) as refus_message_dautrui;

select '— 5. la direction supprime le sien —' as etape;
select public.message_supprimer((select token from jetons where prenom='Hugo'),
         (select id from public.messages where texte like 'Oups%')) as suppression;

select '— 6. le fil vu par Sami : la ligne a disparu, sans pierre tombale —' as etape;
select jsonb_array_length(
         (public.messages_lire((select token from jetons where prenom='Sami'), 2026, 9))->'messages')
       as messages_visibles_par_sami;
select jsonb_pretty(jsonb_agg(m->'texte'))as textes_restants
  from jsonb_array_elements(
         (public.messages_lire((select token from jetons where prenom='Sami'), 2026, 9))->'messages') m;

select '— 7. le journal, lui, l’a vue passer —' as etape;
select action, cible, detail->>'texte' as texte, detail->>'deja_lu' as deja_lu
  from public.journal where action = 'message_supprime';

select '— 8. et ce journal ne s’ouvre que depuis le back office —' as etape;
select prenom, role,
       coalesce((public.journal_lire(token, 30))->>'ok', 'null') as ok,
       coalesce((public.journal_lire(token, 30))->>'erreur', '') as erreur
  from jetons order by role;

select '— 9. un identifiant inconnu ne fait rien de fâcheux —' as etape;
select public.message_supprimer((select token from jetons where prenom='Hugo'),
         '00000000-0000-0000-0000-000000000000') as message_introuvable;
