-- 064: Refresh PostgREST's function cache after sync proof RPCs were deployed.
-- This keeps client-side schema health checks from disabling the shared sync flow.
notify pgrst, 'reload schema';
