# Clarvy Thinking Models: Deep Dive and Build Spec

Status: decisions recorded 2026-10-15 · Source: "Decision Making Process.docx" (Downloads)

**Decisions:** Rooms only (individuals move to a separate product). Launch with the **core 5**: WRAP (4.2), Type 1 / Type 2 (4.1 Quick call, with 4.2 as the one-way route), Cynefin (4.3), MECE (4.4), RAPID roles (4.9). OODA, Test it first, Stage-Gate and Crisis mode follow after launch. **Framework names first** in the chooser, with a plain line under each. Chooser shows **top 3 + "See all models"**. RAPID approver objection **blocks Decide now** until withdrawn or overridden on the record. See `product-foundation.md` section 0.

## 1. Summary

Clarvy already thinks with one model: frame the options, score them, run five independent minds (Analyst, Red Team, Values, Investigator, Bias Checker), do the math, then the Judge makes one call. That is close to **WRAP plus the one-way / two-way door test**.

The proposal:

1. Turn each framework in the document into a **complete thinking model**: when to use it, its full steps, what Clarvy asks, how the engine runs it, and what the answer looks like.
2. Add a short **Triage** step that reads the question and **recommends one model**, with a one-line reason.
3. Let the customer **keep the recommendation or choose another** (solo and in rooms).
4. Keep a set of **safeguards on for every model** (pre-mortem, devil's advocate, tripwires, bias checks), so no model makes Clarvy less careful.

What the customer sees, solo:

> **How should Clarvy think about this?**
> Recommended: **Careful call (WRAP)**. It's hard to undo and you only listed two options.
> [Keep it] [Choose another ▾]

And in a room, the owner picks the model at setup (step 1, after the question), with the same recommendation.

## 2. Fact check of the source document

The document is solid. A few points to correct before any of it goes into prompts or marketing copy:

| Claim in the doc | Correction |
| --- | --- |
| Cynefin "developed at IBM", four domains | Created by Dave Snowden (1999, IBM Global Services, later Cognitive Edge). It has **five** domains: Clear (formerly "Simple"), Complicated, Complex, Chaotic, and **Confused** (formerly "Disorder"), the state of not knowing which domain you are in. |
| Type 2 decisions use "the 80% rule" | Bezos's 2016 shareholder letter says most decisions should be made with about **70%** of the information you wish you had. (Colin Powell's version is 40 to 70%.) Use 70%. |
| RAPID "used by Bain, Apple, Google" | RAPID is Bain's (Rogers and Blenko, "Who Has the D?", HBR 2006). Apple and Google using it is not well sourced; drop those names. |
| Tenth Man Rule "popularized by Israeli military intelligence" | After the 1973 Yom Kippur War, Israeli military intelligence did set up a devil's-advocate unit. The "tenth man" phrasing was popularized by the film *World War Z* (2013). Say "inspired by". |
| "Pre-mortem" | Gary Klein, HBR 2007. Correct as described. |
| Stage-Gate | Robert G. Cooper (1980s). Correct; "Stage-Gate" is a registered trademark, so we call ours "Big bet in stages". |
| Incident Command System | Born from 1970s California wildfire response (FIRESCOPE), now standard in US emergency services. Correct in spirit. |
| PRFAQ and the 6-page memo | Two related Amazon practices: the narrative memo (read in silence at the start of the meeting, often 20 to 30 minutes) and the PRFAQ ("working backwards" press release plus FAQ). Correct in spirit. |
| MECE | Barbara Minto at McKinsey. Correct. |

## 3. How models plug into the engine

A model is **data, not new code paths**. Each one is a config object the engine reads:

```js
{
  id: "wrap",
  name: { en: "Careful call", ar: "قرار متأنٍّ" },
  family: "Framework name shown small: WRAP (Heath brothers)",
  bestFor: "...",                    // one line for the chooser
  signals: { door: "one-way", stakes: ["medium","high"], options: "few" },  // used by Triage
  asks: [...],                       // extra questions for the person (0 to 2, all optional)
  frame: "extra instructions for the Frame step",
  minds: { analyst: "...", red: "...", values: "...", investigator: "...", framing: "...", extra: [...] },
  judge: "how the Judge weighs things under this model",
  output: ["call", "check_first", "tripwires", ...]   // which result cards to show, in order
}
```

The pipeline becomes:

```
Reader (files)  →  Triage (recommend a model)  →  [person keeps or changes it]
→  Frame (shaped by the model)  →  Scout (live facts, if needed)
→  Minds in parallel (the model turns minds on, off, or retunes them; may add one)
→  Math in code (same computeMath / computeRisk; some models add a step)
→  Judge (model's rubric)  →  Result cards (model's layout)
```

**Triage costs one small model call.** To keep the composer fast, Triage runs while the person is still typing details, and its recommendation appears before they tap Ask. If they never open the chooser, the recommendation is used.

**Always-on safeguards** (every model, because the document's bias section applies to all of them):

| Safeguard | Where it lives today | Rule |
| --- | --- | --- |
| Pre-mortem | Red Team mind | Every option gets a "it failed a year from now, why?" |
| Devil's advocate ("tenth man") | Red Team mind | If all minds favour the same option, the Red Team must make the strongest case against it. |
| Reality test | Investigator | Ask "what must be true for this to fail?", not "will it work?" |
| Tripwires | **New** card | Every one-way-door call ends with 1 to 3 measurable "stop or rethink if..." signals and a date. In rooms, tripwires are checked at the review date. |
| Gain vs loss framing, sunk cost, status quo, anchoring | Bias Checker | Unchanged. |
| Distance (10/10/10, best friend test) | Values mind | Unchanged. |

## 4. The model library

Ten models, grouped so the chooser stays simple. The first is today's engine.

### 4.0 Clarvy Standard (today's engine, kept as the fallback)

- **Best for:** most everyday decisions when nothing else clearly fits.
- **Steps:** Frame → five minds → math → Judge (as now).
- **Recommended when:** Triage has no strong signal.

### 4.1 Quick call (Type 2 / two-way door, the 70% rule)

- **Best for:** reversible, low-cost choices: a pricing test, a hire for a short contract, which tool to try, where to eat with friends.
- **Recommended when:** door is two-way, stakes low or medium, a wrong choice can be undone within weeks.
- **Steps (complete):**
  1. Confirm it is reversible: what does undoing it cost, and how fast?
  2. Pick the option with the best expected value using what is known now (aim for about 70% of the information).
  3. Set the undo point: the date or signal at which you will look again.
  4. Act today.
- **Clarvy asks:** nothing extra.
- **Engine:** Frame + Analyst + Judge only (Red Team in short form). About 3 calls instead of 8, so answers come back fast.
- **Output:** the call, "how to undo it if wrong", "look again on [date] or if [signal]".
- **Watch-out:** Triage must not send one-way doors here. If the Frame finds the door is one-way after all, Clarvy switches up to the Careful call and says so.

### 4.2 Careful call (WRAP, Chip and Dan Heath, *Decisive*, 2013)

- **Best for:** big, hard-to-undo personal and business decisions: a job change, a move, a partnership, a large purchase.
- **Recommended when:** door is one-way, stakes medium or high, few options listed (especially a yes/no "whether or not" question).
- **Steps (complete; the four villains it fights are narrow framing, confirmation bias, short-term emotion and overconfidence):**
  1. **Widen your options.**
     - *Vanishing options test:* "If none of your current options were possible, what would you do?"
     - *Multitrack:* can you do two options at once, or in sequence?
     - *Find someone who solved it:* how do others in this position usually handle it?
  2. **Reality-test your assumptions.**
     - *Consider the opposite:* "What must be true for each option to fail?"
     - *Zoom out:* base rates for people in this situation.
     - *Zoom in:* the closest real example.
     - *Ooch:* a small, cheap experiment before committing.
  3. **Attain distance.**
     - *10/10/10:* how will this feel in 10 minutes, 10 months, 10 years?
     - *Best friend test:* "What would you tell your best friend to do?"
     - *Core priorities:* which option honours what matters most to you?
  4. **Prepare to be wrong.**
     - *Bookend the future:* best and worst realistic case.
     - *Pre-mortem.*
     - *Tripwires.*
- **Clarvy asks (optional):** "What's the one thing that matters most to you here?"
- **Engine:** today's five minds, retuned:
  - **Frame** must add at least one widened option (vanishing-options test) and flag "whether or not" questions.
  - **Investigator** proposes one ooch (a cheap test).
  - **Values** adds the best-friend test.
  - **Judge** must produce tripwires.
- **Output:** the call, the widened option Clarvy added, "test it small first" (the ooch), 10/10/10, tripwires.

### 4.3 Make sense first (Cynefin, Dave Snowden)

- **Best for:** messy situations where it isn't clear what kind of problem it is: a team falling apart, a market behaving strangely, a new regulation with unclear effects.
- **Recommended when:** many unknowns, no clear options yet, or the person writes "I don't know what to do" rather than "A or B?".
- **Steps (complete):**
  1. **Place the situation in a domain**, with the evidence for it:
     - **Clear:** cause and effect are obvious; best practice exists. *Sense → categorise → respond.*
     - **Complicated:** cause and effect can be worked out by analysis or experts. *Sense → analyse → respond.*
     - **Complex:** cause and effect only make sense in hindsight; no expert has the answer. *Probe → sense → respond.*
     - **Chaotic:** no clear cause and effect, and things are getting worse fast. *Act → sense → respond.*
     - **Confused:** not yet clear which domain applies. Break the situation into parts and place each part.
  2. **Respond the way that domain needs:**
     - Clear → apply the known best practice (Clarvy names it).
     - Complicated → expert analysis: hand off to **Break it down (MECE)** and the scored engine.
     - Complex → don't pick a big option yet. Design 2 or 3 safe-to-fail experiments: hand off to **Test it first**.
     - Chaotic → stabilise first: hand off to **Crisis mode**.
  3. **Watch for drift** between domains (the "cliff": treating complex as clear can tip into chaos). Name the signal that the situation has moved.
- **Clarvy asks:** nothing extra; it may ask one clarifying question if the domain is a toss-up.
- **Engine:** a new **Sensemaker** mind runs first and outputs the domain plus evidence. The rest of the pipeline is chosen by the domain.
- **Output:** a domain card ("This looks Complex, because..."), then the chosen route's cards. A room shows the domain to everyone, because disagreement about the domain is itself useful.

### 4.4 Break it down (MECE issue tree, Barbara Minto / McKinsey)

- **Best for:** big analytical questions with many moving parts: "Should we expand to Egypt?", "Why are sales falling?".
- **Recommended when:** the question is broad, has sub-questions, and the person attached data. Also the Complicated route of Cynefin.
- **Steps (complete):**
  1. Restate the question as one precise, answerable question (the "governing question").
  2. Build an **issue tree**: split it into 3 to 5 branches that don't overlap (mutually exclusive) and leave nothing out (collectively exhaustive). Example: market attractiveness / our ability to win / economics / risks.
  3. For each branch, write a **hypothesis** ("Egypt's market is large enough") and what evidence would prove or disprove it.
  4. Answer each branch with facts (files, live search, the Analyst).
  5. **Synthesise top-down** (Minto's pyramid): the answer first, then the 3 supporting reasons, then the evidence.
- **Clarvy asks:** nothing extra.
- **Engine:** Frame becomes an issue-tree builder. Scout queries are generated **per branch**. The Analyst scores options per branch. A code check flags overlapping or missing branches. The Judge writes pyramid style.
- **Output:** the call, the issue tree with a verdict on each branch (✓ / ✗ / unknown), evidence per branch.

### 4.5 Move fast (OODA loop, John Boyd)

- **Best for:** fast-moving or competitive situations where speed matters more than perfection: a competitor's price cut, a negotiation, a market shock.
- **Recommended when:** the question mentions a competitor, a deadline in days, or a situation that is changing.
- **Steps (complete):**
  1. **Observe:** what is actually happening, from live facts and the person's notes, not assumptions.
  2. **Orient:** the most important step. Check the mental models and biases colouring the picture (Boyd's list: culture, past experience, inherited assumptions, new information). Ask: "What would we believe if we were the competitor?"
  3. **Decide:** pick a course of action as a hypothesis to test, not a final verdict.
  4. **Act:** do it fast, then loop back to Observe. Name what to watch so the next loop is faster.
  5. **Tempo:** the aim is to loop faster than the other side, so prefer moves that are quick to make and that create options.
- **Clarvy asks (optional):** "Who are you up against, and how fast are they moving?"
- **Engine:**
  - **Scout** always runs (live facts are essential here).
  - A new **Opponent** mind models what the other side will likely do next.
  - The **Bias Checker** becomes the "Orient" check.
  - The **Judge** gives a move plus "watch for" signals. Values and Investigator are off, to save time.
- **Output:** the move now, what the other side will probably do, the signals to watch, "run Clarvy again when [signal]". In rooms, an OODA room can be re-run every few days (a loop counter on the room).

### 4.6 Test it first (Dual-track discovery / Cynefin's "probe")

- **Best for:** new products, new markets, anything where nobody can know the answer without trying.
- **Recommended when:** high uncertainty, low cost to experiment, and the options are ideas rather than fixed choices. Also the Complex route of Cynefin.
- **Steps (complete):**
  1. Turn each option into a **hypothesis** ("Customers will pay 20% more for same-day delivery").
  2. Design the **smallest test** for each: who, what, how long, cost (aim for days, not months).
  3. Set **success and kill thresholds** before running it ("go if 30%+ sign up; drop if under 10%").
  4. Run the tests in parallel where possible.
  5. Decide with the results: scale the winner, kill the rest. This is the **delivery track**.
- **Clarvy asks (optional):** "How much time and money can you spend testing?"
- **Engine:** the Investigator leads (it already does value-of-information). The Analyst estimates odds of each hypothesis. The Judge outputs a test plan instead of a final pick. In rooms, the result date becomes the review date, and the room re-decides with real data.
- **Output:** the test plan (hypothesis, test, cost, go/kill line), what to do while waiting, the "decide on [date]" step.

### 4.7 Big bet in stages (Stage-Gate, Robert Cooper)

- **Best for:** large, irreversible investments: a factory, an acquisition, a new branch, a big hire.
- **Recommended when:** one-way door, high stakes, large money, and the decision can be split into phases.
- **Steps (complete):**
  1. **Scope:** concept and rough numbers.
  2. **Gate 1, reality test:** the Red Team attacks the assumptions. Go to deep research, or kill.
  3. **Build the case:** detailed plan and budget; **set the tripwires** (the metrics that would stop it later).
  4. **Gate 2, point of no return:** the decision-maker checks the plan against the tripwires. Launch, or kill.
  5. **Launch, then review** 6 to 12 months later: were the tripwires crossed, and was the expected return met? Then a short, blameless look at how the decision was made.
- **Clarvy asks:** "Roughly how much is at stake?" and "Can it be split into phases?"
- **Engine:** Clarvy runs Gate 1 now (Red Team plus Analyst on the assumptions) and returns **Go to the next stage / Kill / Fix first**, not a final yes. The Judge must write the tripwires and the Gate 2 checklist.
- **Rooms:** the room keeps a **stage** (Gate 1 → Build → Gate 2 → Launched → Reviewed). Each gate is a decision round with its own inputs and verdict. This fits the review loop in the Rooms spec.
- **Output:** gate verdict, assumptions that must hold, what to prepare for the next gate, tripwires.

### 4.8 Crisis mode (Incident Command / Cynefin's "chaotic")

- **Best for:** something is going wrong right now: a data breach, a PR storm, a supplier collapse, a family emergency.
- **Recommended when:** the question is urgent ("now", "today", "we've been hacked"), harm is ongoing, and Cynefin would say Chaotic.
- **Steps (complete):**
  1. **Stop the bleeding:** the first action in the next hour, even before the cause is understood.
  2. **Declare severity:** how bad, using a simple scale (Sev 1 / 2 / 3). This tells everyone the normal approvals are paused.
  3. **Name one incident commander:** one person has the call until it's stable. Name who does what (communications, fixes, liaison).
  4. **Stabilise, then understand:** once it stops getting worse, the situation is Complicated again, and normal analysis resumes.
  5. **Blameless post-mortem:** what happened, why the system allowed it, what rule changes so it can't happen again.
- **Clarvy asks:** nothing. Speed first.
- **Engine:** **one fast call** (no five minds) for steps 1 to 3, with an action list. A follow-up "it's stable now" button runs the post-mortem template. Rooms switch to "commander decides" (no waiting for inputs; members get the plan, not a vote).
- **Output:** "Do this in the next hour", severity, roles, the comms line to send, "when it's stable" next steps.
- **Watch-out:** for anything involving physical danger, health or legal emergencies, Clarvy first points to emergency services or a professional, and doesn't replace them.

### 4.9 Who decides (RAPID, Bain & Company)

- **Best for:** organisational decisions that stall because nobody knows who has the final say.
- **Recommended when:** in a room, more than 4 people, or the question mentions approvals, legal, board or departments.
- **Steps (complete):**
  1. **Recommend (R):** one person (or team) gathers input and proposes the decision.
  2. **Agree (A):** the few who must sign off and can **veto** (legal, compliance, a key funder). Keep this list short; every A slows things down.
  3. **Perform (P):** who will carry it out. Their input on feasibility matters.
  4. **Input (I):** experts who give facts and views. **No vote, no veto.**
  5. **Decide (D):** **one** person with the final call, who commits the organisation.
  6. **Common failures to check for:** two people think they have the D; too many As; Is treated as vetoes; the P never consulted.
- **Clarvy asks (owner):** who plays each role. Clarvy suggests a split.
- **Engine:** the decision runs as normal (any model above). RAPID adds a **role chart** and changes the Judge's write-up: the verdict goes to the D as a **recommendation**, and any A objection is shown as a blocker.
- **Rooms fit (this is where it shines):**

  | RAPID | Room role today | Change needed |
  | --- | --- | --- |
  | D | owner | none |
  | R | owner, or a member the owner names | new optional role "recommender" |
  | A | none | new role "approver": can object with a veto; a veto blocks Decide now until resolved or overridden on the record |
  | I | member | none (members already advise without a vote) |
  | P | none | new role "doer": sees the plan and the first steps; asked "can we deliver this?" |

- **Format option, the decision memo (Amazon-style):** the R writes a short narrative (or Clarvy drafts it from the analysis): the proposal, a mock announcement, FAQ of objections. Members read it in the room before giving input. The memo is the PDF export already in the Rooms spec.

## 5. Recommending a model (Triage)

Triage reads the question, details, files and room type, then returns:

```json
{"model":"wrap","why":"It's hard to undo and you only listed two options.","alternatives":["stagegate","standard"],
 "signals":{"door":"one-way","stakes":"high","urgency":"low","uncertainty":"medium","options":2,"group":false,"competitive":false}}
```

**Rules, applied in order (first match wins), so recommendations are predictable:**

1. Urgent and harm is ongoing → **Crisis mode**
2. No clear options, or "what's going on?" → **Make sense first**
3. Competitor, opponent or a deadline of days → **Move fast**
4. One-way door, high stakes, can be phased → **Big bet in stages**
5. Ideas not choices, cheap to test → **Test it first**
6. Broad analytical question with sub-parts or data → **Break it down**
7. One-way door, medium or high stakes → **Careful call**
8. Two-way door, low or medium stakes → **Quick call**
9. Otherwise → **Clarvy Standard**

**RAPID** is not in this list. It's offered as an add-on in rooms with 4+ members or when approvals are mentioned ("Add roles: who decides, who approves").

The model call only extracts the signals; the code applies the rules. That way the recommendation is explainable, testable, and cheap.

**The customer always sees why**, and can switch with one tap. If the Frame later contradicts Triage (for example, the "quick" decision turns out to be one-way), Clarvy switches up and says so on the result.

## 6. What changes in the product

**Solo (main page):**
- The composer gets a small line under the question: "Clarvy will think about this as a **Careful call** · change".
- The result shows the model used, and "Think about it another way" offers the alternatives (re-runs with a different model).
- History stores the model used.

**Rooms:**
- **Setup:** a new step after the question, "How should we decide?", with the recommendation preselected.
- The model sets the members' steps (for example, Test it first asks members for their go/kill line; Move fast asks what they've seen the other side do).
- **Verdict:** shows the model's cards.
- **Big bet in stages** and **Move fast** rooms can run more than one round (gates, loops). Review dates become gate dates.
- **RAPID roles** need a small database change (two new roles and a veto). That's the only schema change in this plan.

**Engine (code):**
- `models.js`: the ten model configs, shared by the browser engine and the server (like `rooms/math.js`).
- `triage`: one prompt plus the rules in code.
- Prompts gain a `model` block; three new minds (Sensemaker, Opponent, and Crisis as a single-call path).
- New result cards: tripwires, test plan, issue tree, domain, gate, incident plan, role chart.
- Arabic: every model name, question and card in both languages, written natively.

**Cost per decision (model calls):** Quick 3 · Crisis 1 to 2 · Standard, WRAP, OODA 8 to 9 · MECE 9 to 11 (search per branch) · Cynefin 1 plus its route · Stage-Gate 6 to 7 per gate · Triage adds 1 small call to all of them.

**Suggested build order:**
1. Triage, chooser UI, Quick call and Careful call (largest share of real questions).
2. Always-on tripwires card.
3. Make sense first, Break it down, Test it first.
4. Move fast and Crisis mode.
5. Big bet in stages (multi-round rooms) and RAPID roles (schema change).

## 7. Open questions for you

1. **Names:** plain names ("Careful call") with the framework underneath ("WRAP"), or framework names first? Plain names are easier for most people; framework names signal rigour to executives. The draft above uses plain names with the framework shown small.
2. **How many models in the chooser:** show all ten, or the top 3 for this question plus "More"? (Recommendation: top 3 plus More.)
3. **Should Triage be skippable for speed** (Quick call by default unless the question looks big)?
4. **Crisis mode:** should it exist in the consumer app at all, or only in rooms (teams)? It changes Clarvy's tone a lot.
5. **RAPID veto:** should an approver's objection block Decide now, or only be shown loudly on the verdict?
6. **Stage-Gate and OODA rooms:** OK to make rooms multi-round (a room can have several decisions over time)?
7. Anything from your own notes that should become an eleventh model (for example a negotiation model, or a hiring model)?
