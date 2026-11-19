create or replace function public.web_create_financial_account(
  p_business_id uuid,p_name text,p_account_type text,p_note text default null
)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare
 v_user uuid:=auth.uid();v_legacy_id text:=gen_random_uuid()::text;v_account_id uuid;
 v_chart_account_id uuid;v_chart_code text;v_is_default boolean;v_payload jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then raise exception using errcode='42501',message='Financial account management is not permitted';end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 120 or coalesce(p_account_type,'') not in ('cash','bank') or length(btrim(coalesce(p_note,'')))>500 then
  raise exception using errcode='22023',message='Invalid financial account details';
 end if;
 v_chart_code:=case p_account_type when 'cash' then '1000' else '1010' end;
 select ca.id into v_chart_account_id from public.chart_of_accounts ca
 where ca.business_id=p_business_id and ca.code=v_chart_code and ca.account_class='asset' and ca.is_active and ca.allow_posting limit 1;
 if v_chart_account_id is null then raise exception using errcode='55000',message='Default ledger account for this financial account type is not configured';end if;
 select not exists(select 1 from public.financial_accounts fa where fa.business_id=p_business_id and fa.is_active) into v_is_default;
 insert into public.financial_accounts(business_id,name,account_type,currency_code,is_active,is_default,opening_balance,legacy_id,created_by)
 values(p_business_id,btrim(p_name),p_account_type,'IRR',true,v_is_default,0,v_legacy_id,v_user) returning id into v_account_id;
 insert into public.financial_account_ledger_map(business_id,financial_account_id,chart_account_id,created_by) values(p_business_id,v_account_id,v_chart_account_id,v_user);
 v_payload:=jsonb_strip_nulls(jsonb_build_object('id',v_legacy_id,'name',btrim(p_name),'type',p_account_type,'note',nullif(btrim(coalesce(p_note,'')),'')));
 perform private.write_legacy_master_record(p_business_id,'accounts',v_legacy_id,v_payload,false,v_user);
 insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
 values(p_business_id,'accounts',v_legacy_id,'financial_accounts',v_account_id,encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'),'mapped',gen_random_uuid(),v_user);
 return v_account_id;
end;$function$;

create or replace function public.web_import_legacy_financial_accounts(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
 v_user uuid:=auth.uid();v_row record;v_name text;v_type text;v_chart_code text;v_chart_id uuid;
 v_account_id uuid;v_is_default boolean;v_fingerprint text;v_map private.legacy_normalized_record_map%rowtype;
 v_imported integer:=0;v_unchanged integer:=0;v_conflicts integer:=0;v_invalid integer:=0;v_matches integer;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then raise exception using errcode='42501',message='Financial account import is not permitted';end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then raise exception using errcode='42501',message='Business is unavailable';end if;
 for v_row in select r.legacy_id,r.payload_public from private.business_state_records r where r.business_id=p_business_id and r.collection='accounts' and r.deleted_at is null order by r.legacy_id loop
  if jsonb_typeof(v_row.payload_public)<>'object' or coalesce(v_row.payload_public->>'id','')<>v_row.legacy_id then v_invalid:=v_invalid+1;continue;end if;
  v_name:=nullif(btrim(v_row.payload_public->>'name'),'');v_type:=nullif(btrim(v_row.payload_public->>'type'),'');
  if v_name is null or length(v_name)>120 or coalesce(v_type,'') not in ('cash','bank') then v_invalid:=v_invalid+1;continue;end if;
  v_chart_code:=case v_type when 'cash' then '1000' else '1010' end;
  select ca.id into v_chart_id from public.chart_of_accounts ca where ca.business_id=p_business_id and ca.code=v_chart_code and ca.account_class='asset' and ca.is_active and ca.allow_posting limit 1;
  if v_chart_id is null then v_invalid:=v_invalid+1;continue;end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_row.payload_public::text,'UTF8'),'sha256'),'hex');
  select * into v_map from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.legacy_collection='accounts' and m.legacy_id=v_row.legacy_id for update;
  if found then
   if v_map.import_status='mapped' and v_map.source_fingerprint=v_fingerprint and exists(select 1 from public.financial_accounts fa where fa.business_id=p_business_id and fa.id=v_map.normalized_id and fa.name=v_name and fa.account_type=v_type) then
    update private.legacy_normalized_record_map set last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_unchanged:=v_unchanged+1;
   else
    update private.legacy_normalized_record_map set import_status='conflict',note_code='source_or_target_changed',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_conflicts:=v_conflicts+1;
   end if;continue;
  end if;
  select fa.id into v_account_id from public.financial_accounts fa where fa.business_id=p_business_id and fa.legacy_id=v_row.legacy_id;
  if v_account_id is null then
   select count(*),min(fa.id) into v_matches,v_account_id from public.financial_accounts fa
   where fa.business_id=p_business_id and fa.name=v_name and fa.account_type=v_type and fa.legacy_id is null;
   if v_matches>1 then v_conflicts:=v_conflicts+1;continue;end if;
   if v_matches=1 then
    update public.financial_accounts set legacy_id=v_row.legacy_id,updated_at=now(),version=version+1 where business_id=p_business_id and id=v_account_id;
   else
    select not exists(select 1 from public.financial_accounts fa where fa.business_id=p_business_id and fa.is_active) into v_is_default;
    insert into public.financial_accounts(business_id,name,account_type,currency_code,is_active,is_default,opening_balance,legacy_id,created_by)
    values(p_business_id,v_name,v_type,'IRR',true,v_is_default,0,v_row.legacy_id,v_user) returning id into v_account_id;
    insert into public.financial_account_ledger_map(business_id,financial_account_id,chart_account_id,created_by) values(p_business_id,v_account_id,v_chart_id,v_user);
   end if;
  elsif not exists(select 1 from public.financial_accounts fa where fa.business_id=p_business_id and fa.id=v_account_id and fa.name=v_name and fa.account_type=v_type) then
   v_conflicts:=v_conflicts+1;continue;
  end if;
  insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
  values(p_business_id,'accounts',v_row.legacy_id,'financial_accounts',v_account_id,v_fingerprint,'mapped',gen_random_uuid(),v_user);
  v_imported:=v_imported+1;
 end loop;
 return jsonb_build_object('business_id',p_business_id,'imported',v_imported,'unchanged',v_unchanged,'conflicts',v_conflicts,'invalid',v_invalid,'opening_balances_imported',false);
end;$function$;

revoke all on function public.web_create_financial_account(uuid,text,text,text) from public,anon;
grant execute on function public.web_create_financial_account(uuid,text,text,text) to authenticated;
revoke all on function public.web_import_legacy_financial_accounts(uuid) from public,anon;
grant execute on function public.web_import_legacy_financial_accounts(uuid) to authenticated;
