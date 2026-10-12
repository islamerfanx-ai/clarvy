// Shared by the Decision Rooms pages (room.html, new.html): words, Supabase, sign-in, weights, file reading.
(() => {
const $ = id => document.getElementById(id);

/* ---------- Words: English and Arabic live in /i18n/*.json ---------- */
let lang = "en", words = {};
const t = (k, vars = {}) => {
  const w = words[k];
  return typeof w === "string" ? w.replace(/\{(\w+)\}/g, (_, v) => vars[v] ?? "") : w ?? k;
};
async function loadLang(l) {
  words = await (await fetch(`/i18n/${l}.json`)).json(); lang = l;
  document.documentElement.lang = l;
  document.documentElement.dir = words.dir;
  document.querySelectorAll("[data-t]").forEach(el => { el.textContent = t(el.dataset.t); });
  document.querySelectorAll("[data-t-ph]").forEach(el => { el.placeholder = t(el.dataset.tPh); });
  const b = $("langBtn");
  if (b) { b.textContent = t("lang_other"); b.setAttribute("aria-label", t("lang_other_label")); }
}
function savedLang() { try { return localStorage.getItem("clarvy-lang"); } catch { return null; } }
function firstLang(hint) { return savedLang() || hint || ((navigator.language || "").startsWith("ar") ? "ar" : "en"); }
// Wire the EN/عربي button. onChange runs after the new words load.
function langToggle(onChange) {
  $("langBtn").addEventListener("click", async () => {
    const next = lang === "ar" ? "en" : "ar";
    await loadLang(next);
    try { localStorage.setItem("clarvy-lang", next); } catch {}
    if (sb && user) sb.from("profiles").update({ language: next }).eq("id", user.id).then(() => {}, () => {});
    onChange && onChange();
  });
}

/* ---------- Supabase ---------- */
let sb = null, user = null;
async function connect() {
  const cfg = await fetch("/api/config").then(r => r.ok ? r.json() : {}).catch(() => ({}));
  if (!cfg.supabase) return false;
  await loadScript("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js");
  sb = window.supabase.createClient(cfg.supabase.url, cfg.supabase.anonKey);
  user = (await sb.auth.getSession()).data.session?.user || null;
  return true;
}
async function profile() {
  if (!user) return null;
  const { data } = await sb.from("profiles").select("name,language").eq("id", user.id).maybeSingle();
  return data;
}
// The sign-in form: an email link that brings you back to this exact page.
function signInForm(form, input, status) {
  form.addEventListener("submit", async e => {
    e.preventDefault();
    const email = input.value.trim(); if (!email) return;
    const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href } });
    status.textContent = t(error ? "err_generic" : "signin_sent");
    status.className = "status " + (error ? "err" : "ok");
  });
}
// Map a database error (raised by our triggers and functions) to a words key.
function errKey(err, known) {
  const msg = String(err?.message || err || "");
  return known.find(k => msg.includes(k)) || "err_generic";
}

/* ---------- Model calls (same /api/ask the main app uses) ---------- */
async function ask(prompt) {
  let code = ""; try { code = localStorage.getItem("clarvy-access-code") || ""; } catch {}
  const r = await fetch("/api/ask", { method: "POST", headers: { "Content-Type": "application/json", "x-access-code": code }, body: JSON.stringify({ prompt }) });
  const data = await r.json().catch(() => null);
  if (!r.ok || !data?.data) throw new Error(data?.code || "upstream");
  return data.data;
}

/* ---------- Weights: whole numbers that always add up to 100 ---------- */
// Spread `total` across keys in proportion to `shares`, rounding so the parts still sum exactly.
function apportion(keys, shares, total) {
  const sum = keys.reduce((s, k) => s + (Number(shares[k]) || 0), 0);
  const raw = keys.map(k => sum > 0 ? (Number(shares[k]) || 0) / sum * total : total / keys.length);
  const out = raw.map(Math.floor);
  let left = total - out.reduce((a, b) => a + b, 0);
  raw.map((r, i) => [r - out[i], i]).sort((a, b) => b[0] - a[0]).forEach(([, i]) => { if (left > 0) { out[i]++; left--; } });
  return Object.fromEntries(keys.map((k, i) => [k, out[i]]));
}
// Set one key to v and rescale the others so the total stays 100.
function rebalance(weights, id, v) {
  const others = Object.keys(weights).filter(k => k !== id);
  if (!others.length) return { [id]: 100 };
  return { ...apportion(others, weights, 100 - v), [id]: v };
}

/* ---------- Small DOM helpers ---------- */
const PALETTE = ["#690DE2", "#8FB2FF", "#C74092", "#FF6A3D", "#2C36CB", "#7C7AA3", "#E8E3FF", "#3FB59B"];
function chip(label, pressed, onClick) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "chip"; b.textContent = label;
  b.setAttribute("aria-pressed", String(pressed));
  b.addEventListener("click", onClick);
  return b;
}
const scripts = {};
function loadScript(src) {
  return scripts[src] || (scripts[src] = new Promise((res, rej) => {
    const s = document.createElement("script"); s.src = src; s.onload = res;
    s.onerror = () => { delete scripts[src]; rej(new Error("load")); };
    document.head.append(s);
  }));
}

/* ---------- Files: read text in the browser (same readers as the main app) ---------- */
const LIB = "https://cdn.jsdelivr.net/npm/";
function fileKind(f) {
  const ext = (f.name.split(".").pop() || "").toLowerCase();
  if (["txt", "md", "csv", "tsv", "json"].includes(ext) || (f.type || "").startsWith("text/")) return "text";
  if (["xlsx", "xls", "ods"].includes(ext)) return "sheet";
  if (ext === "pdf" || f.type === "application/pdf") return "pdf";
  if (ext === "docx") return "docx";
  return null;
}
async function readFile(f) {
  const kind = fileKind(f);
  if (kind === "text") return await f.text();
  if (kind === "sheet") {
    await loadScript(LIB + "xlsx@0.18.5/dist/xlsx.full.min.js");
    const wb = XLSX.read(await f.arrayBuffer(), { type: "array" });
    return wb.SheetNames.map(n => `## Sheet: ${n}\n` + XLSX.utils.sheet_to_csv(wb.Sheets[n], { blankrows: false })).join("\n\n");
  }
  if (kind === "docx") {
    await loadScript(LIB + "mammoth@1.6.0/mammoth.browser.min.js");
    return (await mammoth.extractRawText({ arrayBuffer: await f.arrayBuffer() })).value || "";
  }
  if (kind === "pdf") {
    await loadScript(LIB + "pdfjs-dist@3.11.174/build/pdf.worker.min.js"); // runs in-page, no separate worker
    await loadScript(LIB + "pdfjs-dist@3.11.174/build/pdf.min.js");
    const doc = await window.pdfjsLib.getDocument({ data: new Uint8Array(await f.arrayBuffer()), isEvalSupported: false }).promise;
    const n = Math.min(doc.numPages, 80), parts = [];
    for (let i = 1; i <= n; i++) { const tc = await (await doc.getPage(i)).getTextContent(); parts.push(`[page ${i}] ` + tc.items.map(x => x.str).join(" ").replace(/\s+/g, " ")); }
    if (doc.numPages > n) parts.push(`[only the first ${n} of ${doc.numPages} pages were read]`);
    return parts.join("\n");
  }
  throw new Error("unsupported");
}

window.Rooms = {
  $, t, loadLang, firstLang, savedLang, langToggle, get lang() { return lang; },
  connect, profile, signInForm, errKey, get sb() { return sb; }, get user() { return user; },
  ask, apportion, rebalance, PALETTE, chip, fileKind, readFile
};
})();
