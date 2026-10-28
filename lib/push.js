// Web Push with no extra packages: VAPID sign-in (RFC 8292) and aes128gcm payload encryption (RFC 8291).
// The VAPID key pair comes from VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY, or is made once and kept in
// ~/.clarvy-vapid.json (outside the deployed folder, so a deploy never replaces it). Changing the key pair
// would cut off every phone that already allowed notifications, so the file is never rewritten.
import crypto from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const b64u = buf => Buffer.from(buf).toString("base64url");
const unb64u = s => Buffer.from(String(s), "base64url");

let keys = null;
function vapid() {
  if (keys) return keys;
  let pub = process.env.VAPID_PUBLIC_KEY, priv = process.env.VAPID_PRIVATE_KEY;
  if (!pub || !priv) {
    const file = process.env.VAPID_FILE || join(homedir(), ".clarvy-vapid.json");
    try { ({ publicKey: pub, privateKey: priv } = JSON.parse(readFileSync(file, "utf8"))); }
    catch {
      const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
      const jwk = privateKey.export({ format: "jwk" });
      pub = b64u(Buffer.concat([Buffer.from([4]), unb64u(jwk.x), unb64u(jwk.y)]));
      priv = jwk.d;
      try { writeFileSync(file, JSON.stringify({ publicKey: pub, privateKey: priv }), { mode: 0o600, flag: "wx" }); }
      catch { try { ({ publicKey: pub, privateKey: priv } = JSON.parse(readFileSync(file, "utf8"))); } catch (e) { console.error("push keys:", e.message); return null; } }
    }
  }
  const raw = unb64u(pub);
  const key = crypto.createPrivateKey({ key: { kty: "EC", crv: "P-256", d: priv, x: b64u(raw.subarray(1, 33)), y: b64u(raw.subarray(33, 65)) }, format: "jwk" });
  keys = { pub, key };
  return keys;
}
export const vapidPublicKey = () => vapid()?.pub || null;

function jwt(aud) {
  const subject = process.env.VAPID_SUBJECT || process.env.PUBLIC_URL || "https://clarvy.tejarra.com";
  const head = b64u(JSON.stringify({ typ: "JWT", alg: "ES256" }));
  const body = b64u(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject }));
  const sig = crypto.sign("sha256", Buffer.from(`${head}.${body}`), { key: vapid().key, dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${b64u(sig)}`;
}

function encrypt(payload, p256dh, authSecret) {
  const uaPublic = unb64u(p256dh), auth = unb64u(authSecret);
  const ecdh = crypto.createECDH("prime256v1");
  const asPublic = ecdh.generateKeys();
  const shared = ecdh.computeSecret(uaPublic);
  const salt = crypto.randomBytes(16);
  const ikm = Buffer.from(crypto.hkdfSync("sha256", shared, auth, Buffer.concat([Buffer.from("WebPush: info\0"), uaPublic, asPublic]), 32));
  const cek = Buffer.from(crypto.hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: aes128gcm\0"), 16));
  const nonce = Buffer.from(crypto.hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: nonce\0"), 12));
  const cipher = crypto.createCipheriv("aes-128-gcm", cek, nonce);
  const body = Buffer.concat([cipher.update(Buffer.concat([Buffer.from(payload), Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const rs = Buffer.alloc(4); rs.writeUInt32BE(4096);
  return Buffer.concat([salt, rs, Buffer.from([asPublic.length]), asPublic, body]);
}

// Send one notification to one device. Returns "ok", "gone" (the device unsubscribed: remove it) or "failed".
export async function sendPush(sub, message, { topic, ttl = 86400 } = {}) {
  if (!vapid()) return "failed";
  try {
    const aud = new URL(sub.endpoint).origin;
    const r = await fetch(sub.endpoint, {
      method: "POST",
      headers: {
        Authorization: `vapid t=${jwt(aud)}, k=${vapid().pub}`,
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        TTL: String(ttl),
        Urgency: "normal",
        ...(topic ? { Topic: String(topic).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 32) } : {})
      },
      body: encrypt(JSON.stringify(message), sub.p256dh, sub.auth),
      signal: AbortSignal.timeout(10000)
    });
    if (r.status === 404 || r.status === 410) return "gone";
    if (!r.ok) { console.error("push send:", r.status, (await r.text()).slice(0, 160)); return "failed"; }
    return "ok";
  } catch (e) { console.error("push send:", e.message); return "failed"; }
}
