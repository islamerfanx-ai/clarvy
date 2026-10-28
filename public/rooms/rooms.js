// Shared by the Decision Rooms pages (index, new, room, dashboard): words, Supabase, trial sign-in,
// weights, file reading and small DOM helpers.
(() => {
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

/* ---------- Where people came from (first visit, kept in this browser) ---------- */
// Saved on the profile once, at sign-up, for the growth dashboard: an invite, an organisation link,
// a utm_source, the referring site, or direct.
const firstTouch = (() => {
  const KEY = "dr-first-touch";
  try {
    const q = new URLSearchParams(location.search);
    const now = q.get("join") && location.pathname.startsWith("/room") ? { src: "room_invite" }
      : q.get("join") && location.pathname.startsWith("/org") ? { src: "org_link" }
      : /type=invite/.test(location.hash) ? { src: "org_invite" } : null;
    // An invite always wins: that's how this person reached us, whatever they saw before.
    if (now) { localStorage.setItem(KEY, JSON.stringify(now)); return now; }
    const kept = JSON.parse(localStorage.getItem(KEY) || "null");
    if (kept) return kept;
    let ref = ""; try { ref = document.referrer ? new URL(document.referrer).hostname : ""; } catch {}
    const utm = q.get("utm_source");
    const first = utm ? { src: utm.toLowerCase().slice(0, 40), detail: [q.get("utm_medium"), q.get("utm_campaign")].filter(Boolean).join(" / ").slice(0, 200) || null }
      : ref && ref !== location.hostname ? { src: ref.replace(/^www\./, "").slice(0, 40) } : { src: "direct" };
    localStorage.setItem(KEY, JSON.stringify(first));
    return first;
  } catch { return { src: "direct" }; }
})();

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
  document.querySelectorAll(".ap-back").forEach(e => e.setAttribute("aria-label", t("ap_back")));
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
let sb = null, user = null, emailCodes = false, providers = [];
async function connect() {
  const cfg = await fetch("/api/config").then(r => r.ok ? r.json() : {}).catch(() => ({}));
  if (!cfg.supabase) return false;
  emailCodes = !!cfg.emailCodes;
  providers = Array.isArray(cfg.providers) ? cfg.providers : [];
  turnstileKey = cfg.turnstile || "";
  pushKey = cfg.push || null;
  await loadScript("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js");
  sb = window.supabase.createClient(cfg.supabase.url, cfg.supabase.anonKey);
  user = (await sb.auth.getSession()).data.session?.user || null;
  sb.auth.onAuthStateChange((_e, session) => { user = session?.user || null; });
  showMyRooms();
  syncPush();
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
// Accounts (2026-10-22): everyone signs in with Google, Microsoft or a 6-digit email code, then fills in a
// short profile. Old guest sessions (anonymous trial accounts) start fresh: they are signed out first.
async function dropGuest() { if (user?.is_anonymous) { await sb.auth.signOut(); user = null; } }
async function signOut() { await sb.auth.signOut(); user = null; showMyRooms(); }
const PROFILE_FIELDS = "name,email,organisation,job_title,country,phone,sector,org_size,photo_url,news_opt_in,completed_at,language";
async function myProfile() {
  if (!hasAccount()) return null;
  const { data } = await sb.from("profiles").select(PROFILE_FIELDS).eq("id", user.id).maybeSingle();
  return data;
}
async function saveProfile(patch) {
  const { error } = await sb.from("profiles").update(patch).eq("id", user.id);
  if (error) throw error;
}
// Countries as ISO codes, named in the page's language.
const COUNTRIES = "AE SA QA KW BH OM EG JO LB IQ SY PS YE MA DZ TN LY SD MR SO DJ KM TR IR PK IN BD LK NP AF CN JP KR SG MY ID TH VN PH HK TW AU NZ GB IE FR DE NL BE LU CH AT IT ES PT GR CY MT SE NO DK FI IS PL CZ SK HU RO BG HR SI RS BA ME MK AL UA RU KZ UZ AZ GE AM US CA MX BR AR CL CO PE VE ZA NG KE ET GH TZ UG RW SN CI CM ZM ZW AO MZ BW NA".split(" ");
function countrySelect(value) {
  const sel = el("select", "line role-select"); sel.style.width = "100%";
  let names; try { names = new Intl.DisplayNames([lang === "ar" ? "ar" : "en"], { type: "region" }); } catch { names = { of: c => c }; }
  const opts = COUNTRIES.map(c => [c, names.of(c) || c]).sort((a, b) => a[1].localeCompare(b[1], lang));
  const o0 = el("option", null, t("pf_country_pick")); o0.value = ""; sel.append(o0);
  opts.forEach(([c, n]) => { const o = el("option", null, n); o.value = c; if (c === value) o.selected = true; sel.append(o); });
  return sel;
}
// Sign in or sign up: Google and Microsoft buttons (when switched on), or an email and a 6-digit code.
function signInBox(box, { email = "", onDone } = {}) {
  box.replaceChildren();
  const wrap = el("div", "stack-sm signin");
  if (providers.length) {
    const row = el("div", "signin-providers");
    [["google", "Google"], ["azure", "Microsoft"]].filter(([p]) => providers.includes(p)).forEach(([p, label]) => {
      const b = el("button", "btn ghost", t("si_with", { provider: label })); b.type = "button";
      b.onclick = async () => {
        b.disabled = true;
        await dropGuest();
        // Google and Microsoft won't sign in inside a frame (the setup pop-up), so go through the main window.
        const framed = window.top !== window;
        const back = framed ? window.top.location.href : location.href;
        const { data, error } = await sb.auth.signInWithOAuth({ provider: p, options: { redirectTo: back, skipBrowserRedirect: framed, scopes: p === "azure" ? "email" : undefined } });
        if (error) { b.disabled = false; console.error(error); return; }
        if (framed && data?.url) window.top.location.href = data.url;
      };
      row.append(b);
    });
    wrap.append(row, el("p", "small signin-or", t("si_or")));
  }
  const codeBox = el("div");
  wrap.append(codeBox);
  box.append(wrap);
  emailCode(codeBox, { email, onDone });
}
// Signed in with a complete profile? If not, show what's missing in `box` and call onDone when ready.
async function ensureAccount(box, { email = "", name = "", intro = null, onDone } = {}) {
  const profileStep = async () => {
    const p = await myProfile();
    if (p?.completed_at && p.name && p.organisation && p.job_title && p.country) return onDone(p);
    profileForm(box, { profile: { ...p, name: p?.name || name }, intro: t("pf_intro"), onDone });
  };
  if (hasAccount()) return profileStep();
  signInBox(box, { email, onDone: profileStep });
  if (intro) box.prepend(intro);
}
// The required profile: full name, organisation, job title, country (the email is already verified).
function profileForm(box, { profile = {}, intro = "", onDone, saveLabel } = {}) {
  const f = el("form", "stack-sm profile-form"); f.noValidate = true;
  const field = (id, label, input) => { const w = el("div", "field"); const l = el("label", "lbl", label); l.htmlFor = id; input.id = id; w.append(l, input); return w; };
  const mk = (val, max, ph, ac) => { const i = el("input", "line"); Object.assign(i, { value: val || "", maxLength: max, placeholder: ph || "", autocomplete: ac || "off" }); return i; };
  const name = mk(profile.name, 80, "", "name"), org = mk(profile.organisation, 120, t("pf_org_ph"), "organization"), title = mk(profile.job_title, 80, t("pf_title_ph"), "organization-title");
  const country = countrySelect(profile.country);
  const st = el("p", "status err"); st.setAttribute("role", "status");
  const go = el("button", "btn", saveLabel || t("pf_continue")); go.type = "submit";
  if (intro) f.append(el("p", "small", intro));
  if (profile.email) f.append(el("p", "small", t("pf_signed_as", { email: profile.email })));
  f.append(field("pfName", t("pf_name"), name), field("pfOrg", t("pf_org"), org), field("pfTitle", t("pf_title"), title), field("pfCountry", t("pf_country"), country), go, st);
  f.onsubmit = async e => {
    e.preventDefault();
    const patch = { name: name.value.trim(), organisation: org.value.trim(), job_title: title.value.trim(), country: country.value || null };
    if (!profile.completed_at) Object.assign(patch, { signup_source: firstTouch.src, signup_detail: firstTouch.detail || null });
    if (!patch.name) { name.focus(); st.textContent = t("need_name"); return; }
    if (!patch.organisation) { org.focus(); st.textContent = t("pf_need_org"); return; }
    if (!patch.job_title) { title.focus(); st.textContent = t("pf_need_title"); return; }
    if (!patch.country) { country.focus(); st.textContent = t("pf_need_country"); return; }
    go.disabled = true;
    try { await saveProfile(patch); onDone && onDone({ ...profile, ...patch }); }
    catch (err) { console.error(err); st.textContent = t("err_generic"); go.disabled = false; }
  };
  box.replaceChildren(f);
  setTimeout(() => (name.value ? org.value ? title : org : name).focus(), 50);
}
function showMyRooms() { const a = $("myRoomsLink"); if (a) a.hidden = !hasAccount() || !!$("acctMenu"); accountMenu(); }
// The account avatar, top right on every page: initials in a circle, with a small menu.
let menuFor = null;
async function accountMenu() {
  const bar = document.querySelector(".top .top-acts") || document.querySelector(".top .nav");
  const old = $("acctMenu");
  if (!bar || !sb || !hasAccount()) {
    if (old) old.remove(); menuFor = null;
    document.querySelectorAll('[data-acct-hidden="1"]').forEach(x => { x.hidden = false; delete x.dataset.acctHidden; });
    return;
  }
  if (old && menuFor === user.id) return;
  if (old) old.remove();
  menuFor = user.id;
  const wrap = el("div", "acct"); wrap.id = "acctMenu";
  const btn = el("button", "acct-btn"); btn.type = "button"; btn.setAttribute("aria-haspopup", "menu"); btn.setAttribute("aria-expanded", "false");
  btn.setAttribute("aria-label", t("acct_menu"));
  btn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7"/></svg>';
  const menu = el("div", "acct-pop"); menu.setAttribute("role", "menu"); menu.hidden = true;
  const head = el("div", "acct-head");
  const item = (label, href, onClick) => { const x = el(href ? "a" : "button", "acct-item", label); x.setAttribute("role", "menuitem"); if (href) { x.href = href; x.target = "_top"; } else { x.type = "button"; x.onclick = onClick; } return x; };
  menu.append(head, item(t("pf_link"), "/profile.html"), item(t("my_rooms"), "/dashboard.html"), item(t("nt_link"), "/notes.html"));
  const out = item(t("si_sign_out"), null, async () => { await signOut(); (window.top || window).location.href = "/"; });
  menu.append(out);
  const open = on => { menu.hidden = !on; btn.setAttribute("aria-expanded", String(on)); };
  btn.onclick = e => { e.stopPropagation(); open(menu.hidden); };
  document.addEventListener("click", e => { if (!wrap.contains(e.target)) open(false); });
  document.addEventListener("keydown", e => { if (e.key === "Escape") open(false); });
  // "Your rooms" as a round icon beside the avatar; the text links it replaces are hidden.
  const rooms = el("a", "acct-btn acct-rooms"); rooms.href = "/dashboard.html"; rooms.target = "_top";
  rooms.setAttribute("aria-label", t("my_rooms")); rooms.title = t("my_rooms");
  rooms.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M4 21V4.5A1.5 1.5 0 0 1 5.5 3h9A1.5 1.5 0 0 1 16 4.5V21"/><path d="M16 7h2.5A1.5 1.5 0 0 1 20 8.5V21M2 21h20"/><circle cx="12.5" cy="12.5" r=".9" fill="currentColor"/></svg>';
  document.querySelectorAll('.top a.navlink[href="/dashboard.html"]').forEach(x => { x.hidden = true; x.dataset.acctHidden = "1"; });
  wrap.append(rooms, btn, menu);
  bar.append(wrap);
  // Initials, name and organisation once the profile loads; the organisation link if there is one.
  try {
    const { data: p } = await sb.from("profiles").select("name,email,organisation").eq("id", user.id).maybeSingle();
    const name = (p?.name || "").trim();
    if (name) { btn.textContent = name.split(/\s+/).slice(0, 2).map(w => w[0]).join("").toUpperCase(); btn.classList.add("has-name"); }
    head.append(el("b", null, name || p?.email || ""), el("span", null, [p?.organisation, p?.email].filter(Boolean).join(" · ")));
    const { data: os } = await sb.rpc("my_orgs");
    if (os?.length) menu.insertBefore(item(os.length === 1 ? os[0].name : t("og_link"), "/org.html"), out);
  } catch {}
}

/* ---------- Email sign-in: a 6-digit code typed here, or the link in the email ---------- */
// Builds the email -> code steps inside `box`. A guest who adds an email keeps their rooms
// (their anonymous account is upgraded); anyone else signs in or signs up. Without codes
// (EMAIL_CODES off), the page waits for the link to be tapped, in any tab of this browser.
function emailCode(box, { onDone, email: preset = "" } = {}) {
  box.replaceChildren();
  const emailStep = el("form", "stack-sm"), codeStep = el("form", "stack-sm");
  codeStep.hidden = true;
  const eLbl = el("label", "lbl", t("email_lbl")); eLbl.htmlFor = "ecEmail";
  const eIn = el("input", "line"); Object.assign(eIn, { id: "ecEmail", type: "email", autocomplete: "email", required: true, inputMode: "email", value: preset });
  const eBtn = el("button", "btn", t(emailCodes ? "email_send" : "email_send_link")); eBtn.type = "submit";
  const cLbl = el("label", "lbl", t("code_lbl")); cLbl.htmlFor = "ecCode";
  const cIn = el("input", "line code"); Object.assign(cIn, { id: "ecCode", inputMode: "numeric", autocomplete: "one-time-code", maxLength: 10, pattern: "[0-9]*" });
  const cHint = el("p", "small");
  const cBtn = el("button", "btn", t("code_verify")); cBtn.type = "submit";
  const again = el("div", "row-acts");
  const resend = el("button", "linkbtn", t(emailCodes ? "code_resend" : "resend_link")); resend.type = "button";
  const change = el("button", "linkbtn", t("email_change")); change.type = "button";
  again.append(resend, change);
  const status = el("p", "status"); status.setAttribute("role", "status");
  // Already have a code from the last hour? Go straight to typing it.
  const have = el("button", "linkbtn", t("code_have")); have.type = "button"; have.hidden = true;
  have.onclick = () => { email = eIn.value.trim(); if (!validEmail(email)) { eIn.focus(); return; } emailStep.hidden = true; codeStep.hidden = false;
    cHint.textContent = t("code_hint", { email }); say(""); cIn.value = ""; cIn.focus(); };
  emailStep.append(eLbl, eIn, eBtn, have);
  codeStep.append(cLbl, cIn, cHint, cBtn, again);
  box.append(emailStep, codeStep, status);
  let mode = "email", email = "";
  const say = (msg, kind = "err") => { status.textContent = msg; status.className = "status " + kind; };
  async function send() {
    say("");
    eBtn.disabled = true;
    await dropGuest();   // old guest accounts start fresh
    let res;
    try { res = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href, captchaToken: await captchaToken() } }); }
    catch (err) { res = { error: err }; }
    mode = "email";
    eBtn.disabled = false;
    if (res.error) {
      const msg = res.error.message || "";
      const secs = Number((msg.match(/(\d+)\s*seconds?/i) || [])[1]);
      if (secs > 0) {
        // Supabase sends one code per address per minute: show the exact wait, and offer the code already sent.
        let left = secs; have.hidden = false; eBtn.disabled = true;
        const tick = () => { if (left <= 0) { clearInterval(timer); eBtn.disabled = false; return say(""); } say(t("email_wait_secs", { n: left }), "err"); left--; };
        const timer = setInterval(tick, 1000); tick();
        return;
      }
      if (/rate|too many/i.test(msg)) { have.hidden = false; return say(t("email_wait_hour")); }
      return say(t(/captcha/i.test(msg) ? "captcha" : "err_generic"));
    }
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
    if (token.length < 6 || token.length > 10) return say(t("code_wrong"));   // Supabase sends 6 or 8 digits, depending on the project
    cBtn.disabled = true;
    const { data, error } = await sb.auth.verifyOtp({ email, token, type: mode });
    cBtn.disabled = false;
    if (error) return say(t("code_wrong"));
    user = data.user || (await sb.auth.getUser()).data.user;
    showMyRooms();
    onDone && onDone(email);
  });
  setTimeout(() => (preset ? eBtn : eIn).focus(), 50);
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
  frame.allow = "microphone";   // "Say your question" records inside the pop-up
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
let helperApi = null;   // set by helper(): open the panel and ask a question from a button
function askHelper(q) { helperApi?.(q); }
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
  helperApi = q => { open(true); if (q) ask(q); };
  f.onsubmit = e => { e.preventDefault(); ask(inp.value); };
  inp.onkeydown = e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); ask(inp.value); } };
}

/* ---------- The app: install to the home screen, and phone notifications ---------- */
// The site installs as an app (manifest.webmanifest, sw.js). Notifications need the app installed on iPhone
// (iOS 16.4+); Android and computers allow them in the browser too. Each device saves a subscription
// (save_push_subscription); what people hear about is set in push_prefs.
let pushKey = null, installEvt = null;
const PUSH_KINDS = ["invites", "progress", "call", "after"];
const standalone = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const isIOS = () => /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const pushReady = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
if ("serviceWorker" in navigator && !embedded) navigator.serviceWorker.register("/sw.js").catch(() => {});
addEventListener("beforeinstallprompt", e => { e.preventDefault(); installEvt = e; document.dispatchEvent(new Event("dr-app")); });
addEventListener("appinstalled", () => { installEvt = null; document.dispatchEvent(new Event("dr-app")); });
const keyBytes = k => { const s = atob(k.replace(/-/g, "+").replace(/_/g, "/")); return Uint8Array.from(s, c => c.charCodeAt(0)); };
const deviceName = () => {
  const u = navigator.userAgent;
  const dev = /iPhone/.test(u) ? "iPhone" : /iPad/.test(u) || isIOS() ? "iPad" : /Android/.test(u) ? "Android" : /Mac/.test(u) ? "Mac" : /Windows/.test(u) ? "Windows" : "Computer";
  const app = standalone() ? "app" : /Edg\//.test(u) ? "Edge" : /Firefox\//.test(u) ? "Firefox" : /Chrome\//.test(u) ? "Chrome" : /Safari\//.test(u) ? "Safari" : "browser";
  return `${dev} · ${app}`;
};
async function currentSub() {
  if (!pushReady()) return null;
  const reg = await navigator.serviceWorker.getRegistration("/");
  return reg ? reg.pushManager.getSubscription() : null;
}
async function saveSub(sub) {
  const j = sub.toJSON();
  const { error } = await sb.rpc("save_push_subscription", { p_endpoint: j.endpoint, p_key: j.keys.p256dh, p_auth: j.keys.auth, p_ua: deviceName() });
  if (error) throw error;
}
// A device that already allowed notifications follows whoever signed in on it.
async function syncPush() {
  try { if (hasAccount() && Notification.permission === "granted") { const sub = await currentSub(); if (sub) await saveSub(sub); } } catch {}
}
const app = {
  standalone, isIOS, kinds: PUSH_KINDS,
  canInstall: () => !!installEvt,
  async install() { if (!installEvt) return false; installEvt.prompt(); const r = await installEvt.userChoice.catch(() => ({})); installEvt = null; return r.outcome === "accepted"; },
  // "unsupported", "install-first" (iPhone outside the app), "denied", "off" or "on".
  async pushState() {
    if (!pushKey) return "unsupported";
    if (isIOS() && !standalone()) return "install-first";
    if (!pushReady()) return "unsupported";
    if (Notification.permission === "denied") return "denied";
    return Notification.permission === "granted" && await currentSub() ? "on" : "off";
  },
  async enablePush() {
    if (await Notification.requestPermission() !== "granted") return app.pushState();
    const reg = await navigator.serviceWorker.register("/sw.js").then(() => navigator.serviceWorker.ready);
    const sub = await reg.pushManager.getSubscription() || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(pushKey) });
    await saveSub(sub);
    return "on";
  },
  async disablePush() {
    const sub = await currentSub();
    if (!sub) return;
    await sb.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
    await sub.unsubscribe().catch(() => {});
  },
  async prefs() { const { data } = await sb.from("push_prefs").select("off").eq("user_id", user.id).maybeSingle(); return data?.off || []; },
  async savePrefs(off) { const { error } = await sb.from("push_prefs").upsert({ user_id: user.id, off }); if (error) throw error; }
};
// The install and notifications box. full: also the four kinds (profile page). onDone: called once
// notifications are on and the app is installed, so a page can hide a reminder card.
async function appBox(box, { full = false, onDone } = {}) {
  const draw = async () => {
    box.replaceChildren();
    const state = await app.pushState().catch(() => "unsupported");
    const row = el("div", "ap-row");
    const btn = (label, cls, fn) => { const b = el("button", "btn " + cls, label); b.type = "button"; b.onclick = async () => { b.disabled = true; try { await fn(); } catch { note.textContent = t("ap_push_fail"); } b.disabled = false; }; return b; };
    const note = el("p", "small ap-note");
    if (!standalone()) {
      if (app.canInstall()) row.append(btn(t("ap_install"), "", async () => { await app.install(); draw(); }));
      else box.append(el("p", "small", t(isIOS() ? "ap_ios" : "ap_other")));
    } else box.append(el("p", "small", t("ap_installed")));
    if (state === "off") row.append(btn(t("ap_push_on_btn"), standalone() || !app.canInstall() ? "" : "ghost", async () => { const r = await app.enablePush(); if (r !== "on") note.textContent = t(r === "denied" ? "ap_push_denied" : "ap_push_fail"); else draw(); }));
    else if (state === "on") { box.append(el("p", "small ap-on", t("ap_push_on"))); if (full) row.append(btn(t("ap_push_off_btn"), "ghost", async () => { await app.disablePush(); draw(); })); }
    else if (state === "denied") note.textContent = t("ap_push_denied");
    if (row.children.length) box.append(row);
    box.append(note);
    if (state === "on" && full) {
      const off = await app.prefs().catch(() => []);
      const fs = el("fieldset", "ap-kinds"); fs.append(el("legend", null, t("ap_kinds")));
      PUSH_KINDS.forEach(k => {
        const lab = el("label", "check"); const c = el("input"); c.type = "checkbox"; c.checked = !off.includes(k);
        c.onchange = async () => {
          const now = PUSH_KINDS.filter(x => !fs.querySelector(`[data-k=${x}]`).checked);
          try { await app.savePrefs(now); note.textContent = t("ap_saved"); } catch { c.checked = !c.checked; note.textContent = t("ap_push_fail"); }
        };
        c.dataset.k = k; lab.append(c, el("span", "small", t("ap_k_" + k))); fs.append(lab);
      });
      box.append(fs);
    }
    if (state === "on" && (standalone() || !isIOS()) && onDone) onDone();
  };
  document.addEventListener("dr-app", draw);
  await draw();
}
// In the installed app there's no browser back button: a back arrow at the start of the header.
function appBack() {
  if (!standalone() || embedded || location.pathname === "/dashboard.html") return;
  const top = document.querySelector(".top"); if (!top || top.querySelector(".ap-back")) return;
  const b = el("button", "ap-back"); b.type = "button"; b.setAttribute("aria-label", t("ap_back"));
  b.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>';
  b.onclick = () => history.length > 1 ? history.back() : location.assign("/dashboard.html");
  const wm = top.querySelector(".wm");
  if (wm) { const g = el("div", "ap-start"); wm.replaceWith(g); g.append(b, wm); } else top.prepend(b);
}
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", appBack); else appBack();
if (standalone()) document.documentElement.classList.add("in-app");

window.Rooms = {
  $, el, t, loadLang, firstLang, savedLang, langToggle, fmtDate, typeName, get lang() { return lang; },
  connect, profile, setName, validEmail, isGuest, hasAccount, emailCode, showMyRooms, signInBox, ensureAccount, profileForm, myProfile, saveProfile, signOut, countrySelect, get providers() { return providers; },
  get sb() { return sb; }, get user() { return user; }, get emailCodes() { return emailCodes; },
  post, decideNow, signedConfidence, helper, askHelper, errKey, apportion, chip, choice, shareLinks, personLinks, phoneDigits, copyText, agreeNote, fileKind, readFile,
  openNewRoom, goToRoom, embedded, validUrl, linksEditor, app, appBox
};
})();
