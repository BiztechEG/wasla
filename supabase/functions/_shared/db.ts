// Calls the database's functions with the server key. The functions check
// the key from push_config themselves, so a caller without it gets nowhere.

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serverKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

export function serverHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    apikey: serverKey,
    "Content-Type": "application/json",
  };
  // Older keys are JWTs and also go in Authorization; newer secret keys don't.
  if (serverKey.startsWith("eyJ")) headers.Authorization = `Bearer ${serverKey}`;
  return headers;
}

export function supabaseUrl(path: string): string {
  return `${url}${path}`;
}

export class NotAllowed extends Error {}

export async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(supabaseUrl(`/rest/v1/rpc/${name}`), {
    method: "POST",
    headers: serverHeaders(),
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) {
    if (text.includes("not_allowed")) throw new NotAllowed();
    throw new Error(`${name} failed (${res.status}): ${text.slice(0, 300)}`);
  }
  return (text ? JSON.parse(text) : null) as T;
}

// Answers a request: 401 without the right key, 500 on other errors.
export function serve(job: (key: string) => Promise<Record<string, unknown>>) {
  Deno.serve(async (req) => {
    const key = req.headers.get("x-wasla-key");
    if (req.method !== "POST" || !key) return new Response("not allowed", { status: 401 });
    try {
      return Response.json(await job(key));
    } catch (e) {
      if (e instanceof NotAllowed) return new Response("not allowed", { status: 401 });
      console.error(e);
      return new Response("failed", { status: 500 });
    }
  });
}
