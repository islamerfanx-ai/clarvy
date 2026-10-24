# Decision Rooms: Product Foundation

Status: decisions recorded 2026-10-15 (section 0) · Mission and values approved for the site
This is the one place that says what Decision Rooms is, who it's for, what it promises, and what we build next.
The detailed specs hang off it: `docs/decision-rooms-spec.md` (Rooms) and `docs/decision-models.md` (thinking models).

## 0. Decisions (2026-10-15)

| Topic | Decision |
| --- | --- |
| Product name | **Decision Rooms.** "Clarvy" is kept for the separate, fun consumer product later. |
| AI voice | **No name.** "Recommended call", "Weighing everyone's view". The product name does the branding. |
| Address | **clarvy.tejarra.com for the trial**; a Decision Rooms address after it. |
| Customers | Leadership groups **and organisations** (for example the Arab League; the UN later). **Universal**, no regional focus. |
| Individuals | **Out for now.** A separate, more fun consumer product later. |
| Solo page | **Hidden, code kept** at an unlisted address for the future consumer product. Home page becomes Decision Rooms. |
| Trip rooms | **Move to the consumer product.** Rooms cover business, finance and politics / public affairs. |
| Look | **Yellow editorial** across the whole product (every page, the same style). |
| Home page | **Leads with deciding together** (Rooms). |
| Build order | **Thinking models first**, then foundations, then launch. |
| Launch models | **Core 5:** WRAP, Type 1 / Type 2, Cynefin, MECE, RAPID roles. OODA, Test it first, Stage-Gate and Crisis mode follow. |
| Model names | **Framework names first**, plain line under each. |
| Chooser | **Top 3 + "See all models".** |
| RAPID veto | An approver's objection **blocks Decide now** until withdrawn or overridden on the record with a reason. |
| Trial access | **Open trial.** Everyone gives a name and an email (not verified): owners when they open a room, members when they join. No code or link. Goal: test with real customers and collect feedback. Rooms stay tied to that browser until an email sender adds "send me a link to come back". Set a monthly spend cap in the OpenAI dashboard. |
| Mission and values | **Approved as drafted** (sections 1 and 2), updated for organisations. |
| Landing page | Main button **Open a room now** (self-serve trial). **Plans shown with prices, marked "Free during the trial".** Fact cards **only with real, cited sources**. Lives at **clarvy.tejarra.com** for now. |
| Landing animation (2026-10-16) | **Mirrored flowing lines:** threads come in from one side, meet at one teal point, and open out the same way on the other (mirrored for Arabic). |
| Organisation type (2026-10-16) | **Asked in every new room**: Corporation or company department, Government or ministry, International body or NGO, Club or association, or **Custom** (owner types it, e.g. "Football federation"; the AI works out the roles). |
| Who's in the room (2026-10-16) | New setup step **after "How should we decide?"**; the RAPID roles merge into it. Suggested roles come from a **ready list per organisation type** (e.g. corporation: CEO, CFO, directors, managers; international body: Secretary-General, member state delegates, committee chairs; government: minister, deputy minister, advisors). The **AI suggests roles only for custom types**, or adds one or two that fit the question. Every list offers **External advisor or consultant** and **Add a custom role**. |
| Role invites (2026-10-16) | **One invite link per role**; people join already tagged with it. The owner sets **how many people per role** (e.g. CEO one, directors many); a full role's link closes. |
| Role asks (2026-10-16) | The **AI drafts a specific ask per role** from the question (e.g. "CFO: add the cost numbers and the 3-year cash impact"); the owner edits or removes it. The member sees it as an **extra step after the usual four, with a text answer and optional files or links**. Answers stay **private and pooled**, like every other input. |
| Role weight and visibility (2026-10-16) | **Everyone counts equally**; roles shape what we ask, not the math. **Nothing is hidden by role**: context, files, links and the result are shared with the whole room. Job titles are separate from RAPID roles (who someone is vs. who decides). |
| Scale and safety first (2026-10-16) | Before growing: **(1) close the open AI routes and add quotas**: sign-in required for every AI call, switch off `/api/ask` and `/api/search` (open to anyone today), daily limits per user stored in Supabase (e.g. Decide now per owner, triage per user, rooms per day), a Turnstile bot check on trial sign-up, and stop trusting a client-supplied `X-Forwarded-For`. **(2) one database cleanup migration**: lock internal SECURITY DEFINER and trigger functions to internal use, fix the 3 mutable `search_path` functions, wrap `auth.uid()` as `(select auth.uid())` in the 31 policies, add the 8 missing foreign-key indexes, drop or lock the old workspace/trip/calendar tables; tested with test_rls.py before it touches the live database. Later: analyses as a job queue in Supabase that survives restarts and caps concurrent OpenAI calls; secrets hardening (env file 600, separate OpenAI project with a hard limit, new Supabase secret keys, rotation checklist, own server). |
| Sign-in after the trial (2026-10-16) | **Stay on Supabase Auth** (not Firebase): Microsoft and Google sign-in plus magic link (needs an email sender; check for a Claude connector first). Trial (anonymous) users link a real account and keep their rooms. SAML company SSO and MFA later on a paid plan. |
| Persona drill fixes (2026-10-17) | After a 20-room persona drill (4 sectors, every model): the group math counts each member's whole answer (weights 45%, risk 25%, gut pick 30%) and flags a split honestly; confidence drops for a split room, a room that leaned elsewhere, an objection, or a reluctant sign-off; the verdict answers role-ask figures, objections and member-proposed options, and can recommend a sequenced mix, a crisis statement and owned first actions. **RAPID objections no longer block Decide now; they block settling the call.** Each room sets who may override an approver (owner, approver only, or a named higher role); objections can target one option; the report carries a decision record. Triage reads pace (crisis, changing) and framing (narrow yes/no) and no longer defaults to MECE. Facts carry a date and kind, prefer primary sources, include named market figures, stay consistent across an organisation's rooms; Type 1/Type 2 rooms use only room facts. No option codes or cut-off text. Busy sign-ups retry. Strict confidentiality option. Later (bigger features the personas asked for): SSO or verified accounts, data residency and a security pack, audit export and Council or board templates, linked rooms, budget linkage, WhatsApp reminders on tripwire dates, separate workspaces, local billing. |
| Next round (2026-10-17) | In this order: **(1) Check my question**: grammar fix plus three rephrasings to pick from, flags loaded wording. **(2) World brief**: while setting up, the owner can pull a short dated brief of what is happening in the world for this question (markets, logistics such as freight, ports and routes, rules, security) and add items to what everyone sees; every model now searches, Type 1/Type 2 lightly. **(3) Follow-up plan**: the call becomes a plan everyone sees, with actions, owners, due dates, tripwire checks and the review date, plus add-to-calendar (Google, Outlook, Apple); automatic reminders wait for an email or WhatsApp sender. **(4) Reports**: the owner chooses a team report, personal reports (each member sees their own answers next to the call, private to them), or both. **(5) Always-on helper "Ask the analyst"**: unnamed (the AI keeps no name); helps write the question and use each step, fetches web sources the owner can add to the room; never sees anyone's private answers; daily limit. **(6) Landing page FAQ** plus a chat that answers only from the FAQ, limited per address. **Members withdrawing: not now**; when built, the owner sets it per room. |
| Setup redesign from user testing (2026-10-20) | From the owner's printed review: **(1)** Organisation type sits on the first screen with name and email, and that screen shows at the start of every new room (name and email filled in for returning people), so the organisation is always confirmed or changed there. It is not repeated on the question step. **(2)** The question is corrected automatically by the AI once typed ("Corrected by AI", with undo); rephrasings stay as choices; "Check my question" gets a one-line description. **(3)** Research starts in the background as soon as the question is written, so the world brief is ready (as tickable items) by the last step and the call comes faster. **(4)** Options arrive pre-filled from the question, covering when, how and who, so a yes/no question becomes real alternatives; adding your own is the extra. **(5)** "What to weigh" merges into the options page as a pre-filled list you edit inline. **(6)** The model step says plainly why it is recommended; RAPID keeps its name with a clear explanation of what it means. **(7)** People are invited one by one (name, role, email or phone), with an address book of saved contacts; no "people with this link" limit; each gets their own link, sent with one tap by WhatsApp or email until automatic sending exists; invites move from the room into setup. **(8)** Suggested asks per person are multiple-choice (tick several). **(9)** "Import files" and "Help me export" replace "Add files" and "Where to find useful files". **(10)** The review date is asked after the decision, next to the plan; the report choice (team, personal, both) is made when the report is made. **(11)** Members can add an optional, folded comment under each rating; the analysis reads them pooled and anonymous. **(12)** Personal links open on "Hi Kenji" with name and contact filled in from the invite. **(13)** The owner can add people from the room until the decision is made. **(14)** Auto-correct and the background research start only when the owner presses Next on the question step, counted against daily limits. **(15)** Existing rooms keep their role links; per-person invites apply to new rooms. **(16)** It ships in two releases after the owner reviewed a features document (next row). |
| Next two releases (2026-10-20) | Decided step by step against the New Features doc and `review-whatif-nudges.md`; full list in `docs/next-release.md`. **Release 1, before the call:** the setup redesign above, the thinking screen, starter questions per organisation type, an optional Decide by date (7 days by default), Needs attention reminders the owner sends, and search on Your rooms. **Release 2, after the call:** a stakeholder reaction panel, a said vs would do check, a value line, The numbers (what-if sliders), an owner-only what-if re-run that uses a Decide credit and never changes a settled call, reopen with a reason, review and Track record. **Later:** decision styles (vote, consensus), Slack, landing page stories, automatic reminders (email first). Each release is built whole, shown once in the demo, then the owner approves database changes and the push. |
| Review, track record, what if, nudges (2026-10-19) | Plan in `docs/review-whatif-nudges.md`. **Owner logs the outcome; members rate privately 1-5** (room sees average and spread, spread only from 3 raters). Score named **Track record**, shown from 3 reviewed rooms. **What if** panel changes weights, risk mix and the Analyst's option scores, labelled "The numbers", never changes the settled call (owner can reopen with a reason). **Stuck rooms:** in-app "Needs attention" plus a one-tap WhatsApp or email the owner sends; automatic email (Resend) then WhatsApp later. New optional "decide by" date. **Build order: Review → Track record → What if → Nudges.** |
| Pricing plans (2026-10-22) | Priced by people per room, with a monthly room allowance because AI cost grows with rooms, not people (estimate about $1.20 to $1.50 a room on gpt-5.5). **Free:** up to 3 people per room, 2 rooms a month. **Small:** up to 5 people, 5 rooms, $39 a month. **Team:** up to 10 people, 15 rooms, $99 a month. **Organisation:** more than 10 people per room, custom contract (invoice, pilot, onboarding). **Facilitated decision:** one-off, from $1,500. Extra rooms on paid plans $10 each. "Several workspaces" is not offered until shared workspaces exist. Every AI call is logged with its estimated cost (scripts/cost-report.py) to check the estimate against real rooms before prices go on the landing page. |
| Accounts, profiles and organisations (2026-10-22) | **Sign-up before use:** Google, Microsoft or a 6-digit email code (Resend as the sender); invited members confirm their personal link with one code; old guest accounts start fresh. **Profile:** required at sign-up: full name, organisation, job title, country and a verified email; optional later: phone (WhatsApp invites), sector and size, photo, product news (opt-in, off by default). Email and phone are seen only by the person and the operator. **Admin page** for the operator: sign-ups, who they are, rooms, decisions, AI cost, CSV export. **Organisations** (custom plan, created only by the operator, who names the first admin): people join by admin email invite (list or CSV), verified company email domain, or a private join link; org admins see people and the room list (status, calls) but never private answers; shared people directory, departments, logo on reports, organisation track record. **Organisation memory, not training:** the analysis looks up the organisation's past calls, reviews, lessons and facts each time (opt-in, admin-controlled, never private answers, never across organisations), so "we never train AI on your data" stays true; private regional deployment later for governments. Build order: sign-up, profiles, admin page, organisations, organisation memory. |
| World library (2026-10-24, starts at launch) | **Not model training.** A daily job searches the news and writes short, dated, sourced briefs into our database; the Analyst and the setup world brief read the latest ones for the room's sector and country, so facts are fresh and cited. Fine-tuning was rejected: it teaches style not facts, goes stale daily, costs more, and training on room questions would break "we never train AI on your data". **Coverage** follows the regions and countries our customers choose (from profiles and rooms), across economy and markets, government and policy, and business sectors. Topic counts from rooms (no text, no names) only decide which sectors to cover. **Checking:** automatic every morning, shown on a "World library" admin tab with sources and cost; the operator can hide a bad brief. **Budget:** start at $20 a month after launch and grow with use. **Until launch nothing changes:** the analysis keeps searching the web per room as it does now. |
| After the call: the talk space (idea, 2026-10-24, not scheduled) | Opens only after the call is made, so private, unattributed input stays honest before it. Four parts, all wanted: **Ask the decision** (any member asks the analyst about the call, reasons and what-ifs; reads the verdict, reasons and numbers, never private answers); **follow-through threads** on each plan item and tripwire (updates, blockers, done); **an open team chat** under the verdict, names showing; **a reopen request** ("something changed", others back it, the owner can reopen; same as release 2's reopen). Everyone in the room can post. New messages show as a badge in Your rooms and in Needs attention (no emails yet). Next step when picked up: a mock-up first. |

## 1. Mission, vision, promise

**Your draft** (kept for reference):
> We need to help the world, organizations, corporations and individuals make decisions based on facts, data, numbers and what is going around in the world. Through collaborating with teams, world leaders, experienced leaders and decision making AI models. Going through a deep critical thinking process, building the decision from bottom to top, through learning from your data and the data circulating around your data. Keeping the security of your data and decisions as our top priority. Giving analysis and reasoning for every decision made with your collaborators.

**Proposed:**

- **Mission:** Help leaders and organisations make better decisions together: grounded in facts, honest about disagreement, and accountable for how they turn out.
- **Vision:** Important decisions everywhere are made on evidence and every voice in the room, not on the loudest opinion in it.
- **What Clarvy does (one paragraph):** Clarvy brings your question, your files and what's happening in the world into one place. Everyone involved gives their view privately. Clarvy thinks it through with a proven decision model, from the facts up, and makes one clear call with its reasoning shown. The owner signs it off, and on the review date the group checks whether it was right.
- **Promise (tagline):** Makes the call while you're still overthinking it.
- **Positioning line (from the spec):** ChatGPT gives you an answer. Clarvy runs your decisions.

What changed and why:

| Draft | Proposed | Why |
| --- | --- | --- |
| "the world, organizations, corporations and individuals" | "leaders and organisations" | A mission has to choose. Individuals get their own product later. |
| "world leaders, experienced leaders" | (moved to the roadmap: expert reviewers, facilitated decisions) | We don't have this yet; a mission can't promise it. |
| "learning from your data" | "your files and what's happening in the world" | "Learning" reads as training on customer data, which we never do. |
| "security as our top priority" | Value 4, with concrete rules | A security promise must be specific and true. |
| (missing) | "makes one clear call", "the owner signs it off" | Clarvy commits to an answer; people stay accountable. |
| (missing) | "every voice", "honest about disagreement" | Private input is the product's edge. |
| (missing) | "accountable for how they turn out" | The review loop and track record nobody can copy. |

## 2. Values (each one is a product rule, not a poster)

1. **Facts first.** Every call rests on evidence: your files, live facts with sources, base rates. *So we:* cite sources, never invent figures, and say plainly when facts are missing.
2. **Every voice counts.** People say what they really think when it's safe. *So we:* keep each person's input private, show disagreement as patterns ("two members weigh cash risk far higher"), never who said what.
3. **Show the reasoning.** A call without reasons is an opinion. *So we:* show why, the risks, what would change the call, and the model used, every time.
4. **Your data is yours.** *So we:* use your data only to produce your decision; never sell it or use it to train AI models; encrypt it at rest; give every room delete and export; keep raw inputs readable only by their author, enforced in the database.
5. **Decide, then check.** Overthinking is a cost too. *So we:* commit to one call, set tripwires and a review date, and score how it turned out.
6. **Neutral on politics.** *So we:* decide only from the group's own stated values, show the strongest case for each side, and never favour a party or candidate.

**Security, stated honestly (for the privacy page):** Questions, files and inputs are sent to our AI provider (OpenAI) only to produce the analysis. Under OpenAI's API terms they aren't used to train its models by default; OpenAI may keep them for up to 30 days for abuse monitoring unless we arrange zero data retention. Rooms data is stored in Supabase (Postgres, encrypted at rest), with row-level security so members only see their own rooms and only their own raw input. Verify the provider terms before publishing, and revisit if we offer regional hosting.

## 3. Who it's for

| | Who | What they get |
| --- | --- | --- |
| **Customers** | Leadership groups and organisations anywhere: founders and partners, boards, family businesses, investment committees, public-affairs and policy teams, and multilateral bodies (for example the Arab League; the UN later). | Rooms with private input, a recommended decision model (framework names first), a signed-off call with reasoning, a memo, reviews and a track record. English and Arabic. |
| **Members and observers** | The people those customers invite: partners, advisers, delegates, experts. | A private, two-minute way to say what they really think, and the result on the same link. |
| **Later, separate product** | Individuals and friend groups (solo decisions, trip planning). | A lighter, more fun consumer app built from today's solo engine. |

Pricing stays as in the Rooms spec (Team, Organisation, Facilitated decision), with an Institution tier to scope for multilateral bodies (more members, observers by delegation, stricter data handling).

## 4. One product, one loop

Everything Clarvy does is a step in one loop. Solo decisions use a short version of it; Rooms use all of it.

```
1. Ask      the question, options, context and files
2. Gather   live facts from the world, read the files
3. Hear     each person's view, privately             (Rooms)
4. Think    with a decision model, recommended or chosen
5. Call     one decision, confidence, reasons, risks, what would change it
6. Commit   owner accepts or overrides on the record; everyone signs off   (Rooms)
7. Check    tripwires and the review date; log what happened
8. Learn    the track record informs the next decision
```

## 5. Where we are (honest status)

| Loop step | Solo app | Rooms | Status |
| --- | --- | --- | --- |
| Ask | Composer (one question, details folded) | 5-step setup | Live |
| Gather | Reader + live search | Analyst with web search | Live |
| Hear | n/a | Private 4-step input, name-only join | Live |
| Think | One model (≈ WRAP), five minds, math | Analyst, per-member math, Judge | Live; model library designed (`decision-models.md`), not built |
| Call | Result cards | Verdict + disagreement map | Live |
| Commit | n/a | Accept/override, sign-off | Live |
| Check | Not built | Review date stored; no review screen yet | **Gap** |
| Learn | History in the browser only | Not built | **Gap** |

**Other gaps blocking a real launch:**

1. **Owner sign-in email**: Supabase's built-in email only reaches your own team and a few emails an hour. Needs a custom email sender (for example Resend with tejarra.com), which also turns on 6-digit codes.
2. **No privacy page or terms**, which the security value depends on.
3. **Two looks:** the main page is white and blue; Rooms are the yellow editorial style. Pick one.
4. **Two audiences on one home page:** the main page sells solo decisions; nothing explains Rooms to a paying customer.
5. **Decide now hasn't run end to end** with real members yet (no live test so far).
6. **Arabic copy** hasn't been reviewed by a native writer (the spec requires it).
7. **The solo engine lives in one 1,000+ line HTML file**; the thinking models will need it split into modules shared with the server.

## 6. The plan to go live (in order)

1. **Thinking models, core 5** (`decision-models.md`): Triage and the top-3 chooser; WRAP, Type 1 / Type 2, Cynefin, MECE; RAPID roles with blocking veto (one database change); tripwires card. Used in Rooms (setup step "How should we decide?", the server's Decide now, the verdict).
2. **Trial access and rename**: everyone gives a name and an email (not verified), owners and members alike; trial accounts may open rooms (one database policy change, together with step 1's). Rename the product to **Decision Rooms** everywhere (wordmark, titles, copy, prompts, emails); one yellow editorial style on every page.
3. **Landing page = home page**, yellow editorial, English and Arabic:
   1. Hero: headline, one line, **Open a room now**, secondary "See a demo room".
   2. Why decisions fail: 3 or 4 fact cards in the reference style, each number researched and cited.
   3. How it works: the loop in 5 steps.
   4. Thinking models: WRAP, Type 1 / Type 2, Cynefin, MECE, RAPID.
   5. What you get: verdict and disagreement map from the demo.
   6. Trust: your data is yours, private input, neutral on politics, delete and export.
   7. Who it's for: boards, founders and partners, family businesses, investment committees, policy teams, multilateral organisations.
   8. Plans: Team $99/month, Organisation from $499/month, Facilitated decision (one-off), "free during the trial".
   9. Final call to action; footer with privacy, terms, language switch. Solo page moved to an unlisted address; Trip removed from room types.
4. **Privacy page and terms**, from value 4, including what the open trial stores (email, name, rooms).
5. **One real test** of a room with 3 people end to end (setup, invites, inputs, Decide now, override or accept, sign-off), in English and Arabic.
6. **Go live**, with the OpenAI spend cap set.

After launch: review screen and track record; decision memo PDF; OODA, Test it first, Stage-Gate, Crisis mode; email sender with 6-digit codes; billing; native Arabic review.

## 7. Still open

- Email sender: not needed for the trial; needed later for "send me a link to come back" and verified accounts.
- Native Arabic review of all copy.
- Institution tier details for multilateral bodies.
- Built 2026-10-16: organisation type and "Who's in the room" (section 0). Later: the owner adding a role after the room opens.
- Built 2026-10-16: scale and safety steps (1) and (2) except the Turnstile bot check (needs Cloudflare keys). Analyses job queue built 2026-10-16. Still to build: sign-in after the trial, secrets hardening.
