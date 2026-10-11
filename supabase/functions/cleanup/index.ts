// Each night: removes stored files nobody can reach any more (see
// public.files_to_purge), so they stop counting against the plan.

import { rpc, serve, serverHeaders, supabaseUrl } from "../_shared/db.ts";

serve(async (key) => {
  let removed = 0;
  for (let round = 0; round < 20; round++) {
    const rows = await rpc<{ path: string }[]>("files_to_purge", { p_key: key, p_limit: 500 });
    if (!rows.length) break;
    const paths = rows.map((r) => r.path);
    const res = await fetch(supabaseUrl("/storage/v1/object/files"), {
      method: "DELETE",
      headers: serverHeaders(),
      body: JSON.stringify({ prefixes: paths }),
    });
    if (!res.ok) throw new Error(`storage remove failed (${res.status}): ${await res.text()}`);
    await res.body?.cancel();
    await rpc("mark_files_purged", { p_key: key, p_paths: paths });
    removed += paths.length;
    if (rows.length < 500) break;
  }
  return { removed };
});
