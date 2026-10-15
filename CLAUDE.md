# Decision Rooms (repo still named clarvy)

Decision Rooms helps leaders and organisations make decisions together: private input, a recommended thinking model, one call with reasoning, sign-off and review. Yellow editorial look (flat white square cards, black type, Inter; IBM Plex Sans Arabic for Arabic). English and Arabic. Open trial: everyone gives a name and an unverified email.
Product decisions live in `docs/product-foundation.md` (section 0); models in `docs/decision-models.md`. "Clarvy" is the name kept for a future, separate consumer product.

## Layout
- `public/index.html`: the landing page (home). Facts on it are cited; keep them sourced.
- `public/privacy.html`, `public/terms.html`: bilingual. No contact email or operator name yet (decided 2026-10-16); add both when the user provides them.
- `public/clarvy.html`: the old solo Clarvy app (single file: CSS, WebGL halo shader, composer, decision engine, result cards, history), unlisted (`noindex`), kept for the future consumer product. The "Solo decision pipeline" section below describes it.
- `lib/core.js`: server logic. It holds the OpenAI key, calls the Responses API (`/v1/responses`), and handles the access code, the per-IP rate limit and JSON parsing.
- `api/ask.js`, `api/search.js`: Vercel serverless endpoints wrapping `lib/core.js`.
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
- Owner journey: the landing page's "Open a room now" goes to Your rooms (`public/dashboard.html`); "Add a room" there opens the setup (`public/new.html?embed=1`) in a pop-up on the start side (any `/new.html` link opens the pop-up, see `openNewRoom` in rooms.js). Steps: name and email (asked once, skipped when the profile has both) → question and category (Business, Finance, Politics, or Custom with a name; the AI's lens follows the category) → options → what to weigh → **How should we decide?** (triage recommends a model, top 3 + "See all", optional RAPID roles) → what everyone should know (context, files incl. WhatsApp/Slack .zip exports, "Paste a conversation", how-to guides, more settings) → Open the room. Members open the invite link, give a name and email, and answer 4 steps (1-5 ratings, risk, gut pick, one concern).
- `public/room.html`: one page that shows join, input steps, waiting (roster, RAPID roles editor, objections), thinking, or the verdict (recommended call, model cards, tripwires, disagreement map, accept or override, sign-off). `?room=<id>`, `?join=<token>`; `?demo=1|owner|join|ar` (+ `&model=wrap|quick|cynefin|mece|standard&rapid=1`) runs every state in the browser with no backend.
- `public/report.html`: the branded decision report (`?r=<share token>` opens for anyone via `report_by_token`; `?room=<id>` for members via `report_for_member`; `?demo=1`). Download PDF uses the print styles. Owners create and switch off share links on the verdict ("Share the result"). Aggregates only, never who said what.
- Links: owners add room links in setup (everyone sees them); members add up to 3 links with their private answers. The Analyst reads both, pooled and unattributed.
- `public/dashboard.html`: My rooms (number cards, open rooms with Invite, ongoing, old). `public/rooms.html` redirects to it.
- `public/rooms/models.js`: the thinking models (core five: WRAP, Type 1 / Type 2 "quick", Cynefin, MECE, standard; RAPID is an add-on) and `recommend(signals)`, the rules that pick one. Shared by the browser and the server.
- `public/rooms/math.js`: per-member scoring and the disagreement map, plain code with no AI calls. Shared by the server and the demo.
- `public/rooms/rooms.js`, `rooms.css`: shared words, Supabase, trial sign-in (`trialSignIn(name, email)`, anonymous Supabase account with the email on the profile), share links, file readers. `emailCode()` is kept for when a real email sender exists.
- `lib/rooms.js`: `POST /api/rooms/triage` (reads signals from the question; code applies `recommend`) and `POST /api/rooms/decide` (owner only; blocked by an open RAPID objection). Decide reads every private input with `SUPABASE_SERVICE_ROLE_KEY`, runs the model (Cynefin adds a Sensemaker call; the Analyst uses web search except for "quick"), then the Judge, and writes one anonymous `analyses` row. It runs in the background after a 202, so it needs the long-running Node server (server.js), not Vercel.
- `supabase/migrations/*.sql`: the data model with row-level security. Raw inputs, sign-offs and trip briefs are readable only by their author; groups see ticks, counts and RAPID roles through security-definer functions. Run `supabase/tests/test_rls.py supabase/migrations/*.sql` after any schema change.
- `public/i18n/en.json`, `ar.json`: all words. Arabic sets `dir=rtl`; room content keeps the owner's language and direction. The AI has no name in copy ("Recommended call").
- `/api/config` hands the browser `SUPABASE_URL` and `SUPABASE_ANON_KEY` (public by design). The service role key stays on the server.
