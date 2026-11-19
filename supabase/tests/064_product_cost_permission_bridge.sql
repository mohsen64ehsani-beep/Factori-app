-- Static security assertions for permission-aware product costs.
do $test$
declare v_bridge text; v_category_fn text;
begin
 if not has_column_privilege('authenticated','public.products','cost_price','SELECT') then
  -- Expected: cost_price must remain hidden from direct REST table reads.
  null;
 else
  raise exception 'cost_price must not be directly selectable by authenticated users';
 end if;
 if not has_column_privilege('authenticated','public.products','name','SELECT') then
  raise exception 'product name must remain selectable';
 end if;
 if has_function_privilege('anon','public.web_list_products(uuid)','EXECUTE') then
  raise exception 'anonymous users must not execute web_list_products';
 end if;
 if not has_function_privilege('authenticated','public.web_list_products(uuid)','EXECUTE') then
  raise exception 'authenticated users must execute web_list_products';
 end if;
 if has_function_privilege('anon','public.web_create_product_category(uuid,text,uuid)','EXECUTE') then
  raise exception 'anonymous users must not create product categories';
 end if;
 select pg_get_functiondef('private.bridge_legacy_master_to_normalized()'::regprocedure) into v_bridge;
 if position('new.collection=''categories''' in v_bridge)=0 then raise exception 'Android categories must be adopted into normalized product categories'; end if;
 select pg_get_functiondef('public.web_create_product_category(uuid,text,uuid)'::regprocedure) into v_category_fn;
 if position('write_legacy_master_record' in v_category_fn)=0 then raise exception 'Web categories must be published to the Android sync stream'; end if;
end $test$;
