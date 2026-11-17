# Private Storage design

> Design only. No Storage bucket or policy has been created in the production Supabase project.

## Bucket
- ID: `factoori-private`
- Public: `false`
- Allowed content: cheque scans/photos, document attachments and business logos where private delivery is required.
- Store `storage_bucket` and `storage_path` in `file_attachments`; never persist a public URL.
- Path convention: `{business_uuid}/{entity_kind}/{entity_uuid}/{random_file_id}.{ext}`.
- Validate MIME type, extension and size server-side. Do not trust browser-supplied filename or MIME type.

## Authorization
- The first path segment must be a syntactically valid business UUID.
- Every object read/upload must verify active membership in that business.
- Cheque paths require `cheques.read` for download and a cheque-management permission for upload.
- Document attachment paths require document read/create permissions appropriate to the entity type.
- A user must never be able to replace the business UUID in a path to access another tenant.
- Prefer short-lived signed URLs created after a server-side permission check.
- Do not grant public SELECT or anonymous upload.
- Delete/replace operations should be performed by a narrow RPC/Edge Function that also updates `file_attachments` and audit history.

## Operational safeguards
- Limit image dimensions and file sizes; strip EXIF metadata where feasible.
- Use random object names; keep original display name only in `file_attachments.file_name`.
- Record uploader, business, entity type/id, MIME type, size and timestamp.
- Retention/deletion policy for cheque images must be approved before production.
- Test Storage RLS independently from database table RLS; a protected `file_attachments` row does not automatically protect the underlying Storage object.
