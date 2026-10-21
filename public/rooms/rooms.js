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
// A room's category as people see it: the custom name for custom rooms.
const typeName = r => r?.type === "custom" && r.type_label ? r.type_label : t("type_" + (r?.type || "business"));
const fmtDate = d => new Date(d + (String(d).length === 10 ? "T00:00:00" : "")).toLocaleDateString(lang === "ar" ? "ar-u-nu-latn" : "en-GB", { day: "numeric", month: "short", year: "numeric" });

/* ---------- Supabase ---------- */
let sb = null, user = null, emailCodes = false;
async function connect() {
  const cfg = await fetch("/api/config").then(r => r.ok ? r.json() : {}).catch(() => ({}));
  if (!cfg.supabase) return false;
  emailCodes = !!cfg.emailCodes;
  turnstileKey = cfg.turnstile || "";
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
// Bot check (Cloudflare Turnstile): a fresh token for each sign-up. The widget stays hidden unless
// Cloudflare needs the person to tick a box; then it shows at the bottom of the screen.
let turnstileKey = "";
async function captchaToken() {
  if (!turnstileKey) return undefined;
  // If the script can't load (a blocker), go on without a token: Supabase decides whether that's allowed.
  try { await loadScript("https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"); } catch { return undefined; }
  let box = document.getElementById("dr-captcha");
  if (!box) { box = el("div"); box.id = "dr-captcha"; document.body.append(box); }
  box.replaceChildren();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Object.assign(new Error("captcha"), { code: "captcha" })), 60000);
    window.turnstile.render(box, {
      sitekey: turnstileKey, appearance: "interaction-only", language: lang === "ar" ? "ar" : "en",
      // Shown only when Cloudflare needs a tick: say so, since the box sits away from the button pressed.
      "before-interactive-callback": () => { box.classList.add("ask"); box.prepend(el("p", "captcha-note", t("captcha_tick"))); },
      callback: token => { clearTimeout(timer); box.classList.remove("ask"); box.replaceChildren(); resolve(token); },
      "error-callback": () => { clearTimeout(timer); reject(Object.assign(new Error("captcha"), { code: "captcha" })); }
    });
  });
}
let signingIn = null;   // a sign-up in progress, so a second call waits for it instead of making another account
async function trialSignIn(name, email) {
  if (!user && signingIn) await signingIn.catch(() => {});
  if (!user) signingIn = (async () => {
    // When many people join at once (a whole office on one network), sign-in can be briefly rate limited:
    // wait and try again a few times before telling the person.
    let data, error;
    for (const wait of [0, 1500, 4000, 9000]) {
      if (wait) await new Promise(r => setTimeout(r, wait));
      ({ data, error } = await sb.auth.signInAnonymously({ options: { captchaToken: await captchaToken() } }));
      if (!error || error.status !== 429) break;
    }
    if (error) throw error.status === 429 ? Object.assign(new Error("busy"), { code: "busy" }) : error;
    user = data.user;
  })();
  if (signingIn) { try { await signingIn; } finally { signingIn = null; } }
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
      : await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href, captchaToken: await captchaToken() } });
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
// AI routes need the signed-in person's token; the server counts each call against their daily limit.
async function post(path, body) {
  const token = sb ? (await sb.auth.getSession()).data.session?.access_token : "";
  const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "x-access-code": accessCode(), ...(token ? { Authorization: "Bearer " + token } : {}) }, body: JSON.stringify(body) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(data.code || "upstream"), data);
  return data;
}
// Owner's "Decide now": the server reads everyone's private input and writes back the combined result.
async function decideNow(roomId) {
  const token = (await sb.auth.getSession()).data.session?.access_token;
  const r = await fetch("/api/rooms/decide", { method: "POST", headers: { "Content-Type": "application/json", "x-access-code": accessCode(), Authorization: "Bearer " + token }, body: JSON.stringify({ room_id: roomId }) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(data.code || "upstream"), data);
  return data;
}
// The call's confidence after sign-off: anyone objecting, or more reluctant than willing sign-offs,
// lowers it one step (the stored confidence is kept; this is what people see).
function signedConfidence(level, counts) {
  const l = ["High", "Medium", "Low"].includes(level) ? level : "Medium";
  if (!counts) return { level: l, lowered: false };
  const agree = counts.agree || 0, reluctant = counts.disagree_commit || 0, object = counts.object || 0;
  if (object > 0 || reluctant > agree) return { level: { High: "Medium", Medium: "Low", Low: "Low" }[l], lowered: l !== "Low" };
  return { level: l, lowered: false };
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
// One person's links: WhatsApp straight to their number, or email straight to their address.
const phoneDigits = c => { const x = String(c || "").replace(/[\s().-]/g, ""); return /^\+?\d{7,15}$/.test(x) ? x.replace(/^\+/, "") : null; };
function personLinks(contact, msg, subject) {
  const ph = phoneDigits(contact), em = validEmail(contact) ? String(contact).trim() : "";
  return {
    whatsapp: `https://wa.me/${ph || ""}?text=${encodeURIComponent(msg)}`,
    email: `mailto:${encodeURIComponent(em).replace(/%40/g, "@")}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(msg)}`,
    phone: !!ph, mail: !!em
  };
}
// Add links: a URL box with "Add link", and the list so far (each removable). Calls onChange(list).
const validUrl = u => { try { const x = new URL(String(u).trim()); return /^https?:$/.test(x.protocol) && x.hostname.includes("."); } catch { return false; } };
function linksEditor(list, max, onChange) {
  const box = el("div", "stack-sm");
  const ul = el("ul", "plain");
  const row = el("div", "add-row");
  const inp = el("input", "line"); Object.assign(inp, { type: "url", inputMode: "url", maxLength: 500, placeholder: t("link_ph") });
  inp.setAttribute("aria-label", t("links_lbl"));
  const add = el("button", "btn soft", t("link_add")); add.type = "button";
  const err = el("p", "status err");
  const draw = () => {
    ul.replaceChildren(...list.map((u, i) => {
      const li = el("li", "file");
      const a = el("a", "nm", u); a.href = u; a.target = "_blank"; a.rel = "noopener noreferrer";
      const x = el("button", null, "×"); x.type = "button"; x.setAttribute("aria-label", t("remove"));
      x.onclick = () => { list.splice(i, 1); onChange(list); draw(); };
      li.append(a, x); return li;
    }));
    row.hidden = list.length >= max;
  };
  const addOne = () => {
    let u = inp.value.trim(); if (!u) return;
    if (!/^https?:\/\//i.test(u)) u = "https://" + u;
    if (!validUrl(u)) { err.textContent = t("need_url"); return; }
    err.textContent = "";
    if (!list.includes(u)) { list.push(u); onChange(list); }
    inp.value = ""; draw();
  };
  add.onclick = addOne;
  inp.onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); addOne(); } };
  row.append(inp, add);
  box.append(ul, row, err);
  draw();
  return box;
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
  if (ext === "zip" || f.type === "application/zip") return "zip";
  return null;
}
// Slack's export is JSON per channel and day: [{user_name|user, text, ts}]. Turn it into "name: message" lines.
function slackLines(json) {
  try {
    const rows = JSON.parse(json);
    if (!Array.isArray(rows)) return "";
    return rows.filter(m => m && typeof m.text === "string" && m.text.trim())
      .map(m => `${m.user_profile?.real_name || m.user_name || m.user || "?"}: ${m.text}`).join("\n");
  } catch { return ""; }
}
async function readFile(f) {
  const kind = fileKind(f);
  if (kind === "text") return await f.text();
  if (kind === "sheet") {
    await loadScript(LIB + "xlsx@0.18.5/dist/xlsx.full.min.js");
    const wb = XLSX.read(await f.arrayBuffer(), { type: "array" });
    return wb.SheetNames.map(n => `## Sheet: ${n}\n` + XLSX.utils.sheet_to_csv(wb.Sheets[n], { blankrows: false })).join("\n\n");
  }
  if (kind === "zip") {
    // A WhatsApp export ("_chat.txt" plus media) or a Slack export (JSON files). Read the text, skip the media.
    await loadScript("https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js");
    const zip = await JSZip.loadAsync(await f.arrayBuffer());
    const parts = [];
    for (const entry of Object.values(zip.files)) {
      if (entry.dir || /(^|\/)(__MACOSX|\.)/.test(entry.name)) continue;
      if (/\.txt$/i.test(entry.name)) parts.push(`## ${entry.name}\n` + await entry.async("string"));
      else if (/\.json$/i.test(entry.name)) { const lines = slackLines(await entry.async("string")); if (lines) parts.push(`## ${entry.name}\n` + lines); }
      if (parts.join("").length > 200000) break;
    }
    return parts.join("\n\n");
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

/* ---------- "Add a room" opens the setup as a pop-up over the current page ---------- */
const embedded = new URLSearchParams(location.search).get("embed") === "1";
if (embedded) document.documentElement.classList.add("embed");
function openNewRoom(href = "/new.html") {
  if (document.querySelector(".dr-pop")) return;
  const url = new URL(href, location.origin); url.searchParams.set("embed", "1");
  const pop = el("div", "dr-pop"); pop.setAttribute("role", "dialog"); pop.setAttribute("aria-modal", "true");
  pop.setAttribute("aria-label", t("new_room"));
  const panel = el("div", "dr-pop-panel");
  const close = el("button", "dr-pop-close", "×"); close.type = "button"; close.setAttribute("aria-label", t("close") || "Close");
  const frame = el("iframe"); frame.src = url.pathname + url.search; frame.title = t("new_room");
  panel.append(close, frame); pop.append(panel); document.body.append(pop);
  document.body.classList.add("dr-pop-open");
  const shut = () => { pop.remove(); document.body.classList.remove("dr-pop-open"); removeEventListener("keydown", onKey); };
  const onKey = e => { if (e.key === "Escape") shut(); };
  close.onclick = shut; pop.addEventListener("click", e => { if (e.target === pop) shut(); });
  addEventListener("keydown", onKey);
  close.focus();
}
// When the room is created inside the pop-up, the whole page moves to the new room.
addEventListener("message", e => {
  if (e.origin !== location.origin || e.data?.type !== "dr-open" || !String(e.data.url || "").startsWith("/room.html")) return;
  location.href = e.data.url;
});
// Any link to the setup page opens the pop-up instead (landing CTAs, Add a room, empty states).
if (!embedded) document.addEventListener("click", e => {
  const a = e.target.closest?.('a[href^="/new.html"]');
  if (!a || e.metaKey || e.ctrlKey || e.shiftKey) return;
  e.preventDefault(); openNewRoom(a.getAttribute("href"));
});
// Inside the pop-up, finishing hands the room's address to the page behind it.
function goToRoom(url) {
  if (embedded && window.parent !== window) window.parent.postMessage({ type: "dr-open", url }, location.origin);
  else location.href = url;
}

/* ---------- Ask the analyst: the always-on helper ---------- */
// A chat in the corner of setup and room pages. It helps people word the question, use each step and
// bring in sources from the web. It only knows what everyone in the room can see, never private answers.
// opts: {page, roomId, draft: () => ({question, options, criteria, type}), onAddSource: url => Promise}
function helper(opts = {}) {
  if (document.getElementById("helperBtn")) return;
  const demoMode = new URLSearchParams(location.search).get("demo");
  const key = "dr-helper-" + (opts.roomId || opts.page || "x");
  let msgs = []; try { msgs = JSON.parse(sessionStorage.getItem(key)) || []; } catch {}
  const keep = () => { try { sessionStorage.setItem(key, JSON.stringify(msgs.slice(-20))); } catch {} };
  const btn = el("button", "helper-btn", t("hp_open")); btn.id = "helperBtn"; btn.type = "button"; btn.setAttribute("aria-expanded", "false");
  const panel = el("section", "helper-panel"); panel.hidden = true; panel.setAttribute("aria-label", t("hp_title"));
  const head = el("div", "helper-head"); const x = el("button", "helper-x", "×"); x.type = "button"; x.setAttribute("aria-label", t("hp_close"));
  head.append(el("strong", null, t("hp_title")), x);
  const log = el("div", "helper-log"); log.setAttribute("aria-live", "polite");
  const sugg = el("div", "chips helper-sugg");
  const f = el("form", "helper-form"); const inp = el("textarea"); Object.assign(inp, { rows: 2, maxLength: 1500, placeholder: t("hp_ph") }); inp.setAttribute("aria-label", t("hp_ph"));
  const send = el("button", "btn", t("hp_send")); send.type = "submit"; f.append(inp, send);
  panel.append(head, log, sugg, f, el("p", "helper-note", t("hp_note")));
  document.body.append(panel, btn);
  const bubble = (m) => {
    const b = el("div", "helper-msg " + m.role); b.append(el("p", null, m.text));
    if (m.sources?.length) {
      const ul = el("ul", "plain helper-src");
      m.sources.forEach(sr => {
        const li = el("li"); const a2 = el("a", null, sr.title); a2.href = sr.url; a2.target = "_blank"; a2.rel = "noopener noreferrer"; li.append(a2);
        if (opts.onAddSource) { const add = el("button", "linkbtn", t("hp_add_source")); add.type = "button"; add.onclick = async () => { add.disabled = true; try { await opts.onAddSource(sr.url); add.textContent = t("hp_added"); } catch { add.disabled = false; } }; li.append(add); }
        ul.append(li);
      });
      b.append(ul);
    }
    return b;
  };
  const draw = () => {
    log.replaceChildren(...(msgs.length ? msgs.map(bubble) : [bubble({ role: "assistant", text: t(opts.roomId ? "hp_hello_room" : "hp_hello_setup") })]));
    log.scrollTop = log.scrollHeight;
    sugg.replaceChildren(...(msgs.length ? [] : t(opts.roomId ? "hp_sugg_room" : "hp_sugg_setup").map(q => chip(q, false, () => ask(q)))));
  };
  const ask = async text => {
    text = String(text || "").trim(); if (!text) return;
    msgs.push({ role: "user", text }); inp.value = ""; draw(); keep();
    const wait = el("div", "helper-msg assistant thinking"); wait.append(el("p", null, t("hp_thinking"))); log.append(wait); log.scrollTop = log.scrollHeight;
    send.disabled = true;
    try {
      let r;
      if (demoMode) r = { reply: t("hp_demo"), sources: [] };
      else if (!user) r = { reply: t("hp_sign_in_first"), sources: [] };
      else r = await post("/api/rooms/helper", { messages: msgs.map(m => ({ role: m.role, text: m.text })), room_id: opts.roomId || null, draft: opts.draft ? opts.draft() : null, page: opts.page || "", lang });
      msgs.push({ role: "assistant", text: r.reply || t("err_generic"), sources: r.sources || [] });
    } catch (e) {
      msgs.push({ role: "assistant", text: t(e.message === "quota" ? "err_quota" : "hp_fail") });
    }
    send.disabled = false; draw(); keep();
  };
  const open = on => { panel.hidden = !on; btn.setAttribute("aria-expanded", String(on)); btn.hidden = on; if (on) { draw(); setTimeout(() => inp.focus(), 50); } };
  btn.onclick = () => open(true); x.onclick = () => open(false);
  f.onsubmit = e => { e.preventDefault(); ask(inp.value); };
  inp.onkeydown = e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); ask(inp.value); } };
}

window.Rooms = {
  $, el, t, loadLang, firstLang, savedLang, langToggle, fmtDate, typeName, get lang() { return lang; },
  connect, profile, setName, trialSignIn, validEmail, isGuest, hasAccount, emailCode, showMyRooms,
  get sb() { return sb; }, get user() { return user; }, get emailCodes() { return emailCodes; },
  post, decideNow, signedConfidence, helper, errKey, apportion, chip, choice, shareLinks, personLinks, phoneDigits, copyText, agreeNote, fileKind, readFile,
  openNewRoom, goToRoom, embedded, validUrl, linksEditor
};
})();
