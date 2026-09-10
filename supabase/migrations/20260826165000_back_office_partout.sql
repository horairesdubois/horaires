-- « Back Office » devient le seul nom de l'accès d'administration.
--
-- Plus de « direction » ni d'« administration » dans ce que lisent les
-- techniciens et la fiduciaire : un seul interlocuteur, un seul mot.
--
-- Deux fonctions renvoient encore des messages d'erreur qui parlent de la
-- direction (_save_jour et supprimer_jour), et _msg_json signe les rappels
-- automatiques « Back office ». Plutôt que de recopier des corps entiers —
-- et risquer d'y perdre une correction au passage — on régénère chaque
-- fonction à partir de sa propre définition, en n'y changeant que le texte.
do $do$
declare
  v_def text;
  v_neuf text;
  v_oid oid;
begin
  for v_oid, v_def in
    select p.oid, pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and (pg_get_functiondef(p.oid) like '%par la direction%'
            or pg_get_functiondef(p.oid) like '%''Back office''%')
  loop
    v_neuf := replace(v_def, 'par la direction', 'par le back office');
    v_neuf := replace(v_neuf, '''Back office''', '''Back Office''');
    if v_neuf <> v_def then
      execute v_neuf;
      raise notice 'Libellés mis à jour : %', v_oid::regprocedure;
    end if;
  end loop;
end $do$;

-- Le compte d'administration s'appelle désormais Back Office : c'est le nom
-- qui apparaît dans la liste des accès et en tête des fils de discussion.
update public.employes set prenom = 'Back Office', nom = ''
 where role = 'admin' and prenom in ('Direction', 'Administration');

-- Le métier du compte d'administration disait « Direction » ; il n'a plus lieu
-- d'être affiché : la liste des accès décrit désormais le rôle en toutes lettres.
update public.employes set metier = ''
 where role = 'admin' and metier in ('Direction', 'Administration');
