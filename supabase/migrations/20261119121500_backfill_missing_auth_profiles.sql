-- Backfill profile rows for auth users created before the auth profile trigger existed.
-- The business_state_records.updated_by foreign key references public.profiles(id).
insert into public.profiles (id, display_name)
select u.id,
       coalesce(
         nullif(btrim(u.raw_user_meta_data->>'display_name'), ''),
         nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
         'کاربر'
       )
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;
