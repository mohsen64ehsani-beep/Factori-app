begin;
drop policy if exists services_web_update on public.services;
create policy services_web_update on public.services
 for update to authenticated
 using (private.has_business_permission(business_id,'catalog.write'))
 with check (private.has_business_permission(business_id,'catalog.write'));
commit;