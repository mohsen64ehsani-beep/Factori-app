-- 006: Enforce immutable posted journals and balanced double-entry integrity.
-- DEVELOPMENT DRAFT ONLY. Depends on migrations 001-003.
begin;

create unique index if not exists journal_entries_one_reversal_per_source
 on public.journal_entries(business_id,reverses_entry_id)
 where reverses_entry_id is not null;

create or replace function private.guard_journal_entry_update()
returns trigger
language plpgsql
set search_path=''
as $$
begin
 if tg_op='DELETE' then
  if old.status in ('posted','reversed') then
   raise exception using errcode='55000',message='Posted journal entries are immutable; create a reversal instead';
  end if;
  return old;
 end if;
 if old.status in ('posted','reversed') then
  raise exception using errcode='55000',message='Posted journal entries are immutable; create a reversal instead';
 end if;
 if new.status='reversed' then
  raise exception using errcode='55000',message='Use the controlled reversal workflow';
 end if;
 return new;
end;
$$;

create or replace function private.guard_journal_line_mutation()
returns trigger
language plpgsql
set search_path=''
as $$
declare v_status text;
begin
 if tg_op in ('UPDATE','DELETE') then
  select status into v_status from public.journal_entries
  where business_id=old.business_id and id=old.journal_entry_id for update;
  if v_status in ('posted','reversed') then
   raise exception using errcode='55000',message='Lines of a posted journal entry are immutable';
  end if;
 end if;

 if tg_op in ('INSERT','UPDATE') then
  select status into v_status from public.journal_entries
  where business_id=new.business_id and id=new.journal_entry_id for update;
  if v_status in ('posted','reversed') then
   raise exception using errcode='55000',message='Lines of a posted journal entry are immutable';
  end if;
 end if;

 if tg_op='DELETE' then return old; end if;
 return new;
end;
$$;

create or replace function private.assert_journal_entry_balanced()
returns trigger
language plpgsql
set search_path=''
as $$
declare
 v_business uuid;
 v_entry uuid;
 v_status text;
 v_debit numeric(30,0);
 v_credit numeric(30,0);
 v_count integer;
 v_period_status text;
 v_period_id uuid;
begin
 if tg_table_name='journal_entries' then
  v_business:=coalesce(new.business_id,old.business_id);
  v_entry:=coalesce(new.id,old.id);
 else
  v_business:=coalesce(new.business_id,old.business_id);
  v_entry:=coalesce(new.journal_entry_id,old.journal_entry_id);
 end if;

 select status,fiscal_period_id into v_status,v_period_id
 from public.journal_entries
 where business_id=v_business and id=v_entry;
 if not found or v_status<>'posted' then return null; end if;

 select coalesce(sum(l.debit),0),coalesce(sum(l.credit),0),count(*)
 into v_debit,v_credit,v_count
 from public.journal_lines l
 where l.business_id=v_business and l.journal_entry_id=v_entry;

 if v_count<2 or v_debit<=0 or v_debit<>v_credit then
  raise exception using errcode='23514',message='Posted journal entry must contain at least two balanced lines';
 end if;

 if exists(
  select 1 from public.journal_lines l
  join public.chart_of_accounts a
   on a.business_id=l.business_id and a.id=l.account_id
  where l.business_id=v_business and l.journal_entry_id=v_entry
    and (not a.is_active or not a.allow_posting)
 ) then
  raise exception using errcode='23514',message='Journal entry contains an inactive or non-posting account';
 end if;

 select fp.status into v_period_status
 from public.journal_entries je
 left join public.fiscal_periods fp
  on fp.business_id=je.business_id and fp.id=je.fiscal_period_id
 where je.business_id=v_business and je.id=v_entry;

 if exists(
  select 1 from public.journal_entries je
  where je.business_id=v_business and je.id=v_entry
    and je.fiscal_period_id is not null
    and coalesce(v_period_status,'missing')<>'open'
 ) then
  raise exception using errcode='23514',message='Journal entry fiscal period is not open';
 end if;
 return null;
end;
$$;

drop trigger if exists journal_entries_immutable_guard on public.journal_entries;
create trigger journal_entries_immutable_guard
before update or delete on public.journal_entries
for each row execute function private.guard_journal_entry_update();

drop trigger if exists journal_lines_immutable_guard on public.journal_lines;
create trigger journal_lines_immutable_guard
before insert or update or delete on public.journal_lines
for each row execute function private.guard_journal_line_mutation();

drop trigger if exists journal_entries_balance_check on public.journal_entries;
create constraint trigger journal_entries_balance_check
after insert or update on public.journal_entries
deferrable initially deferred
for each row execute function private.assert_journal_entry_balanced();

drop trigger if exists journal_lines_balance_check on public.journal_lines;
create constraint trigger journal_lines_balance_check
after insert or update or delete on public.journal_lines
deferrable initially deferred
for each row execute function private.assert_journal_entry_balanced();

revoke all on function private.guard_journal_entry_update() from public,anon,authenticated;
revoke all on function private.guard_journal_line_mutation() from public,anon,authenticated;
revoke all on function private.assert_journal_entry_balanced() from public,anon,authenticated;

commit;
