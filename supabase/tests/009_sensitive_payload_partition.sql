-- Behavioral tests for recursive sensitive-field partitioning used by offline sync.
begin;
do $$
declare
  v_payload jsonb := '{
    "id":"invoice-7",
    "total":1500,
    "b":900,
    "profitAmount":600,
    "items":[
      {"n":"Widget","q":2,"p":750,"b":450,"unitCost":450},
      {"n":"Cable","q":1,"p":0,"b":0}
    ],
    "meta":{"sell":1500,"averageCost":300,"nested":[{"margin":12,"label":"x"}]}
  }'::jsonb;
  v_public jsonb;
  v_private jsonb;
  v_merged jsonb;
begin
  v_public:=private.strip_sensitive_json(v_payload);
  v_private:=private.extract_sensitive_json(v_payload);
  if v_public ? 'b' or v_public ? 'profitAmount'
    or (v_public->'items'->0) ? 'b'
    or (v_public->'items'->0) ? 'unitCost'
    or (v_public->'meta') ? 'averageCost'
    or ((v_public->'meta'->'nested'->0) ? 'margin') then
    raise exception 'Sensitive cost/profit fields leaked into public sync payload: %',v_public;
  end if;
  if v_public->>'id'<>'invoice-7' or v_public->'items'->0->>'n'<>'Widget'
    or v_public->'items'->0->>'p'<>'750' then
    raise exception 'Public sync payload lost ordinary invoice fields: %',v_public;
  end if;
  if v_private->>'b'<>'900' or v_private->>'profitAmount'<>'600'
    or v_private->'items'->0->>'b'<>'450'
    or v_private->'items'->0->>'unitCost'<>'450'
    or v_private->'meta'->>'averageCost'<>'300'
    or v_private->'meta'->'nested'->0->>'margin'<>'12' then
    raise exception 'Private sync payload did not retain all sensitive fields: %',v_private;
  end if;
  v_merged:=private.merge_sensitive_json(v_public,v_private);
  if v_merged is distinct from v_payload then
    raise exception 'Public/private sync payload round-trip mismatch. Expected %, got %',v_payload,v_merged;
  end if;
end $$;
rollback;
