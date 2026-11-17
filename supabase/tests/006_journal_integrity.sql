-- Disposable tests for 006. Requires migrations 001-003 and test fixtures.
begin;
do $$
begin
 if not exists(select 1 from pg_trigger where tgname='journal_entries_immutable_guard' and not tgisinternal) then
  raise exception 'Journal immutability trigger missing';
 end if;
 if not exists(select 1 from pg_trigger where tgname='journal_entries_immutable_guard' and not tgisinternal and (tgtype & 8)=8) then
  raise exception 'Journal immutability trigger must also block DELETE';
 end if;
 if not exists(select 1 from pg_trigger where tgname='journal_lines_immutable_guard' and not tgisinternal) then
  raise exception 'Journal line immutability trigger missing';
 end if;
 if not exists(select 1 from pg_trigger where tgname='journal_entries_balance_check' and not tgisinternal) then
  raise exception 'Deferred header balance trigger missing';
 end if;
 if not exists(select 1 from pg_trigger where tgname='journal_lines_balance_check' and not tgisinternal) then
  raise exception 'Deferred line balance trigger missing';
 end if;
 if not exists(select 1 from pg_indexes where schemaname='public' and indexname='journal_entries_one_reversal_per_source') then
  raise exception 'Unique reversal index missing';
 end if;
end $$;
rollback;
