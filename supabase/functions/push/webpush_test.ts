import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  b64url,
  type Bytes,
  encrypt,
  newVapidKeys,
  readSubscription,
  unb64url,
  vapidHeader,
  webPayload,
} from "./webpush.ts";

const text = (s: string) => new TextEncoder().encode(s);

async function hmac(key: Bytes, data: Bytes) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

async function hkdf(salt: Bytes, ikm: Bytes, info: Bytes, n: number) {
  return (await hmac(await hmac(salt, ikm), new Uint8Array([...info, 1]))).slice(0, n);
}

// A browser: its key pair and auth secret, as a subscription.
async function browser() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const auth = crypto.getRandomValues(new Uint8Array(16));
  return {
    pair,
    pub,
    auth,
    sub: {
      endpoint: "https://push.example.com/send/abc",
      keys: { p256dh: b64url(pub), auth: b64url(auth) },
    },
  };
}

// Decrypts as the browser does (RFC 8291).
async function decrypt(b: Awaited<ReturnType<typeof browser>>, body: Bytes) {
  const salt = body.slice(0, 16);
  const rs = new DataView(body.buffer, body.byteOffset).getUint32(16);
  const idlen = body[20];
  const asPub = body.slice(21, 21 + idlen);
  const sealed = body.slice(21 + idlen);
  assertEquals(rs, 4096);
  const theirs = await crypto.subtle.importKey(
    "raw",
    asPub,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: theirs }, b.pair.privateKey, 256),
  );
  const ikm = await hkdf(
    b.auth,
    shared,
    new Uint8Array([...text("WebPush: info\0"), ...b.pub, ...asPub]),
    32,
  );
  const cek = await hkdf(salt, ikm, text("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, text("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]);
  const plain = new Uint8Array(
    await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, key, sealed),
  );
  assertEquals(plain[plain.length - 1], 2, "the last record's delimiter");
  return new TextDecoder().decode(plain.slice(0, -1));
}

Deno.test("a notification is encrypted so only that browser can read it", async () => {
  const b = await browser();
  const payload = webPayload(
    { title: "Bridge", body: "Sami: صب الخرسانة 7", tag: "chat-c", data: { type: "chat" } },
    "ar",
  );
  const body = await encrypt(b.sub, payload);
  const shown = JSON.parse(await decrypt(b, body));
  assertEquals(shown, {
    title: "Bridge",
    body: "Sami: صب الخرسانة 7",
    tag: "chat-c",
    data: { type: "chat" },
    locale: "ar",
  });

  const other = await browser();
  let failed = false;
  try {
    await decrypt(other, body);
  } catch {
    failed = true;
  }
  assert(failed, "another browser cannot read it");
});

Deno.test("requests are signed for the push service with the public key", async () => {
  const keys = await newVapidKeys();
  assertEquals(unb64url(keys.publicKey).length, 65);
  const header = await vapidHeader(
    keys,
    "https://fcm.googleapis.com/fcm/send/x",
    "https://wasla.example",
    1000,
  );
  const [, jwt, k] = header.match(/^vapid t=([^,]+), k=(.+)$/)!;
  assertEquals(k, keys.publicKey);
  const [h, c, s] = jwt.split(".");
  assertEquals(JSON.parse(new TextDecoder().decode(unb64url(c))), {
    aud: "https://fcm.googleapis.com",
    exp: 1000 + 12 * 3600,
    sub: "https://wasla.example",
  });
  const pub = await crypto.subtle.importKey(
    "raw",
    unb64url(keys.publicKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pub,
      unb64url(s),
      text(`${h}.${c}`),
    ),
    "the signature checks out with the public key",
  );
});

Deno.test("only a browser's own subscription is sent to", () => {
  const good = '{"endpoint":"https://push.example.com/a","keys":{"p256dh":"BK","auth":"au"}}';
  assertEquals(readSubscription(good)?.endpoint, "https://push.example.com/a");
  assertEquals(readSubscription("fcm-token"), null);
  assertEquals(
    readSubscription('{"endpoint":"http://insecure/a","keys":{"p256dh":"x","auth":"y"}}'),
    null,
  );
  assertEquals(readSubscription('{"endpoint":"https://push.example.com/a"}'), null);
});

Deno.test("the encryption matches RFC 8291's own example", async () => {
  const asPublic = unb64url(
    "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
  );
  const jwk = {
    kty: "EC",
    crv: "P-256",
    x: b64url(asPublic.slice(1, 33)),
    y: b64url(asPublic.slice(33, 65)),
  };
  const local = {
    publicKey: await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "ECDH", namedCurve: "P-256" },
      true,
      [],
    ),
    privateKey: await crypto.subtle.importKey(
      "jwk",
      { ...jwk, d: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw" },
      { name: "ECDH", namedCurve: "P-256" },
      true,
      ["deriveBits"],
    ),
  };
  const body = await encrypt(
    {
      endpoint: "https://push.example.net/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV",
      keys: {
        p256dh:
          "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
        auth: "BTBZMqHH6r4Tts7J_aSIgg",
      },
    },
    text("When I grow up, I want to be a watermelon"),
    { salt: unb64url("DGv6ra1nlYgDCS1FRnbzlw"), local },
  );
  assertEquals(
    b64url(body),
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
  );
});
