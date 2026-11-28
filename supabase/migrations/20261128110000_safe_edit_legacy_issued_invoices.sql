begin;

do $migration$
declare
 v_def text;
 v_old text;
 v_new text;
begin
 v_def:=pg_get_functiondef('public.web_update_document_draft(uuid,uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text)'::regprocedure);

 v_old:='  v_header_discount numeric:=coalesce(p_discount_amount,0);';
 v_new:=v_old||E'\n  v_was_legacy_posted boolean:=false;\n  v_legacy_collection text;\n  v_legacy_id text;';
 if position(v_old in v_def)=0 then raise exception 'Update function declaration anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:=E'  if v_existing_document.status<>''draft'' then\n    raise exception using errcode=''22023'',message=''Only draft documents can be edited'';\n  end if;';
 v_new:=E'  if v_existing_document.status=''posted'' then\n    v_was_legacy_posted:=true;\n    if v_existing_document.idempotency_key not like ''legacy-inv:%'' and v_existing_document.idempotency_key not like ''legacy-service-inv:%'' and v_existing_document.idempotency_key not like ''web-edit-legacy:%'' then\n      raise exception using errcode=''22023'',message=''Issued document requires a formal accounting correction'';\n    end if;\n    if not exists(select 1 from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.normalized_id=p_document_id and m.target_table=''documents'' and m.import_status=''mapped'' and m.legacy_collection in (''inv'',''serviceInv''))\n      or exists(select 1 from public.document_postings p where p.business_id=p_business_id and p.document_id=p_document_id)\n      or exists(select 1 from public.stock_movements sm where sm.business_id=p_business_id and sm.document_id=p_document_id)\n      or exists(select 1 from public.financial_transactions ft where ft.business_id=p_business_id and ft.document_id=p_document_id) then\n      raise exception using errcode=''22023'',message=''Issued document has accounting effects and must be corrected through a reversal document'';\n    end if;\n  elsif v_existing_document.status<>''draft'' then\n    raise exception using errcode=''22023'',message=''Only draft or safely imported issued documents can be edited'';\n  end if;';
 if position(v_old in v_def)=0 then raise exception 'Update status guard anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:='  v_doc_id:=p_document_id;';
 v_new:=v_old||E'\n  if v_was_legacy_posted then\n    update public.documents set idempotency_key=''web-edit-legacy:''||p_document_id::text where business_id=p_business_id and id=p_document_id;\n  end if;';
 if position(v_old in v_def)=0 then raise exception 'Update document id anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:='  where id=v_doc_id and business_id=p_business_id and status=''draft'';';
 v_new:='  where id=v_doc_id and business_id=p_business_id and status in (''draft'',''posted'');';
 if position(v_old in v_def)=0 then raise exception 'Update target status anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:='  return v_doc_id;';
 v_new:=E'  if v_was_legacy_posted then\n    select m.legacy_collection,m.legacy_id into v_legacy_collection,v_legacy_id\n    from private.legacy_normalized_record_map m\n    where m.business_id=p_business_id and m.normalized_id=v_doc_id and m.target_table=''documents'' and m.import_status=''mapped''\n    for update;\n    perform private.publish_document_to_legacy(p_business_id,v_doc_id,v_user);\n    if v_legacy_id is not null and v_legacy_id<>v_doc_id::text then\n      perform private.write_legacy_master_record(p_business_id,v_legacy_collection,v_legacy_id,''{}''::jsonb,true,v_user);\n    end if;\n    update private.legacy_normalized_record_map m\n    set legacy_id=v_doc_id::text,\n        source_fingerprint=encode(extensions.digest(convert_to(r.payload_public::text,''UTF8''),''sha256''),''hex''),\n        import_generation=gen_random_uuid(),last_seen_at=now()\n    from private.business_state_records r\n    where m.business_id=p_business_id and m.normalized_id=v_doc_id and m.target_table=''documents''\n      and r.business_id=m.business_id and r.collection=v_legacy_collection and r.legacy_id=v_doc_id::text;\n  end if;\n  return v_doc_id;';
 if position(v_old in v_def)=0 then raise exception 'Update return anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);
 execute v_def;

 v_def:=pg_get_functiondef('public.web_void_document_draft(uuid,uuid,text)'::regprocedure);
 v_old:=E'  v_user uuid:=auth.uid();';
 v_new:=v_old||E'\n  v_was_legacy_posted boolean:=false;\n  v_legacy_collection text;\n  v_legacy_id text;';
 if position(v_old in v_def)=0 then raise exception 'Void declaration anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:=E'  if v_doc.status<>''draft'' then\n    raise exception using errcode=''22023'',message=''Only draft documents can be archived'';\n  end if;';
 v_new:=E'  if v_doc.status=''posted'' then\n    v_was_legacy_posted:=true;\n    if v_doc.idempotency_key not like ''legacy-inv:%'' and v_doc.idempotency_key not like ''legacy-service-inv:%'' and v_doc.idempotency_key not like ''web-edit-legacy:%'' then\n      raise exception using errcode=''22023'',message=''Issued document requires a formal accounting correction'';\n    end if;\n    if not exists(select 1 from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.normalized_id=p_document_id and m.target_table=''documents'' and m.import_status=''mapped'' and m.legacy_collection in (''inv'',''serviceInv''))\n      or exists(select 1 from public.document_postings p where p.business_id=p_business_id and p.document_id=p_document_id)\n      or exists(select 1 from public.stock_movements sm where sm.business_id=p_business_id and sm.document_id=p_document_id)\n      or exists(select 1 from public.financial_transactions ft where ft.business_id=p_business_id and ft.document_id=p_document_id) then\n      raise exception using errcode=''22023'',message=''Issued document has accounting effects and cannot be deleted safely'';\n    end if;\n  elsif v_doc.status<>''draft'' then\n    raise exception using errcode=''22023'',message=''Only draft or safely imported issued documents can be archived'';\n  end if;';
 if position(v_old in v_def)=0 then raise exception 'Void status guard anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:=E'  update public.documents\n  set status=''voided'',';
 v_new:=E'  update public.documents\n  set idempotency_key=case when v_was_legacy_posted then ''web-edit-legacy:''||p_document_id::text else idempotency_key end,\n      status=''voided'',';
 if position(v_old in v_def)=0 then raise exception 'Void update anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);

 v_old:=E'  where business_id=p_business_id and id=p_document_id;\nend;';
 v_new:=E'  where business_id=p_business_id and id=p_document_id;\n  if v_doc.document_type in (''goods_sale'',''service_sale'') then\n    perform private.publish_document_to_legacy(p_business_id,p_document_id,v_user);\n  end if;\n  if v_was_legacy_posted then\n    select m.legacy_collection,m.legacy_id into v_legacy_collection,v_legacy_id\n    from private.legacy_normalized_record_map m\n    where m.business_id=p_business_id and m.normalized_id=p_document_id and m.target_table=''documents'' and m.import_status=''mapped''\n    for update;\n    if v_legacy_id is not null and v_legacy_id<>p_document_id::text then\n      perform private.write_legacy_master_record(p_business_id,v_legacy_collection,v_legacy_id,''{}''::jsonb,true,v_user);\n    end if;\n    update private.legacy_normalized_record_map m\n    set legacy_id=p_document_id::text,\n        source_fingerprint=encode(extensions.digest(convert_to(r.payload_public::text,''UTF8''),''sha256''),''hex''),\n        import_generation=gen_random_uuid(),last_seen_at=now()\n    from private.business_state_records r\n    where m.business_id=p_business_id and m.normalized_id=p_document_id and m.target_table=''documents''\n      and r.business_id=m.business_id and r.collection=v_legacy_collection and r.legacy_id=p_document_id::text;\n  end if;\nend;';
 if position(v_old in v_def)=0 then raise exception 'Void return anchor not found'; end if;
 v_def:=replace(v_def,v_old,v_new);
 execute v_def;
end;
$migration$;

commit;