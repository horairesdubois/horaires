-- Arrêt des rappels automatiques, pour tout le monde.
--
-- POURQUOI UN INTERRUPTEUR ET NON UNE SUPPRESSION DE CODE
-- Le contrôle des saisies garde toute son utilité pour la direction : savoir qui
-- est en retard reste nécessaire, c'est écrire au technicien qui ne l'est plus.
-- On coupe donc l'envoi, pas la surveillance — et d'un seul geste, réversible.
--
-- OÙ LA COUPURE EST POSÉE
-- Dans relancer_saisies, la fonction appelée par l'ordonnanceur, et nulle part
-- ailleurs. controle_saisies n'est pas redéfinie : elle a divergé du dépôt en
-- production (la formulation du message qui y est écrite n'existe dans aucune
-- migration), et la remplacer effacerait ce que quelqu'un y a mis à la main.
-- La coupure passe donc par l'appelant, qui demande désormais un contrôle en
-- lecture seule — p_relancer à faux, aucun message posé.
--
-- CE QUI CONTINUE DE TOURNER
-- Le pré-remplissage de la veille, s'il est installé. Il ne parle à personne :
-- il pose les journées types que le technicien retrouvera dans l'application.
--
-- CE QUI RESTE POSSIBLE
-- Un appel direct à controle_saisies(secret, true) poste encore des messages.
-- Seul le porteur du secret de contrôle peut le faire ; l'ordonnanceur, lui, ne
-- le demande plus.

insert into public.parametres (cle, valeur)
values ('rappels_automatiques', 'non')
on conflict (cle) do update set valeur = 'non';

/**
 * Réveillé par pg_cron. Ne poste plus aucun rappel tant que le paramètre
 * « rappels_automatiques » ne vaut pas 'oui'.
 *
 * Codes de retour, pour relire cron.job_run_details sans ambiguïté :
 *   -1  ce n'était pas l'heure
 *   -2  les rappels sont coupés — le contrôle a tourné, personne n'a été écrit
 *    n  n rappels posés
 */
create or replace function public.relancer_saisies()
returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare v_n int; v_actifs boolean;
begin
  if extract(hour from now() at time zone 'Europe/Zurich')::int <> 9 then
    return -1;
  end if;

  -- Le pré-remplissage ne dépend pas des rappels : il tourne dans tous les cas,
  -- et seulement s'il a été installé — cette migration doit pouvoir s'appliquer
  -- seule, en urgence, sans rien supposer du reste.
  if to_regprocedure('public.generer_pointages_manquants()') is not null then
    perform public.generer_pointages_manquants();
  end if;

  select coalesce((select lower(trim(valeur)) from public.parametres
                    where cle = 'rappels_automatiques'), 'non') = 'oui'
    into v_actifs;

  if not v_actifs then
    -- Contrôle en lecture seule : la direction garde sa vue, personne n'est écrit.
    perform public.controle_saisies(
      (select valeur from public.parametres where cle = 'controle_secret'), false);
    return -2;
  end if;

  select jsonb_array_length(
           (public.controle_saisies(
              (select valeur from public.parametres where cle = 'controle_secret'), true)
           )->'relances_posees')
    into v_n;
  return coalesce(v_n, 0);
end $$;
revoke execute on function public.relancer_saisies() from anon, authenticated, public;

-- Retrait de toute tâche du soir. Celles du matin, si elles existent, restent :
-- elles portent le pré-remplissage, qui n'écrit à personne.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid)
       from cron.job
      where command ilike '%relancer_saisies%'
        and jobname not in ('relance-saisies-matin-a', 'relance-saisies-matin-b');
  else
    raise notice 'pg_cron absent : retirer la tâche du soir à la main.';
  end if;
exception when others then
  raise notice 'Retrait impossible ici (%). À faire à la main.', sqlerrm;
end $$;

-- Pour rallumer un jour, sans redéployer :
--   update public.parametres set valeur = 'oui' where cle = 'rappels_automatiques';
-- Les interrupteurs par personne (employes.notifications) restent tels quels :
-- ils reprendront leur effet à ce moment-là, Alen inclus.
