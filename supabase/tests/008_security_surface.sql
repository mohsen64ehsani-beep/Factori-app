-- Cross-migration security-surface checks for the disposable PostgreSQL CI database.
begin;
do $$
declare
  v_table record;
  v_function record;
begin
  for v_table in
    select c.oid, n.nspname, c.relname, c.relrowsecurity
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p')
  loop
    if not v_table.relrowsecurity then
      raise exception 'RLS is disabled on public.%',v_table.relname;
    end if;
    if has_table_privilege('anon',v_table.oid,'SELECT')
      or has_table_privilege('anon',v_table.oid,'INSERT')
      or has_table_privilege('anon',v_table.oid,'UPDATE')
      or has_table_privilege('anon',v_table.oid,'DELETE') then
      raise exception 'anon has direct table privileges on public.%',v_table.relname;
    end if;
  end loop;

  for v_function in
    select p.oid::regprocedure as signature, p.proconfig
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','private') and p.prosecdef
  loop
    if not coalesce(v_function.proconfig::text,'') ilike '%search_path=%' then
      raise exception 'SECURITY DEFINER function lacks fixed search_path: %',v_function.signature;
    end if;
  end loop;

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.prosecdef
      and has_function_privilege('anon',p.oid,'EXECUTE')
  ) then
    raise exception 'anon can execute a private SECURITY DEFINER function';
  end if;
end $$;
rollback;
