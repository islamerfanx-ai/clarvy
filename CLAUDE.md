# Clarvy

Clarvy is a decision-making web app: "makes the call while you're still overthinking it." Dark halo look (Blink-inspired), playful voice, uppercase mono type.

## Layout
- `public/index.html`: the entire front end (single file: CSS, WebGL halo shader, composer, decision engine, result cards, history). No build step.
- `lib/core.js`: server logic. It holds the OpenAI key, calls the Responses API (`/v1/responses`), and handles the access code, the per-IP rate limit and JSON parsing.
- `api/ask.js`, `api/search.js`: Vercel serverless endpoints wrapping `lib/core.js`.
- `server.js`: plain Node server for local runs or non-Vercel hosts (`npm start`).

## Decision pipeline (in public/index.html, `decide()`)
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

## Decision Rooms (in progress, spec: docs/decision-rooms-spec.md)
- `supabase/migrations/20261012000000_decision_rooms.sql`: the whole v1 data model with row-level security. A member's raw input, sign-off and trip brief are readable by that member only (not the owner); groups see ticks and counts through security-definer functions (`room_roster`, `signoff_counts`, `trip_vote_counts`). The server reads inputs with the service role to compute the combined view. Inputs are validated by trigger: weights cover exactly the room's criteria, whole numbers summing to 100, and lock once the room leaves `open`.
- `public/room.html?room=<id>`: the My input screen (Supabase sign-in by email link). `?demo=1` and `?demo=ar` open in-browser demo rooms with no backend.
- `public/i18n/en.json`, `ar.json`: interface text. Arabic sets `dir=rtl`, switches to IBM Plex Sans Arabic and drops uppercase and letter-spacing. Room content keeps the owner's language and direction.
- `/api/config` hands the browser `SUPABASE_URL` and `SUPABASE_ANON_KEY` (public by design). Never send the service role key to the browser.
