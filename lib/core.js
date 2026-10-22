// Shared server logic for Clarvy. The OpenAI key stays here, on the server, and never reaches the browser.
const OPENAI_URL = (process.env.OPENAI_BASE_URL || "https://api.openai.com/v1") + "/responses";
const MODEL = process.env.OPENAI_MODEL || "gpt-5.5";
const SEARCH_MODEL = process.env.OPENAI_SEARCH_MODEL || MODEL;
const REASONING = process.env.OPENAI_REASONING || ""; // optional: "low" | "medium" | "high"

const MAX_PROMPT_CHARS = 120000;
const MAX_IMAGES = 4;
const MAX_IMAGE_CHARS = 3_000_000; // a data URL; the page shrinks images before upload

// ---- simple per-IP rate limit (per server instance) ----
const hits = new Map();
const LIMIT = Number(process.env.RATE_LIMIT_PER_10_MIN || 80);
function rateOk(ip) {
  const now = Date.now(), win = 10 * 60 * 1000;
  const list = (hits.get(ip) || []).filter(t => now - t < win);
  if (list.length >= LIMIT) { hits.set(ip, list); return false; }
  list.push(now); hits.set(ip, list);
  if (hits.size > 5000) for (const [k, v] of hits) if (!v.length || now - v[v.length - 1] > win) hits.delete(k);
  return true;
}

// The caller's address. The first X-Forwarded-For entry is whatever the caller sent, so trust only what
// our own proxy adds: X-Real-IP, or else the last X-Forwarded-For entry (appended by nginx).
export function clientIp(req) {
  const real = String(req.headers["x-real-ip"] || "").trim();
  if (real) return real;
  const fwd = String(req.headers["x-forwarded-for"] || "").split(",").map(s => s.trim()).filter(Boolean);
  return fwd[fwd.length - 1] || req.socket?.remoteAddress || "?";
}

// The open prompt routes (/api/ask, /api/search) belonged to the solo Clarvy page. They let anyone run any
// prompt on our key, so they are off unless SOLO_ENABLED=1 (for local work on clarvy.html).
const soloOff = () => process.env.SOLO_ENABLED !== "1" ? { status: 410, body: { code: "retired" } } : null;

export function guard(req) {
  if (req.method !== "POST") return { status: 405, body: { code: "method" } };
  if (!process.env.OPENAI_API_KEY) return { status: 500, body: { code: "not_configured" } };
  const code = process.env.ACCESS_CODE;
  if (code && (req.headers["x-access-code"] || "") !== code) return { status: 401, body: { code: "access_code" } };
  if (!rateOk(clientIp(req))) return { status: 429, body: { code: "rate_limited" } };
  return null;
}

// Cost log: one line per AI call ("usage {...}" in the server log), so we can see what a room really costs.
// Prices are per million tokens and per web search, from env, defaulting to gpt-5.5 list prices (an estimate).
const PRICE = { in: Number(process.env.PRICE_IN) || 5, cached: Number(process.env.PRICE_CACHED) || 0.5, out: Number(process.env.PRICE_OUT) || 30, search: Number(process.env.PRICE_SEARCH) || 0.025 };
function logUsage(body, data, tag = {}) {
  const u = data?.usage || {}, cached = u.input_tokens_details?.cached_tokens || 0;
  const searches = (data?.output || []).filter(o => o.type === "web_search_call").length;
  const cost = ((u.input_tokens || 0) - cached) / 1e6 * PRICE.in + cached / 1e6 * PRICE.cached + (u.output_tokens || 0) / 1e6 * PRICE.out + searches * PRICE.search;
  console.log("usage " + JSON.stringify({ kind: tag.kind || "other", room: tag.room || null, model: body.model, effort: body.reasoning?.effort || "default",
    in: u.input_tokens || 0, cached, out: u.output_tokens || 0, reasoning: u.output_tokens_details?.reasoning_tokens || 0, searches, cost: Math.round(cost * 10000) / 10000 }));
}
async function callOpenAI(body, tag) {
  if (REASONING && !body.reasoning) body.reasoning = { effort: REASONING };
  const r = await fetch(OPENAI_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
    body: JSON.stringify(body),
  });
  const data = await r.json().catch(() => null);
  if (!r.ok) {
    const err = new Error((data && data.error && data.error.message) || `OpenAI ${r.status}`);
    err.status = r.status;
    throw err;
  }
  try { logUsage(body, data, tag); } catch {}
  return data;
}

function outputText(data) {
  if (typeof data?.output_text === "string") return data.output_text;
  return (data?.output || [])
    .filter(o => o.type === "message")
    .flatMap(o => o.content || [])
    .filter(c => c.type === "output_text")
    .map(c => c.text)
    .join("");
}
function citations(data) {
  return (data?.output || [])
    .filter(o => o.type === "message")
    .flatMap(o => o.content || [])
    .flatMap(c => c.annotations || [])
    .filter(a => a.type === "url_citation" && a.url)
    .map(a => ({ title: a.title || "", url: a.url }));
}
function parseJSON(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch {}
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  if (a >= 0 && b > a) { try { return JSON.parse(text.slice(a, b + 1)); } catch {} }
  return null;
}
function upstreamError(e) {
  if (e.status === 429) return { status: 429, body: { code: "rate_limited" } };
  if (e.status === 400 && /context|too long|maximum/i.test(e.message)) return { status: 413, body: { code: "prompt_too_large" } };
  console.error("OpenAI error:", e.status, e.message);
  return { status: 502, body: { code: "upstream" } };
}

// POST /api/ask  {prompt, json, images[]}  ->  {data} or {text}
export async function ask(req) {
  const g = soloOff() || guard(req); if (g) return g;
  const { prompt, json = true, images = [] } = req.body || {};
  if (typeof prompt !== "string" || !prompt.trim()) return { status: 400, body: { code: "bad_request" } };
  if (prompt.length > MAX_PROMPT_CHARS) return { status: 413, body: { code: "prompt_too_large" } };
  const imgs = (Array.isArray(images) ? images : []).slice(0, MAX_IMAGES)
    .filter(u => typeof u === "string" && /^data:image\/(png|jpe?g|webp|gif);base64,/.test(u) && u.length <= MAX_IMAGE_CHARS);
  const content = [{ type: "input_text", text: prompt }, ...imgs.map(u => ({ type: "input_image", image_url: u }))];
  const body = { model: MODEL, input: [{ role: "user", content }] };
  if (json) body.text = { format: { type: "json_object" } };
  try {
    let data;
    try { data = await callOpenAI(body); }
    catch (e) { // some models reject json mode; retry once without it
      if (json && e.status === 400 && /format|json/i.test(e.message)) { delete body.text; data = await callOpenAI(body); }
      else throw e;
    }
    const text = outputText(data);
    if (!json) return { status: 200, body: { text } };
    const parsed = parseJSON(text);
    if (parsed === null) return { status: 502, body: { code: "invalid_json" } };
    return { status: 200, body: { data: parsed } };
  } catch (e) { return upstreamError(e); }
}

// POST /api/search  {objective, search_queries[]}  ->  {results:[{title,url,publish_date,excerpts[]}]}
export async function search(req) {
  const g = soloOff() || guard(req); if (g) return g;
  const { objective = "", search_queries = [] } = req.body || {};
  const qs = (Array.isArray(search_queries) ? search_queries : []).slice(0, 3).map(q => String(q).slice(0, 100));
  if (!String(objective).trim() && !qs.length) return { status: 400, body: { code: "bad_request" } };
  const today = new Date().toISOString().slice(0, 10);
  const prompt = `Today is ${today}. Search the web to help with this objective: ${String(objective).slice(0, 400)}
Useful queries: ${qs.join(" | ")}
Find up to 10 recent, relevant, reputable sources. Prefer official sources and established outlets, and the last few months.
Reply with only JSON:
{"results":[{"title":"page title","url":"https://...","publish_date":"YYYY-MM-DD or null","excerpts":["a short passage from the page that carries the key fact, with exact figures"]}]}`;
  try {
    const data = await callOpenAI({ model: SEARCH_MODEL, tools: [{ type: "web_search" }], input: prompt });
    const parsed = parseJSON(outputText(data));
    let results = Array.isArray(parsed?.results) ? parsed.results : [];
    // keep only links the search actually cited, when citations are available
    const cited = citations(data);
    if (cited.length) {
      const urls = new Set(cited.map(c => c.url.split("#")[0]));
      const kept = results.filter(r => r && urls.has(String(r.url || "").split("#")[0]));
      if (kept.length) results = kept;
    }
    results = results.filter(r => r && /^https?:\/\//.test(r.url)).slice(0, 10).map(r => ({
      title: String(r.title || "").slice(0, 200),
      url: String(r.url),
      publish_date: r.publish_date || null,
      excerpts: (Array.isArray(r.excerpts) ? r.excerpts : [r.excerpts]).filter(Boolean).map(x => String(x).slice(0, 600)).slice(0, 3),
    }));
    return { status: 200, body: { results } };
  } catch (e) { return upstreamError(e); }
}

// One model call that returns parsed JSON, for server-side pipelines (Decision Rooms).
// With search, the model may use web search and the sources it cited come back as `cited`.
// fast: small setup jobs (grammar, drafts, suggestions) think briefly so the owner isn't kept waiting;
// the analysis itself keeps the default depth.
export async function modelJSON(prompt, { search = false, fast = false, kind = "other", room = null } = {}) {
  const body = search
    ? { model: SEARCH_MODEL, tools: [{ type: "web_search" }], input: prompt }
    : { model: MODEL, input: prompt, text: { format: { type: "json_object" } } };
  if (fast) body.reasoning = { effort: process.env.OPENAI_FAST_REASONING || "low" };
  let data;
  try { data = await callOpenAI(body, { kind, room }); }
  catch (e) {
    if (!search && e.status === 400 && /format|json/i.test(e.message)) { delete body.text; data = await callOpenAI(body, { kind, room }); }
    else throw e;
  }
  const parsed = parseJSON(outputText(data));
  if (parsed === null) throw Object.assign(new Error("invalid_json"), { code: "invalid_json" });
  return { data: parsed, cited: citations(data) };
}

// Speech to text for a spoken question. The audio goes to OpenAI and is not kept by us.
const TRANSCRIBE_MODEL = process.env.OPENAI_TRANSCRIBE_MODEL || "gpt-4o-mini-transcribe";
export async function transcribe(buffer, mime, { lang = "", prompt = "" } = {}) {
  const ext = /mp4|m4a|aac/.test(mime) ? "m4a" : /ogg/.test(mime) ? "ogg" : /wav/.test(mime) ? "wav" : "webm";
  const form = new FormData();
  form.append("file", new Blob([buffer], { type: mime }), "question." + ext);
  form.append("model", TRANSCRIBE_MODEL);
  if (lang) form.append("language", lang);
  if (prompt) form.append("prompt", prompt);
  const r = await fetch((process.env.OPENAI_BASE_URL || "https://api.openai.com/v1") + "/audio/transcriptions", {
    method: "POST", headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}` }, body: form
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(data?.error?.message || "transcribe_failed"), { status: r.status });
  console.log("usage " + JSON.stringify({ kind: "voice", model: TRANSCRIBE_MODEL, bytes: buffer.length, in: data.usage?.input_tokens || 0, out: data.usage?.output_tokens || 0 }));
  return String(data.text || "").trim();
}

// GET /api/config  ->  public settings for Decision Rooms. The Supabase anon key is meant for browsers;
// row-level security in supabase/migrations decides what each signed-in person can read.
export async function config() {
  const url = process.env.SUPABASE_URL || "", anonKey = process.env.SUPABASE_ANON_KEY || "";
  // EMAIL_CODES=1 once the Supabase email templates include {{ .Token }} (needs custom SMTP);
  // until then sign-in emails carry only a link.
  // The Turnstile site key is public; its secret lives in Supabase (Auth > Attack Protection), which checks
  // the token on every sign-up.
  const turnstile = process.env.TURNSTILE_SITE_KEY || "0x4AAAAAAFfCA2QbR05aPSGE";
  return { status: 200, body: { supabase: url && anonKey ? { url, anonKey } : null, emailCodes: process.env.EMAIL_CODES === "1", turnstile } };
}
