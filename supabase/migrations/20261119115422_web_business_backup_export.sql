create or replace function public.web_export_business_backup(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_user uuid:=auth.uid();
 v_business jsonb;
 v_products jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then
  raise exception using errcode='42501',message='Business backup export is not permitted';
 end if;
 select jsonb_build_object('id',b.id,'name',b.name,'status',b.status,'created_at',b.created_at)
 into v_business from public.businesses b where b.id=p_business_id and b.status='active';
 if v_business is null then raise exception using errcode='42501',message='Business is unavailable';end if;
 select coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) into v_products
 from public.web_list_products(p_business_id) p;
 return jsonb_build_object(
  'format','factoori-business-backup','schema_version',1,'exported_at',now(),'business',v_business,
  'data',jsonb_build_object(
   'contacts',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.contacts x where x.business_id=p_business_id),
   'products',v_products,
   'product_categories',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.product_categories x where x.business_id=p_business_id),
   'services',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.services x where x.business_id=p_business_id),
   'documents',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.documents x where x.business_id=p_business_id),
   'document_items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.document_items x where x.business_id=p_business_id),
   'financial_accounts',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.financial_accounts x where x.business_id=p_business_id),
   'financial_account_ledger_map',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.financial_account_ledger_map x where x.business_id=p_business_id),
   'financial_transactions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.financial_transactions x where x.business_id=p_business_id),
   'cheques',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.cheques x where x.business_id=p_business_id),
   'cheque_events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.cheque_events x where x.business_id=p_business_id),
   'warehouses',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.warehouses x where x.business_id=p_business_id),
   'stock_movements',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.stock_movements x where x.business_id=p_business_id),
   'sales_return_documents',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.sales_return_documents x where x.business_id=p_business_id),
   'sales_return_items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.sales_return_items x where x.business_id=p_business_id),
   'purchase_return_documents',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.purchase_return_documents x where x.business_id=p_business_id),
   'purchase_return_items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.purchase_return_items x where x.business_id=p_business_id),
   'business_due_dates',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.business_due_dates x where x.business_id=p_business_id),
   'fiscal_periods',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.fiscal_periods x where x.business_id=p_business_id),
   'business_settings',(select to_jsonb(x) from public.business_settings x where x.business_id=p_business_id),
   'journal_entries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.journal_entries x where x.business_id=p_business_id),
   'legacy_public_records',(select coalesce(jsonb_agg(jsonb_build_object('collection',x.collection,'legacy_id',x.legacy_id,'payload_public',x.payload_public,'revision',x.revision,'updated_at',x.updated_at,'deleted_at',x.deleted_at)),'[]'::jsonb) from private.business_state_records x where x.business_id=p_business_id)
  )
 );
end;$function$;
revoke all on function public.web_export_business_backup(uuid) from public,anon;
grant execute on function public.web_export_business_backup(uuid) to authenticated;
