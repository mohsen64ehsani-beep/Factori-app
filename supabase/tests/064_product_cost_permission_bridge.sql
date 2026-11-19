-- Static security assertions for permission-aware product costs.
do $$
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
end $$;
