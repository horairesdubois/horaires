-- Activation autorisée pour tous les techniciens après publication de l'interface.
-- Les comptes de démonstration et les comptes désactivés gardent leur état.
alter table public.employes alter column pointage_actif set default true;
update public.employes set pointage_actif=true where role='employe' and actif and not demo;
