begin;
-- 038: Avoid per-row re-evaluation of auth.uid() in profile and membership RLS.
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
 for select to authenticated
 using (id=(select auth.uid()));

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
 for update to authenticated
 using (id=(select auth.uid()))
 with check (id=(select auth.uid()));

drop policy if exists business_members_read on public.business_members;
create policy business_members_read on public.business_members
 for select to authenticated
 using ((user_id=(select auth.uid())) or private.has_business_permission(business_id,'members.read'));
commit;