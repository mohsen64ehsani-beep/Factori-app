create or replace function public.web_update_contact(
  p_business_id uuid,
  p_contact_id uuid,
  p_name text,
  p_phone text default null,
  p_code text default null,
  p_address text default null,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid:=auth.uid();
  v_contact public.contacts%rowtype;
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if length(btrim(coalesce(p_name,''))) not between 2 and 160 then
    raise exception using errcode='22023',message='Invalid contact name';
  end if;
  if not private.has_business_permission(p_business_id,'contacts.write') then
    raise exception using errcode='42501',message='Contact write permission denied';
  end if;

  select * into v_contact
  from public.contacts
  where business_id=p_business_id and id=p_contact_id
  for update;
  if not found or not v_contact.is_active then
    raise exception using errcode='P0002',message='Active contact not found';
  end if;

  update public.contacts
  set name=btrim(p_name),
      phone=nullif(btrim(coalesce(p_phone,'')),''),
      code=nullif(btrim(coalesce(p_code,'')),''),
      address=nullif(btrim(coalesce(p_address,'')),''),
      notes=nullif(left(btrim(coalesce(p_notes,'')),2000),''),
      version=version+1
  where business_id=p_business_id and id=p_contact_id;

  if v_contact.legacy_id is not null then
    if v_contact.contact_type in ('customer','both') then
      perform private.write_legacy_master_record(
        p_business_id,'cust',v_contact.legacy_id,
        jsonb_strip_nulls(jsonb_build_object(
          'id',v_contact.legacy_id,'n',btrim(p_name),
          'ph',nullif(btrim(coalesce(p_phone,'')),''),
          'ad',nullif(btrim(coalesce(p_address,'')),''),
          'code',nullif(btrim(coalesce(p_code,'')),'')
        )),false,v_user
      );
    end if;
    if v_contact.contact_type in ('supplier','both') then
      perform private.write_legacy_master_record(
        p_business_id,'suppliers',v_contact.legacy_id,
        jsonb_strip_nulls(jsonb_build_object(
          'id',v_contact.legacy_id,'name',btrim(p_name),
          'phone',nullif(btrim(coalesce(p_phone,'')),''),
          'address',nullif(btrim(coalesce(p_address,'')),''),
          'code',nullif(btrim(coalesce(p_code,'')),'')
        )),false,v_user
      );
    end if;
  end if;
end;
$function$;

create or replace function public.web_set_contact_active(
  p_business_id uuid,
  p_contact_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid:=auth.uid();
  v_contact public.contacts%rowtype;
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if not private.has_business_permission(p_business_id,'contacts.write') then
    raise exception using errcode='42501',message='Contact write permission denied';
  end if;
  select * into v_contact from public.contacts
  where business_id=p_business_id and id=p_contact_id for update;
  if not found then raise exception using errcode='P0002',message='Contact not found'; end if;
  if v_contact.is_active is distinct from coalesce(p_is_active,false) then
    update public.contacts set is_active=coalesce(p_is_active,false),version=version+1
    where business_id=p_business_id and id=p_contact_id;
    if v_contact.legacy_id is not null then
      if coalesce(p_is_active,false) then
        if v_contact.contact_type in ('customer','both') then
          perform private.write_legacy_master_record(
            p_business_id,'cust',v_contact.legacy_id,
            jsonb_strip_nulls(jsonb_build_object(
              'id',v_contact.legacy_id,'n',v_contact.name,'ph',v_contact.phone,
              'ad',v_contact.address,'code',v_contact.code
            )),false,v_user
          );
        end if;
        if v_contact.contact_type in ('supplier','both') then
          perform private.write_legacy_master_record(
            p_business_id,'suppliers',v_contact.legacy_id,
            jsonb_strip_nulls(jsonb_build_object(
              'id',v_contact.legacy_id,'name',v_contact.name,'phone',v_contact.phone,
              'address',v_contact.address,'code',v_contact.code
            )),false,v_user
          );
        end if;
      else
        if v_contact.contact_type in ('customer','both') then
          perform private.write_legacy_master_record(p_business_id,'cust',v_contact.legacy_id,'{}'::jsonb,true,v_user);
        end if;
        if v_contact.contact_type in ('supplier','both') then
          perform private.write_legacy_master_record(p_business_id,'suppliers',v_contact.legacy_id,'{}'::jsonb,true,v_user);
        end if;
      end if;
    end if;
  end if;
end;
$function$;

create or replace function public.web_update_product(
  p_business_id uuid,
  p_product_id uuid,
  p_name text,
  p_sku text default null,
  p_unit_name text default 'عدد',
  p_sale_price numeric default 0,
  p_track_inventory boolean default true,
  p_minimum_stock numeric default 0,
  p_barcode text default null,
  p_cost_price numeric default null,
  p_category_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid:=auth.uid();
  v_product public.products%rowtype;
  v_category text;
  v_cost numeric;
  v_cost_allowed boolean;
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if length(btrim(coalesce(p_name,''))) not between 2 and 160
     or coalesce(p_sale_price,0)<0 or coalesce(p_minimum_stock,0)<0
     or (p_cost_price is not null and p_cost_price<0) then
    raise exception using errcode='22023',message='Invalid product details';
  end if;
  if not private.has_business_permission(p_business_id,'catalog.write') then
    raise exception using errcode='42501',message='Catalog write permission denied';
  end if;
  v_cost_allowed:=private.has_business_permission(p_business_id,'catalog.cost.read');
  if p_cost_price is not null and not v_cost_allowed then
    raise exception using errcode='42501',message='Product cost permission denied';
  end if;

  select * into v_product from public.products
  where business_id=p_business_id and id=p_product_id for update;
  if not found or not v_product.is_active then
    raise exception using errcode='P0002',message='Active product not found';
  end if;

  if p_category_id is not null then
    select name into v_category from public.product_categories
    where id=p_category_id and business_id=p_business_id;
    if v_category is null then raise exception using errcode='22023',message='Invalid product category'; end if;
  end if;

  v_cost:=case when v_cost_allowed then coalesce(p_cost_price,v_product.cost_price) else v_product.cost_price end;

  if v_product.legacy_id is not null then
    perform private.write_legacy_master_record(
      p_business_id,'prod',v_product.legacy_id,
      jsonb_strip_nulls(jsonb_build_object(
        'id',v_product.legacy_id,'n',btrim(p_name),
        'sku',nullif(btrim(coalesce(p_sku,'')),''),
        'barcode',nullif(btrim(coalesce(p_barcode,'')),''),
        'sell',coalesce(p_sale_price,0),'buy',v_cost,
        'category',v_category,'minQty',coalesce(p_minimum_stock,0),
        'unit',coalesce(nullif(btrim(coalesce(p_unit_name,'')),''),'عدد'),
        'track_inventory',coalesce(p_track_inventory,true)
      )),false,v_user
    );
  end if;

  update public.products
  set name=btrim(p_name),
      sku=nullif(btrim(coalesce(p_sku,'')),''),
      barcode=nullif(btrim(coalesce(p_barcode,'')),''),
      unit_name=coalesce(nullif(btrim(coalesce(p_unit_name,'')),''),'عدد'),
      sale_price=coalesce(p_sale_price,0),
      track_inventory=coalesce(p_track_inventory,true),
      minimum_stock=coalesce(p_minimum_stock,0),
      category_id=p_category_id,
      cost_price=v_cost,
      version=version+1
  where business_id=p_business_id and id=p_product_id;
end;
$function$;

create or replace function public.web_set_product_active(
  p_business_id uuid,
  p_product_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid:=auth.uid();
  v_product public.products%rowtype;
  v_category text;
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if not private.has_business_permission(p_business_id,'catalog.write') then
    raise exception using errcode='42501',message='Catalog write permission denied';
  end if;
  select * into v_product from public.products
  where business_id=p_business_id and id=p_product_id for update;
  if not found then raise exception using errcode='P0002',message='Product not found'; end if;

  if v_product.is_active is distinct from coalesce(p_is_active,false) then
    update public.products set is_active=coalesce(p_is_active,false),version=version+1
    where business_id=p_business_id and id=p_product_id;
    if v_product.legacy_id is not null then
      if coalesce(p_is_active,false) then
        select name into v_category from public.product_categories
        where id=v_product.category_id and business_id=p_business_id;
        perform private.write_legacy_master_record(
          p_business_id,'prod',v_product.legacy_id,
          jsonb_strip_nulls(jsonb_build_object(
            'id',v_product.legacy_id,'n',v_product.name,'sku',v_product.sku,
            'barcode',v_product.barcode,'sell',v_product.sale_price,'buy',v_product.cost_price,
            'category',v_category,'minQty',v_product.minimum_stock,
            'unit',v_product.unit_name,'track_inventory',v_product.track_inventory
          )),false,v_user
        );
      else
        perform private.write_legacy_master_record(p_business_id,'prod',v_product.legacy_id,'{}'::jsonb,true,v_user);
      end if;
    end if;
  end if;
end;
$function$;

revoke all on function public.web_update_contact(uuid,uuid,text,text,text,text,text) from public,anon;
revoke all on function public.web_set_contact_active(uuid,uuid,boolean) from public,anon;
revoke all on function public.web_update_product(uuid,uuid,text,text,text,numeric,boolean,numeric,text,numeric,uuid) from public,anon;
revoke all on function public.web_set_product_active(uuid,uuid,boolean) from public,anon;
grant execute on function public.web_update_contact(uuid,uuid,text,text,text,text,text) to authenticated;
grant execute on function public.web_set_contact_active(uuid,uuid,boolean) to authenticated;
grant execute on function public.web_update_product(uuid,uuid,text,text,text,numeric,boolean,numeric,text,numeric,uuid) to authenticated;
grant execute on function public.web_set_product_active(uuid,uuid,boolean) to authenticated;
