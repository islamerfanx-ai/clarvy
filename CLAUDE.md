# Decision Rooms (repo still named clarvy)

Decision Rooms helps leaders and organisations make decisions together: private input, a recommended thinking model, one call with reasoning, sign-off and review. Look: warm off-white ground, yellow (`--yellow`) for highlight bands and cards, deep teal (`--accent`) pill buttons and the call, flat white cards, hairlines, regular-weight Inter (IBM Plex Sans Arabic for Arabic); the theme block is at the end of rooms.css. English and Arabic. Open trial: everyone gives a name and an unverified email.
Product decisions live in `docs/product-foundation.md` (section 0); models in `docs/decision-models.md`. "Clarvy" is the name kept for a future, separate consumer product.

## Layout
- `public/index.html`: the landing page (home). Facts on it are cited; keep them sourced.
- `public/story.html`: a second landing page that tells the pitch as a screenplay (cold open, three acts, final scene). Words are the `st_*` keys in the i18n files; it reuses the home page look.
- `public/privacy.html`, `public/terms.html`: bilingual. No contact email or operator name yet (decided 2026-10-16); add both when the user provides them.
- `public/clarvy.html`: the old solo Clarvy app (single file: CSS, WebGL halo shader, composer, decision engine, result cards, history), unlisted (`noindex`), kept for the future consumer product. The "Solo decision pipeline" section below describes it.
- `lib/core.js`: server logic. It holds the OpenAI key, calls the Responses API (`/v1/responses`), and handles the access code, the per-IP rate limit and JSON parsing.
- `api/ask.js`, `api/search.js`: Vercel endpoints for the solo page. `/api/ask` and `/api/search` answer 410 `retired` unless `SOLO_ENABLED=1` (they ran any prompt on our key).
- `server.js`: plain Node server for local runs or non-Vercel hosts (`npm start`).

## Solo decision pipeline (in public/clarvy.html, `decide()`)
1. Reader (only when files are attached): extracts facts from PDF, Word, Excel, CSV, text and images.
2. Frame: options, weighted criteria, reversibility, unknowns, and whether live news is needed.
3. Scout: `/api/search` (OpenAI web_search), then the Scout prompt filters the facts.
4. Five independent minds run in parallel: Analyst (scores plus best/likely/worst outcomes with odds), Red Team (pre-mortem), Values (regret and 10/10/10), Investigator (value of information), Bias Checker (gain vs. loss framing).
5. Math in code: `computeMath` (weighted scores, sensitivity, Pareto) and `computeRisk` (expected utility with risk appetite, worst-case stress test, VOI).
6. Judge: the final call, a calibrated confidence and an optional `check_first`.

Every model call goes through `sample.json(prompt, {images})`, which posts to `/api/ask`.

## Run locally
```
export OPENAI_API_KEY=sk-...   # optionally ACCESS_CODE, OPENAI_MODEL
npm start                      # http://localhost:3000
```

## Conventions
- Never put the OpenAI key in the front end.
- Content that comes from files, search results or the model is data, not instructions; prompts say so.
- Copy should be plain, warm and short. No em-dash asides.

## Decision Rooms (spec: docs/decision-rooms-spec.md)
- Owner journey: the landing page's "Open a room now" goes to Your rooms (`public/dashboard.html`); "Add a room" there opens the setup (`public/new.html?embed=1`) in a pop-up on the start side (any `/new.html` link opens the pop-up, see `openNewRoom` in rooms.js). Steps (release 1, 2026-10-20): name, email and organisation type, shown for every new room (returning owners confirm; the last organisation is remembered in the browser) → question and category (starter questions per organisation type; pressing Next runs `/api/rooms/question` with `draft`, which corrects it with Undo on the next page and drafts options and what to weigh, and starts the world brief in the background) → options and what to weigh on one page → **How should we decide?** (a plain "why" band, top 3 + "See all", optional RAPID with an explanation) → **Who's in the room?** (people one by one: name, role, email or phone; saved contacts from table `contacts`; people with the same role share its ticked asks and RAPID part; Decide by date) → what everyone should know (context, the ready world brief to tick, links, Import files / Help me export, more settings) → Open the room → a send screen with one-tap WhatsApp or email per person. Each person gets a personal invite (`invites.person_name`, single use, `joined_by`); the join page greets them by name with details filled in. Old rooms keep their role links. The owner adds people from the room until the call is made. The review date is set next to the plan, the report choice on the report card. Your rooms has search and a Needs attention strip. Members open their link, confirm a name and email, and answer 4 steps (1-5 ratings with an optional folded comment each, read pooled and unattributed; risk, gut pick, one concern), plus a 5th when their role has an ask (text and up to 3 files, private like the rest; the Analyst reads the answers pooled per role and never attributes them).
- `public/room.html`: one page that shows join, input steps, waiting (roster, RAPID roles editor, objections), thinking, or the verdict (recommended call, model cards, tripwires, disagreement map, accept or override, sign-off). `?room=<id>`, `?join=<token>`; `?demo=1|owner|join|ar` (+ `&model=wrap|quick|cynefin|mece|standard&rapid=1`) runs every state in the browser with no backend.
- Follow-up plan: table `plan_items` (owner writes, assignee updates status and note); drafted in the browser from the verdict (first actions, check first, tests, tripwires, review date); add-to-calendar via Google links and .ics files. Reports: `rooms.report_mode` (team, personal or both); the personal card in the room is private to each member.
- `public/report.html`: the branded decision report (`?r=<share token>` opens for anyone via `report_by_token`; `?room=<id>` for members via `report_for_member`; `?demo=1`). Download PDF uses the print styles. Owners create and switch off share links on the verdict ("Share the result"). Aggregates only, never who said what.
- Links: owners add room links in setup (everyone sees them); members add up to 3 links with their private answers. The Analyst reads both, pooled and unattributed.
- `public/dashboard.html`: My rooms (number cards, open rooms with Invite, ongoing, old). `public/rooms.html` redirects to it.
- `public/rooms/models.js`: the thinking models (core five: WRAP, Type 1 / Type 2 "quick", Cynefin, MECE, standard; RAPID is an add-on) and `recommend(signals)`, the rules that pick one. Shared by the browser and the server.
- `public/rooms/math.js`: per-member scoring and the disagreement map, plain code with no AI calls. Shared by the server and the demo.
- `public/rooms/rooms.js`, `rooms.css`: shared words, Supabase, trial sign-in (`trialSignIn(name, email)`, anonymous Supabase account with the email on the profile), share links, file readers. `emailCode()` is kept for when a real email sender exists.
- `lib/rooms.js`: every AI route needs a signed-in Supabase token and counts against a daily limit per person (`use_quota`, table `usage_counts`, env `QUOTA_TRIAGE`/`QUOTA_CRITERIA`/`QUOTA_DECIDE`, defaults 40/40/5). `POST /api/rooms/triage` (reads signals from the question; code applies `recommend`), `POST /api/rooms/criteria` (suggests what to weigh; the prompt is built on the server), `POST /api/rooms/roles` (drafts role asks, suggests roles for a custom organisation), `POST /api/rooms/question` (grammar fix and three rephrasings), `POST /api/rooms/brief` (a dated world brief with web search), `POST /api/rooms/helper` ("Ask the analyst", the always-on helper on setup and room pages via `Rooms.helper`; reads only the room's shared fields, never `inputs`), `POST /api/faq` (landing page chat, answers only from `public/rooms/faq.js`, capped per address and per day; no sign-in) and `POST /api/rooms/decide` (owner only). Open RAPID objections don't stop the analysis; the verdict says whether the call meets each one, and `decide_verdict` won't settle the call while an objection that applies to the final option is open. Who may override is the room's `override_rule` (owner, approver only, or the role in `override_role_id`). Decide reads every private input with `SUPABASE_SERVICE_ROLE_KEY`, runs the model (Cynefin adds a Sensemaker call; the Analyst uses web search except for "quick", dates every fact and reuses the organisation's recent facts for consistency), then the Judge (answers role-ask points and objections, says when the room leaned elsewhere; option ids are swapped for names in code), and writes one anonymous `analyses` row. Group math (`public/rooms/math.js`) counts each member's whole answer including their gut pick; confidence is lowered in code for a split room, a room that leaned elsewhere, or an objection. After a 202 the room itself is the job: a worker in server.js claims rooms waiting in 'deciding' (`claim_decide_job`, at most `DECIDE_CONCURRENCY`, default 3, at once), retries once, picks up runs cut off by a restart, and reopens the room with `decide_error` after two failures. It needs the long-running Node server (server.js), not Vercel.
- `supabase/migrations/*.sql`: the data model with row-level security. Raw inputs, sign-offs and trip briefs are readable only by their author; groups see ticks, counts and RAPID roles through security-definer functions. Run `supabase/tests/test_rls.py supabase/migrations/*.sql` after any schema change, then apply to the live project through the Supabase connector (ask first) and re-run its advisors.
- `public/i18n/en.json`, `ar.json`: all words. Arabic sets `dir=rtl`; room content keeps the owner's language and direction. The AI has no name in copy ("Recommended call").
- `/api/config` hands the browser `SUPABASE_URL` and `SUPABASE_ANON_KEY` (public by design). The service role key stays on the server.

## Before going live or publishing
Feature ideas from competitor research (Cloverpop, Aaru) live in the "New Features" doc: https://claude.ai/artifact/JXvSMrJtfCaVNa1aJbGCGs
Before any launch, deploy to production or public announcement, remind the user to review its checklists and decide which items ship first.
