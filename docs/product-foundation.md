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
