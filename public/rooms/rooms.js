// Shared by the Decision Rooms pages (index, new, room, dashboard): words, Supabase, trial sign-in,
// weights, file reading and small DOM helpers.
(() => {
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

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
  document.querySelectorAll("[data-t]").forEach(e => { e.textContent = t(e.dataset.t); });
  document.querySelectorAll("[data-t-ph]").forEach(e => { e.placeholder = t(e.dataset.tPh); });
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
const fmtDate = d => new Date(d + (String(d).length === 10 ? "T00:00:00" : "")).toLocaleDateString(lang === "ar" ? "ar-u-nu-latn" : "en-GB", { day: "numeric", month: "short", year: "numeric" });

/* ---------- Supabase ---------- */
let sb = null, user = null, emailCodes = false;
async function connect() {
  const cfg = await fetch("/api/config").then(r => r.ok ? r.json() : {}).catch(() => ({}));
  if (!cfg.supabase) return false;
  emailCodes = !!cfg.emailCodes;
  await loadScript("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js");
  sb = window.supabase.createClient(cfg.supabase.url, cfg.supabase.anonKey);
  user = (await sb.auth.getSession()).data.session?.user || null;
  sb.auth.onAuthStateChange((_e, session) => { user = session?.user || null; });
  showMyRooms();
  return true;
}
const isGuest = () => !!user?.is_anonymous;      // joined with just a name
const hasAccount = () => !!user && !user.is_anonymous;
async function profile() {
  if (!user) return null;
  const { data } = await sb.from("profiles").select("name,email,language").eq("id", user.id).maybeSingle();
  return data;
}
async function setName(name) { await sb.from("profiles").update({ name }).eq("id", user.id); }
const validEmail = e => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(e || "").trim());
// Open trial: everyone gives a name and an email (not verified) and gets their own private account
// (Supabase anonymous sign-in). The email is stored on their profile so we can reach them.
async function trialSignIn(name, email) {
  if (!user) {
    const { data, error } = await sb.auth.signInAnonymously();
    if (error) throw error;
    user = data.user;
  }
  const patch = { name };
  if (email) patch.email = String(email).trim();
  const { error } = await sb.from("profiles").update(patch).eq("id", user.id);
  if (error) throw error;
  showMyRooms();
}
function showMyRooms() { const a = $("myRoomsLink"); if (a) a.hidden = !user; }

/* ---------- Email sign-in: a 6-digit code typed here, or the link in the email ---------- */
// Builds the email -> code steps inside `box`. A guest who adds an email keeps their rooms
// (their anonymous account is upgraded); anyone else signs in or signs up. Without codes
// (EMAIL_CODES off), the page waits for the link to be tapped, in any tab of this browser.
function emailCode(box, { onDone }) {
  box.replaceChildren();
  const emailStep = el("form", "stack-sm"), codeStep = el("form", "stack-sm");
  codeStep.hidden = true;
  const eLbl = el("label", "lbl", t("email_lbl")); eLbl.htmlFor = "ecEmail";
  const eIn = el("input", "line"); Object.assign(eIn, { id: "ecEmail", type: "email", autocomplete: "email", required: true, inputMode: "email" });
  const eBtn = el("button", "btn", t(emailCodes ? "email_send" : "email_send_link")); eBtn.type = "submit";
  const cLbl = el("label", "lbl", t("code_lbl")); cLbl.htmlFor = "ecCode";
  const cIn = el("input", "line code"); Object.assign(cIn, { id: "ecCode", inputMode: "numeric", autocomplete: "one-time-code", maxLength: 6, pattern: "[0-9]*" });
  const cHint = el("p", "small");
  const cBtn = el("button", "btn", t("code_verify")); cBtn.type = "submit";
  const again = el("div", "row-acts");
  const resend = el("button", "linkbtn", t(emailCodes ? "code_resend" : "resend_link")); resend.type = "button";
  const change = el("button", "linkbtn", t("email_change")); change.type = "button";
  again.append(resend, change);
  const status = el("p", "status"); status.setAttribute("role", "status");
  emailStep.append(eLbl, eIn, eBtn);
  codeStep.append(cLbl, cIn, cHint, cBtn, again);
  box.append(emailStep, codeStep, status);
  let mode = "email", email = "";
  const say = (msg, kind = "err") => { status.textContent = msg; status.className = "status " + kind; };
  async function send() {
    say("");
    eBtn.disabled = true;
    const res = isGuest()
      ? await sb.auth.updateUser({ email }, { emailRedirectTo: location.href })
      : await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href } });
    mode = isGuest() ? "email_change" : "email";
    eBtn.disabled = false;
    if (res.error) return say(t(/rate|seconds/i.test(res.error.message) ? "email_wait" : "err_generic"));
    emailStep.hidden = true; codeStep.hidden = false;
    cLbl.hidden = cIn.hidden = cBtn.hidden = !emailCodes;
    cHint.textContent = t(emailCodes ? "code_hint" : "link_hint", { email });
    if (emailCodes) { cIn.value = ""; cIn.focus(); }
    else waitForLink();
  }
  // The link signs this browser in (Supabase shares the session across tabs), so carry on when it lands.
  let watching = null;
  function waitForLink() {
    if (watching) return;
    watching = sb.auth.onAuthStateChange((ev, session) => {
      const u = session?.user;
      if (!u || (ev !== "SIGNED_IN" && ev !== "USER_UPDATED")) return;
      if (u.is_anonymous && u.email == null) return; // still the guest; wait for the email confirmation
      watching.data.subscription.unsubscribe();
      user = u; showMyRooms();
      onDone && onDone(email);
    });
  }
  emailStep.addEventListener("submit", e => { e.preventDefault(); email = eIn.value.trim(); if (email) send(); });
  resend.addEventListener("click", send);
  change.addEventListener("click", () => { codeStep.hidden = true; emailStep.hidden = false; say(""); eIn.focus(); });
  codeStep.addEventListener("submit", async e => {
    e.preventDefault();
    const token = cIn.value.replace(/\D/g, "");
    if (token.length !== 6) return say(t("code_wrong"));
    cBtn.disabled = true;
    const { data, error } = await sb.auth.verifyOtp({ email, token, type: mode });
    cBtn.disabled = false;
    if (error) return say(t("code_wrong"));
    user = data.user || (await sb.auth.getUser()).data.user;
    showMyRooms();
    onDone && onDone(email);
  });
  setTimeout(() => eIn.focus(), 50);
}

/* ---------- Server calls ---------- */
const accessCode = () => { try { return localStorage.getItem("clarvy-access-code") || ""; } catch { return ""; } };
async function ask(prompt) {
  const r = await fetch("/api/ask", { method: "POST", headers: { "Content-Type": "application/json", "x-access-code": accessCode() }, body: JSON.stringify({ prompt }) });
  const data = await r.json().catch(() => null);
  if (!r.ok || !data?.data) throw new Error(data?.code || "upstream");
  return data.data;
}
// Owner's "Decide now": the server reads everyone's private input and writes back the combined result.
async function decideNow(roomId) {
  const token = (await sb.auth.getSession()).data.session?.access_token;
  const r = await fetch("/api/rooms/decide", { method: "POST", headers: { "Content-Type": "application/json", "x-access-code": accessCode(), Authorization: "Bearer " + token }, body: JSON.stringify({ room_id: roomId }) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(data.code || "upstream"), data);
  return data;
}
// Map an error (from our database functions or the server) to a words key.
function errKey(err, known) {
  const msg = String(err?.message || err || "");
  return known.find(k => msg.includes(k)) || "err_generic";
}

/* ---------- Weights ---------- */
// Spread `total` across keys in proportion to `shares`, rounding so the parts still sum exactly.
// (Same as apportion() in rooms/math.js, which the server uses.)
function apportion(keys, shares, total = 100) {
  const sum = keys.reduce((s, k) => s + (Number(shares[k]) || 0), 0);
  const raw = keys.map(k => sum > 0 ? (Number(shares[k]) || 0) / sum * total : total / keys.length);
  const out = raw.map(Math.floor);
  let left = total - out.reduce((a, b) => a + b, 0);
  raw.map((r, i) => [r - out[i], i]).sort((a, b) => b[0] - a[0]).forEach(([, i]) => { if (left > 0) { out[i]++; left--; } });
  return Object.fromEntries(keys.map((k, i) => [k, out[i]]));
}

/* ---------- Small DOM helpers ---------- */
function chip(label, pressed, onClick) {
  const b = el("button", "chip", label);
  b.type = "button";
  b.setAttribute("aria-pressed", String(pressed));
  b.addEventListener("click", onClick);
  return b;
}
// A big tappable choice: title plus an optional one-line description.
function choice(title, hint, pressed, onClick) {
  const b = el("button", "choice");
  b.type = "button";
  b.setAttribute("aria-pressed", String(pressed));
  b.append(el("span", "choice-t", title));
  if (hint) b.append(el("span", "choice-h", hint));
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
// Share links that open the person's own apps; we send nothing ourselves.
function shareLinks(msg, subject) {
  return {
    whatsapp: "https://wa.me/?text=" + encodeURIComponent(msg),
    email: `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(msg)}`
  };
}
// "By continuing you accept our Terms · Privacy" under the forms that collect a name and email.
function agreeNote() {
  const p = el("p", "small agree");
  const a1 = el("a", null, t("lp_terms")); a1.href = "/terms.html"; a1.target = "_blank";
  const a2 = el("a", null, t("lp_privacy")); a2.href = "/privacy.html"; a2.target = "_blank";
  p.append(t("agree_lead") + " ", a1, " · ", a2);
  return p;
}
async function copyText(text) {
  try { await navigator.clipboard.writeText(text); return true; }
  catch { const ta = el("textarea"); ta.value = text; document.body.append(ta); ta.select(); document.execCommand("copy"); ta.remove(); return true; }
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
  $, el, t, loadLang, firstLang, savedLang, langToggle, fmtDate, get lang() { return lang; },
  connect, profile, setName, trialSignIn, validEmail, isGuest, hasAccount, emailCode, showMyRooms,
  get sb() { return sb; }, get user() { return user; }, get emailCodes() { return emailCodes; },
  ask, decideNow, errKey, apportion, chip, choice, shareLinks, copyText, agreeNote, fileKind, readFile
};
})();
