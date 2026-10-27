// POST /functions/v1/cleanup   header: x-cleanup-secret: <CLEANUP_SECRET>   body (optional): {"dry_run":true}
// Deletes files older than CLEANUP_DAYS (default 3) from the storage buckets. Run daily by Supabase Cron.

import { handleCleanup } from '../_shared/cleanup.ts';

Deno.serve((req: Request) => handleCleanup(req, { get: (name) => Deno.env.get(name) }));
