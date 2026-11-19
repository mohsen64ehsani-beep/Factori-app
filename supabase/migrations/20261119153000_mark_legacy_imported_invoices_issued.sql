-- Historical invoices imported from the Android legacy store represent already-issued invoices.
-- Mark them as issued in the normalized document list without replaying stock or ledger postings.
-- New web-created drafts (web-* idempotency keys) are deliberately excluded.
update public.documents d
set status = 'posted',
    posted_at = coalesce(d.posted_at, d.created_at),
    version = d.version + 1,
    updated_at = now()
where d.business_id = '84c13f82-888d-4c8a-b9a9-655ca218dc86'::uuid
  and d.status = 'draft'
  and (d.idempotency_key like 'legacy-inv:%' or d.idempotency_key like 'legacy-service-inv:%')
  and exists (
    select 1 from private.legacy_normalized_record_map m
    where m.business_id = d.business_id
      and m.normalized_id = d.id
      and m.target_table = 'documents'
      and m.import_status = 'mapped'
  )
  and not exists (
    select 1 from public.document_postings p
    where p.business_id = d.business_id and p.document_id = d.id
  );
