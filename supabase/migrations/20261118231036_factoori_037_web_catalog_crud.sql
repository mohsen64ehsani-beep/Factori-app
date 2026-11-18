begin;
-- 037: Safe authenticated CRUD for web and app catalog masters.
-- Financial documents continue to be created and posted only through validated RPCs.
alter table public.contacts enable row level security;
alter table public.products enable row level security;
alter table public.services enable row level security;

drop policy if exists contacts_web_insert on public.contacts;
create policy contacts_web_insert on public.contacts
 for insert to authenticated
 with check (private.has_business_permission(business_id,'contacts.write'));

drop policy if exists contacts_web_update on public.contacts;
create policy contacts_web_update on public.contacts
 for update to authenticated
 using (private.has_business_permission(business_id,'contacts.write'))
 with check (private.has_business_permission(business_id,'contacts.write'));

drop policy if exists products_web_insert on public.products;
create policy products_web_insert on public.products
 for insert to authenticated
 with check (private.has_business_permission(business_id,'catalog.write'));

drop policy if exists products_web_update on public.products;
create policy products_web_update on public.products
 for update to authenticated
 using (private.has_business_permission(business_id,'catalog.write'))
 with check (private.has_business_permission(business_id,'catalog.write'));

drop policy if exists services_web_insert on public.services;
create policy services_web_insert on public.services
 for insert to authenticated
 with check (private.has_business_permission(business_id,'catalog.write'));

drop policy if exists services_web_update on public.services;
create policy services_web_update on public.services
 using (private.has_business_permission(business_id,'catalog.write'))
 with check (private.has_business_permission(business_id,'catalog.write'));

revoke insert,update,delete on public.contacts,public.products,public.services from anon,public;
grant insert (business_id,contact_type,name,phone,code,address,notes,is_active,created_by)
 on public.contacts to authenticated;
grant update (contact_type,name,phone,code,address,notes,is_active)
 on public.contacts to authenticated;
grant insert (business_id,category_id,name,sku,barcode,unit_name,sale_price,track_inventory,minimum_stock,is_active,created_by)
 on public.products to authenticated;
grant update (category_id,name,sku,barcode,unit_name,sale_price,track_inventory,minimum_stock,is_active)
 on public.products to authenticated;
grant insert (business_id,name,description,sale_price,is_active,created_by)
 on public.services to authenticated;
grant update (name,description,sale_price,is_active)
 on public.services to authenticated;
commit;