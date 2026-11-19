create or replace function public.web_create_due_date(
 p_business_id uuid,p_created_date date,p_due_date date,p_title text,p_person text,
 p_amount numeric,p_due_type text,p_note text default null
)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare v_user uuid:=auth.uid();v_id uuid:=gen_random_uuid();v_payload jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'payments.create') then raise exception using errcode='42501',message='Due-date management is not permitted';end if;
 if p_created_date is null or p_due_date is null or length(btrim(coalesce(p_title,''))) not between 1 and 200
  or length(btrim(coalesce(p_person,'')))>200 or coalesce(p_amount,0)<0
  or coalesce(p_due_type,'') not in ('receivable','payable','cheque')
  or length(btrim(coalesce(p_note,'')))>500 then raise exception using errcode='22023',message='Invalid due-date details';end if;
 insert into public.business_due_dates(id,business_id,created_date,due_date,title,person,amount,due_type,note,legacy_id,created_by)
 values(v_id,p_business_id,p_created_date,p_due_date,btrim(p_title),nullif(btrim(coalesce(p_person,'')),''),coalesce(p_amount,0),p_due_type,nullif(btrim(coalesce(p_note,'')),''),v_id::text,v_user);
 v_payload:=jsonb_strip_nulls(jsonb_build_object('id',v_id::text,'dt',p_created_date,'dueDate',p_due_date,'title',btrim(p_title),'person',nullif(btrim(coalesce(p_person,'')),''),'amount',coalesce(p_amount,0),'kind',p_due_type,'note',nullif(btrim(coalesce(p_note,'')),''),'status','open'));
 perform private.write_legacy_master_record(p_business_id,'duedates',v_id::text,v_payload,false,v_user);
 return v_id;
end;$function$;

create or replace function public.web_set_due_date_status(
 p_business_id uuid,p_due_date_id uuid,p_status text
)
returns boolean language plpgsql security definer set search_path=''
as $function$
declare v_user uuid:=auth.uid();v_due public.business_due_dates%rowtype;v_payload jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'payments.create') then raise exception using errcode='42501',message='Due-date management is not permitted';end if;
 if coalesce(p_status,'') not in ('settled','cancelled') then raise exception using errcode='22023',message='Unsupported due-date status';end if;
 select * into v_due from public.business_due_dates where business_id=p_business_id and id=p_due_date_id for update;
 if not found then raise exception using errcode='P0002',message='Due date not found';end if;
 if v_due.status<>'open' then raise exception using errcode='55000',message='Only open due dates can be settled or cancelled';end if;
 update public.business_due_dates set status=p_status,updated_at=now() where business_id=p_business_id and id=p_due_date_id;
 v_payload:=jsonb_strip_nulls(jsonb_build_object('id',v_due.legacy_id,'dt',v_due.created_date,'dueDate',v_due.due_date,'title',v_due.title,'person',v_due.person,'amount',v_due.amount,'kind',v_due.due_type,'note',v_due.note,'status',p_status));
 perform private.write_legacy_master_record(p_business_id,'duedates',v_due.legacy_id,v_payload,false,v_user);
 return true;
end;$function$;

create or replace function public.web_create_fiscal_period(
 p_business_id uuid,p_title text,p_date_from date,p_date_to date
)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare v_user uuid:=auth.uid();v_id uuid:=gen_random_uuid();v_payload jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then raise exception using errcode='42501',message='Fiscal-period management is not permitted';end if;
 if length(btrim(coalesce(p_title,''))) not between 1 and 100 or p_date_from is null or p_date_to is null or p_date_to<p_date_from then raise exception using errcode='22023',message='Invalid fiscal period dates or title';end if;
 if exists(select 1 from public.fiscal_periods fp where fp.business_id=p_business_id and daterange(fp.date_from,fp.date_to,'[]') && daterange(p_date_from,p_date_to,'[]')) then raise exception using errcode='23P01',message='Fiscal period overlaps an existing period';end if;
 insert into public.fiscal_periods(id,business_id,title,date_from,date_to,status) values(v_id,p_business_id,btrim(p_title),p_date_from,p_date_to,'open');
 v_payload:=jsonb_build_object('id',v_id::text,'title',btrim(p_title),'from',p_date_from,'to',p_date_to,'status','open');
 perform private.write_legacy_master_record(p_business_id,'fiscal',v_id::text,v_payload,false,v_user);
 insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
 values(p_business_id,'fiscal',v_id::text,'fiscal_periods',v_id,encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'),'mapped',gen_random_uuid(),v_user);
 return v_id;
end;$function$;

create or replace function public.web_set_fiscal_period_status(
 p_business_id uuid,p_period_id uuid,p_status text
)
returns boolean language plpgsql security definer set search_path=''
as $function$
declare v_user uuid:=auth.uid();v_period public.fiscal_periods%rowtype;v_payload jsonb;v_legacy_id text;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then raise exception using errcode='42501',message='Fiscal-period management is not permitted';end if;
 if coalesce(p_status,'') not in ('closed','reopened') then raise exception using errcode='22023',message='Unsupported fiscal-period status';end if;
 select * into v_period from public.fiscal_periods where business_id=p_business_id and id=p_period_id for update;
 if not found then raise exception using errcode='P0002',message='Fiscal period not found';end if;
 if p_status='closed' then
  if exists(select 1 from public.documents d where d.business_id=p_business_id and d.document_date between v_period.date_from and v_period.date_to and d.status='draft') then raise exception using errcode='55000',message='Draft documents exist in this fiscal period';end if;
  if exists(select 1 from public.journal_entries j where j.business_id=p_business_id and j.entry_date between v_period.date_from and v_period.date_to and j.status='draft') then raise exception using errcode='55000',message='Draft journal entries exist in this fiscal period';end if;
  update public.fiscal_periods set status='closed',closed_at=now(),closed_by=v_user,updated_at=now() where business_id=p_business_id and id=p_period_id;
 else
  update public.fiscal_periods set status='reopened',closed_at=null,closed_by=null,updated_at=now() where business_id=p_business_id and id=p_period_id and status='closed';
  if not found then raise exception using errcode='55000',message='Only a closed fiscal period can be reopened';end if;
 end if;
 select * into v_period from public.fiscal_periods where business_id=p_business_id and id=p_period_id;
 v_legacy_id:=p_period_id::text;
 v_payload:=jsonb_build_object('id',v_legacy_id,'title',v_period.title,'from',v_period.date_from,'to',v_period.date_to,'status',v_period.status);
 perform private.write_legacy_master_record(p_business_id,'fiscal',v_legacy_id,v_payload,false,v_user);
 update private.legacy_normalized_record_map set source_fingerprint=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'),last_seen_at=now(),last_imported_at=now()
 where business_id=p_business_id and legacy_collection='fiscal' and legacy_id=v_legacy_id and normalized_id=p_period_id;
 return true;
end;$function$;

revoke all on function public.web_set_due_date_status(uuid,uuid,text) from public,anon;
grant execute on function public.web_set_due_date_status(uuid,uuid,text) to authenticated;
revoke all on function public.web_create_due_date(uuid,date,date,text,text,numeric,text,text) from public,anon;
grant execute on function public.web_create_due_date(uuid,date,date,text,text,numeric,text,text) to authenticated;
revoke all on function public.web_create_fiscal_period(uuid,text,date,date) from public,anon;
grant execute on function public.web_create_fiscal_period(uuid,text,date,date) to authenticated;
revoke all on function public.web_set_fiscal_period_status(uuid,uuid,text) from public,anon;
grant execute on function public.web_set_fiscal_period_status(uuid,uuid,text) to authenticated;
