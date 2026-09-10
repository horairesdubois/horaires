-- Régression métier et permissions, sur cinq comptes synthétiques temporaires.
-- Aucun compte existant n'est lu ou modifié. Tout est annulé au ROLLBACK.
-- À exécuter après la migration, avec psql -v ON_ERROR_STOP=1 ou un outil SQL
-- qui s'arrête à la première erreur. Chaque échec lève une exception.
begin;
set local statement_timeout = '15s';
set local plpgsql.check_asserts = on;
set local request.headers = '{"user-agent":"Test SQL synthétique"}';

create temp table test_verrou (lib text primary key, id uuid, token uuid) on commit drop;
insert into test_verrou (lib, id, token) select x, gen_random_uuid(), gen_random_uuid()
from unnest(array['technicien','autre','admin','compta','demo']) x;
insert into public.employes (id, prenom, nom, pin_hash, role, demo)
select id, 'Test verrou ' || lib, 'SYNTHETIQUE', 'aucun-code-utilisable',
       case when lib in ('admin','compta') then lib else 'employe' end, lib = 'demo'
from test_verrou;
insert into public.sessions (token, employe_id) select token, id from test_verrou;

do $$
declare
  t uuid; a uuid; c uuid; x uuid; d uuid;
  ti uuid; ai uuid; ci uuid; xi uuid; di uuid;
  j date := date '2099-11-04'; r jsonb; avant jsonb; p public.pointages;
  n bigint; n2 bigint;
begin
  select token,id into t,ti from test_verrou where lib='technicien';
  select token,id into a,ai from test_verrou where lib='admin';
  select token,id into c,ci from test_verrou where lib='compta';
  select token,id into x,xi from test_verrou where lib='autre';
  select token,id into d,di from test_verrou where lib='demo';

  r := public.admin_enregistrer_jour(a,ti,j,'travail','08:00','12:00','travail','13:00','17:00','');
  assert (r->>'ok')::boolean, 'BO peut préparer une journée';
  r := public.admin_approuver(a,ti,null,null,j,true);
  assert r->>'code' = 'confirmation_requise', 'Approbation interdite avant confirmation';
  r := public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','17:00','');
  assert (r->>'ok')::boolean, 'Première confirmation employé';
  select * into p from public.pointages where employe_id=ti and jour=j;
  assert p.saisi_par=ti and not p.approuve, 'Confirmée, en attente du contrôle BO';
  avant := to_jsonb(p);
  select count(*) into n from public.journal;

  r := public.enregistrer_jour(t,j,'travail','07:00','12:00','travail','13:00','17:00','');
  assert r->>'code'='jour_verrouille', 'Horaire verrouillé';
  r := public.enregistrer_jour(t,j,'vacances','','','travail','13:00','17:00','');
  assert r->>'code'='jour_verrouille', 'Absence verrouillée';
  r := public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','17:00','Retouche');
  assert r->>'code'='jour_verrouille', 'Remarque verrouillée';
  r := public.enregistrer_jour(t,j,'travail','','','travail','','','');
  assert r->>'code'='jour_verrouille', 'Suppression par champs vides verrouillée';
  r := public.supprimer_jour(t,j);
  assert r->>'code'='jour_verrouille', 'Suppression directe verrouillée';
  assert (select to_jsonb(q) from public.pointages q where employe_id=ti and jour=j)=avant,
    'Aucune colonne ne change après les cinq refus';
  select count(*) into n2 from public.journal;
  assert n=n2, 'Une écriture refusée ne fabrique pas de modification dans le journal';

  r := public.enregistrer_jour(gen_random_uuid(),j,'travail','08:00','12:00','travail','13:00','17:00','');
  assert r->>'erreur'='session', 'Session inconnue refusée';
  r := public.enregistrer_jour(c,j,'travail','08:00','12:00','travail','13:00','17:00','');
  assert not (r->>'ok')::boolean, 'La fiduciaire ne saisit pas';
  r := public.supprimer_jour(c,j);
  assert not (r->>'ok')::boolean, 'La fiduciaire ne supprime pas';
  r := public.admin_enregistrer_jour(x,ti,j,'travail','07:00','12:00','travail','13:00','17:00','');
  assert not (r->>'ok')::boolean, 'Un autre employé ne peut pas cibler la journée';
  r := public.admin_supprimer_jour(x,ti,j);
  assert not (r->>'ok')::boolean, 'Suppression de la journée d’un autre refusée';
  r := public.admin_approuver(t,ti,null,null,j,false);
  assert not (r->>'ok')::boolean, 'Employé ne se déverrouille pas';
  r := public.admin_approuver(c,ti,null,null,j,false);
  assert not (r->>'ok')::boolean, 'Fiduciaire ne déverrouille pas';

  r := public.demande_modification(t,j,' ');
  assert not (r->>'ok')::boolean, 'Motif obligatoire';
  r := public.demande_modification(t,j,'Corriger la fin du dépannage');
  assert (r->>'ok')::boolean, 'Demande possible dès la confirmation';
  r := public.demande_modification(t,j,'Deuxième demande simultanée');
  assert not (r->>'ok')::boolean, 'Une seule demande en attente';
  r := public.demande_modification(x,j,'La journée de mon collègue');
  assert not (r->>'ok')::boolean, 'Demande limitée à sa propre journée';
  r := public.admin_repondre_demande(t,ti,j,true,'');
  assert not (r->>'ok')::boolean, 'Le demandeur ne peut pas accorder';
  r := public.admin_repondre_demande(c,ti,j,true,'');
  assert not (r->>'ok')::boolean, 'La compta ne peut pas accorder';
  r := public.admin_repondre_demande(a,ti,j,null,'');
  assert not (r->>'ok')::boolean, 'Décision explicite requise';
  r := public.admin_repondre_demande(a,ti,j,false,'Horaire à conserver');
  assert (r->>'ok')::boolean, 'Refus du BO';
  select * into p from public.pointages where employe_id=ti and jour=j;
  assert p.saisi_par=ti and not p.approuve and p.demande_etat='refusee', 'Refus conserve verrou';
  r := public.supprimer_jour(t,j);
  assert r->>'code'='jour_verrouille', 'Refus ne permet pas suppression';

  r := public.demande_modification(t,j,'Le dépannage a fini une heure plus tard');
  assert (r->>'ok')::boolean, 'Une demande motivée peut suivre un refus';
  r := public.admin_repondre_demande(a,ti,j,true,'Correction autorisée');
  assert (r->>'ok')::boolean, 'Accord BO';
  select * into p from public.pointages where employe_id=ti and jour=j;
  assert p.saisi_par is null and not p.approuve and p.demande_etat='accordee', 'Accord retire les deux verrous';
  assert p.approuve_par is null and p.approuve_le is null, 'Métadonnées approbation réinitialisées';
  assert p.matin_debut='08:00'::time and p.apm_fin='17:00'::time, 'Déblocage ne change pas les heures';
  r := public.admin_approuver(a,ti,null,null,j,true);
  assert r->>'code'='confirmation_requise', 'Nouvelle confirmation nécessaire';
  r := public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','18:00','Dépannage prolongé');
  assert (r->>'ok')::boolean, 'Correction autorisée après accord';
  select * into p from public.pointages where employe_id=ti and jour=j;
  assert p.saisi_par=ti and not p.approuve and p.demande_etat is null, 'Correction reconfirme et solde demande';
  r := public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','19:00','Encore');
  assert r->>'code'='jour_verrouille', 'Deuxième correction interdite sans nouveau cycle';
  r := public.admin_approuver(a,ti,null,null,j,true);
  assert (r->>'ok')::boolean, 'Approbation après reconfirmation';
  select * into p from public.pointages where employe_id=ti and jour=j;
  assert p.approuve and p.approuve_par=ai and p.saisi_par=ti, 'Approbation attribuée au BO';
  assert exists(select 1 from public.journal where action='modification' and acteur_id=ti
    and detail->>'motif_demande'='Le dépannage a fini une heure plus tard'
    and (detail->>'delta')::int=60), 'Journal préserve motif et avant/après';
  assert exists(select 1 from public.journal where action='deblocage_accorde' and acteur_id=ai), 'Accord attribué au BO';
  r := public.demande_modification(t,j,'Revoir cette journée approuvée');
  assert (r->>'ok')::boolean, 'Demande toujours possible après approbation';
  r := public.admin_approuver(a,ti,null,null,j,true);
  assert r->>'code'='demande_en_attente', 'Approbation ne court-circuite pas demande';
  r := public.admin_approuver(a,ti,null,null,j,false);
  assert r->>'code'='demande_en_attente', 'Réouverture directe ne court-circuite pas demande';
  r := public.admin_approuver(a,ti,2099,11,null,true);
  assert r->>'code'='demande_en_attente', 'Lot ne court-circuite pas demande';
  r := public.admin_enregistrer_jour(a,ti,j,'travail','08:00','12:00','travail','13:00','18:00','Correction BO');
  assert (select demande_etat from public.pointages where employe_id=ti and jour=j)='attente', 'Correction BO conserve demande';
  r := public.admin_repondre_demande(a,ti,j,true,'Correction autorisée');
  assert (r->>'ok')::boolean, 'Réponse admin nécessaire';
  select * into p from public.pointages where employe_id=ti and jour=j;
  assert p.saisi_par is null and not p.approuve and p.demande_etat='accordee', 'Accord retire les deux verrous';
  r := public.supprimer_jour(t,j);
  assert (r->>'ok')::boolean, 'Suppression autorisée après réouverture';
  assert not exists(select 1 from public.pointages where employe_id=ti and jour=j), 'Journée rouverte supprimée';

  -- Lot mensuel : une journée confirmée, une à confirmer et une approuvée historique.
  r := public.enregistrer_jour(t,j,'travail','08:00','12:00','travail','13:00','17:00','');
  r := public.admin_enregistrer_jour(a,ti,j+1,'travail','08:00','12:00','travail','13:00','17:00','');
  insert into public.pointages (employe_id,jour,approuve,approuve_par,approuve_le)
  values (ti,j+2,true,ai,now());
  r := public.admin_approuver(a,ti,2099,11,null,true);
  assert r->>'code'='confirmation_requise', 'Lot incomplet refusé';
  assert not (select approuve from public.pointages where employe_id=ti and jour=j), 'Aucune approbation partielle';
  assert (select approuve from public.pointages where employe_id=ti and jour=j+2), 'Historique préservé';
  r := public.enregistrer_jour(t,j+1,'travail','08:00','12:00','travail','13:00','17:00','');
  r := public.admin_approuver(a,ti,2099,11,null,true);
  assert (r->>'ok')::boolean and (r->>'nombre')::int=2, 'Lot confirmé approuvé';
  r := public.admin_approuver(a,ti,2099,11,null,false);
  assert (r->>'ok')::boolean and (r->>'nombre')::int=3, 'Réouverture mensuelle';
  assert not exists(select 1 from public.pointages where employe_id=ti and (approuve or saisi_par=ti)),
    'Réouverture mensuelle retire toutes confirmations et approbations';

  -- Le mode démonstration ne laisse aucune trace, même si le BO intervient.
  select count(*) into n from public.journal;
  r := public.enregistrer_jour(d,j,'travail','08:00','12:00','travail','13:00','17:00','');
  r := public.demande_modification(d,j,'Corriger une journée de démonstration');
  r := public.admin_repondre_demande(a,di,j,false,'Refus test');
  r := public.demande_modification(d,j,'Nouvelle demande de démonstration');
  r := public.admin_repondre_demande(a,di,j,true,'Accord test');
  select count(*) into n2 from public.journal;
  assert n=n2, 'Aucune trace démonstration côté employé ou BO';

  r := public.journal_lire(t,7,null);
  assert not (r->>'ok')::boolean, 'Employé ne voit pas le journal';
  r := public.journal_lire(c,7,null);
  assert not (r->>'ok')::boolean, 'Fiduciaire ne voit pas le journal';
  assert not has_function_privilege('anon','public._verrou_pointages(uuid)','EXECUTE'), 'Helper verrou privé';
  assert not has_function_privilege('authenticated','public._verrou_pointages(uuid)','EXECUTE'), 'Helper non exposé authenticated';
  assert not has_function_privilege('anon','public._save_jour(uuid,date,text,text,text,text,text,text,text,boolean,uuid)','EXECUTE'), 'Helper écriture privé';
  assert not has_function_privilege('authenticated','public.admin_repondre_demande(uuid,uuid,date,boolean,text)','EXECUTE'), 'Pas de grant implicite PUBLIC';
  assert has_function_privilege('anon','public.demande_modification(uuid,date,text)','EXECUTE'), 'RPC utilisable par le client';
  assert not has_table_privilege('anon','public.pointages','UPDATE'), 'Aucun nouvel accès direct aux pointages';
  assert not has_table_privilege('authenticated','public.pointages','DELETE'), 'Aucune suppression directe authenticated';
  raise notice 'OK : cycle, refus, réouverture, reconfirmation, lot atomique, accès et journal';
end $$;

-- La Data API doit aussi refuser une lecture directe du journal.
set local role anon;
do $$
begin
  begin
    perform 1 from public.journal limit 1;
    raise exception 'Lecture directe du journal accessible';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
