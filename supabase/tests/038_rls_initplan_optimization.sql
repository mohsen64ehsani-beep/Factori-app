-- 038: RLS policies use init-plan-friendly auth.uid() expressions.
begin;
do $$
declare v record;
begin
  select qual into v from pg_policies where schemaname='public' and tablename='profiles' and policyname='profiles_select_self';
  if v.qual is null or v.qual ilike '%id = auth.uid()%' then
    raise exception 'profiles_select_self must use a scalar subselect for auth.uid()';
  end if;
  select qual into v from pg_policies where schemaname='public' and tablename='profiles' and policyname='profiles_update_self';
  if v.qual is null or v.qual ilike '%id = auth.uid()%' then
    raise exception 'profiles_update_self must use a scalar subselect for auth.uid()';
  end if;
  select qual into v from pg_policies where schemaname='public' and tablename='business_members' and policyname='business_members_read';
  if v.qual is null or v.qual ilike '%user_id = auth.uid()%' then
    raise exception 'business_members_read must use a scalar subselect for auth.uid()';
  end if;
end $$;
rollback;
