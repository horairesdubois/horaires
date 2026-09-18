-- Retrait de la simulation demandé le 18 septembre 2026.
-- Les données historiques restent archivées ; seuls les accès démo sont révoqués.
begin;
update public.sessions set expire_le=least(expire_le,now())
where employe_id in (select id from public.employes where demo);
update public.employes set actif=false, pin_actif=false where demo;
commit;
