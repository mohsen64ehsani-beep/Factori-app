create or replace function public.web_void_document_draft(
  p_business_id uuid,
  p_document_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_doc public.documents%rowtype;
  v_permission text;
  v_user uuid:=auth.uid();
begin
  if v_user is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;

  select * into v_doc
  from public.documents
  where business_id=p_business_id and id=p_document_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Document not found';
  end if;
  if v_doc.status<>'draft' then
    raise exception using errcode='22023',message='Only draft documents can be archived';
  end if;

  v_permission:=case when v_doc.document_type in ('goods_sale','service_sale')
    then 'sales.create' else 'purchases.create' end;
  if not private.has_business_permission(p_business_id,v_permission) then
    raise exception using errcode='42501',message='Document archive permission denied';
  end if;

  update public.documents
  set status='voided',
      notes=concat_ws(E'\n',nullif(btrim(coalesce(notes,'')),''),nullif(btrim(coalesce(p_reason,'')),'')),
      version=version+1
  where business_id=p_business_id and id=p_document_id;
end;
$function$;

revoke all on function public.web_void_document_draft(uuid,uuid,text) from public,anon;
grant execute on function public.web_void_document_draft(uuid,uuid,text) to authenticated;
