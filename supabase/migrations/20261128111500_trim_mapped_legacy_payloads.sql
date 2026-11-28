begin;
do $migration$
declare v_def text; v_old text; v_new text;
begin
 v_def:=pg_get_functiondef('public.web_list_legacy_collections(uuid,text[])'::regprocedure);
 v_old:=E'    ''payload'',case when v_cost_allowed then private.merge_sensitive_json(r.payload_public,r.payload_private) else r.payload_public end,';
 v_new:=E'    ''payload'',case when m.import_status=''mapped'' then ''{}''::jsonb when v_cost_allowed then private.merge_sensitive_json(r.payload_public,r.payload_private) else r.payload_public end,';
 if position(v_old in v_def)=0 then raise exception 'Legacy payload projection anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);
 execute v_def;
end;
$migration$;
commit;