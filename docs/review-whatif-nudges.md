# Review, Track Record, What If and Nudges: Build Plan

Status: decisions recorded 2026-10-19 (section 0) · Validated against the code (section 6)
Source: the Cloverpop review (decision intelligence, "decision as the unit of work"). It fills the two gaps in `product-foundation.md` section 5 (**Check** and **Learn**) and adds a "what if" panel and nudges for stuck rooms.

## 0. Decisions (2026-10-19)

All eight were decided by the user (D2, D4, D6 and D7 on 2026-10-20). Build order is now set by `docs/next-release.md`: nudges and Decide by in release 1, the rest in release 2, plus an owner-only what-if re-run that uses a Decide credit.

| # | Topic | Proposed | Alternatives |
| --- | --- | --- | --- |
| D1 | Who rates the outcome | **Decided: owner logs it; members rate privately (1-5); the room sees the average and the spread** | Owner only (the table today) |
| D2 | Name of the score | **Decided: "Track record"** (Cloverpop uses "Decision IQ"; we don't borrow their name) | "Decision score", "Call record" |
| D3 | What the what-if panel changes | **Decided: weights, risk mix and the Analyst's option scores (v1)** | Weights and risk only |
| D4 | Can a what-if reopen a settled call | **Decided: no.** It's a viewer; the owner can "Reopen the room" with a reason on the record | Owner can switch the call from the panel |
| D5 | Stuck rooms, before a sender exists | **Decided: in-app "Needs attention" + a one-tap WhatsApp/email reminder the owner sends from their phone** | Wait for the sender |
| D6 | Automatic sender, later | **Decided: email first (Resend on tejarra.com), WhatsApp second** (needs Meta business approval and templates) | WhatsApp first |
| D7 | "Decide by" date | **Decided: optional field in setup, default 7 days** | Infer from the review date |
| D8 | Build order | **Decided: 1 Review → 2 Track record → 3 What if → 4 Nudges** | What if first (more visible in demos) |

## 1. Review screen (closes the Check step)

**What exists:** `rooms.review_date`, room status `reviewed`, tables `outcomes` (what happened, rating 1-5, lessons) and `outcome_comments`, with row-level security. **No screen uses them.**

**Build:**
1. On or after the review date, the room shows a yellow band: "Time to review: how did the call turn out?"
2. Owner form: what happened (text), rating 1-5 (1 the call was wrong, 5 it was right), lessons, and the plan's status pulled in (done / blocked counts, tripwires that fired).
3. Each member (D1): a private 1-5 rating and an optional note, stored like their inputs (author-only). The room sees the average, the spread and pooled notes, never who said what.
4. Saving moves the room to `reviewed` (new security-definer function `log_review`, owner only, only from `decided`).
5. The report gains an "Outcome" section; the dashboard gets a "Due for review" group.
6. "Review again in 3 / 6 months" sets a new review date; each review is kept (outcomes becomes one row per review, not one per room).

## 2. Track record (closes the Learn step)

A page per owner and per organisation, from reviewed rooms only. Shown once there are **3 or more** reviewed rooms (fewer is noise).

| Measure | How it's worked out |
| --- | --- |
| Calls that held up | Share of reviewed rooms rated 4 or 5 |
| Confidence that matched | Of High-confidence calls, the share that held up (same for Medium and Low): our calibration |
| Accepted vs overridden | Hold-up rate when the owner accepted the recommended call vs when they overrode it |
| Time to decide | Median days from opening the room to the settled call |
| Voices heard | Median share of invited members who answered |
| Follow-through | Share of plan actions done by the review date |

Plain read-out on top, e.g. "8 of your last 10 calls held up. High-confidence calls held up 9 times in 10." Later: feed the record into the Judge ("this group's overrides held up more often than the recommendations") with a clear note.

## 3. What if panel

**Goal:** on the verdict, anyone in the room moves a few sliders and watches the ranking change, with no AI call and no cost.

**Why it can be exact and still private:** the group score is `0.45 × fit + 0.25 × certainty + 3 × gut share`, averaged over members. Fit is linear in the weights and certainty only depends on risk appetite, so the group score can be rebuilt from **aggregates only**: the average weights, the risk mix and the gut-pick tally. No one's private answer is needed (section 6, check 3).

**Controls (D3):**
- One slider per criterion (starts at the room's average weight).
- Risk mix: more cautious / as answered / bolder.
- "Ignore gut picks" toggle (numbers only).
- **Option scores (D3):** tap any option's score on a criterion (0-10, from the Analyst) and change it, e.g. "What if B's cost score is 7, not 4?". Edited cells are marked, with the Analyst's value and its reason beside them, and "Reset to the Analyst" undoes all edits. Best/likely/worst outcomes stay as the Analyst set them in v1.

**Output:** the ranked options with bars, a line on what changed ("Raising Cost above 40% puts Option B first"), and **"What would flip it"**: the smallest weight change that changes the top option, computed in code. This line also goes on the verdict card by default.

**Rules:**
- Label it "The numbers" so it's never confused with the recommended call, which also weighs facts, objections and role asks (D4).
- Members can save a scenario to the room ("Sara's scenario: cost at 50%"), shown pooled and unnamed like other input; the owner can bring one into a reopened room.
- Shared code in `public/rooms/math.js` (`groupFromAggregates`, `flipPoint`) so the server, the demo and the panel agree.

## 4. Stuck-room nudges

**Stuck means:**
- Open and past "decide by" (D7) with fewer answers than the quorum.
- Quorum reached but no Decide now after 2 days.
- `decide_error` set (the analysis failed twice).
- Decided but members haven't signed off after 3 days.
- Plan items overdue, or the review date passed with no review.

**v1, no sender (D5):** a "Needs attention" strip on Your rooms and in the room, each with one action: **Send a reminder**. It opens WhatsApp (`wa.me` share link) or the mail app with a short prefilled message and the room link; the owner sends it themselves. The message never names who hasn't answered to the group; the owner sees the count only.

**v2, with a sender (D6):** a daily job in `server.js` sends the same reminders, at most one per person per room per 2 days, with an unsubscribe link and quiet hours by time zone.

## 5. Data changes (one migration)

- `rooms.decide_by date` (D7).
- `outcomes`: new primary key `id`, `review_no`; keep `room_id` indexed.
- New `review_ratings (room_id, user_id, review_no, rating, note)`, readable only by the author; `review_summary(rid)` returns average, spread and pooled notes.
- New `whatif_scenarios (room_id, user_id, weights jsonb, risk_shift text, created_at)`, author-only, plus a pooled read function.
- New `nudges_sent (room_id, user_id, kind, sent_at)` for v2.
- `log_review(rid, …)` and `reopen_room(rid, reason)`, both owner-only security-definer functions; lock `outcomes` inserts to rooms in `decided` or `reviewed`.
- Decide writes `outcomes.whatif`: exact average weights (unrounded), the risk mix and the gut tally, so the panel matches the server exactly.
- Run `supabase/tests/test_rls.py` with new cases, then apply through the Supabase connector (ask first) and re-run its advisors.

## 6. Validation (done 2026-10-19)

| # | Check | Result |
| --- | --- | --- |
| 1 | Review tables exist? | Yes: `outcomes` and `outcome_comments` with RLS. No screen, no function moves a room to `reviewed`. |
| 2 | Outcome insert is guarded by room status? | **No.** The owner could log an outcome before deciding. Fixed in section 5. |
| 3 | Can the group ranking be rebuilt from aggregates the browser already has? | Tested on 500 random rooms (2-10 members, 3 options, 4 criteria) with the real `math.js`: max error **0.099** points, top option different in **10 of 500** (near-ties), caused by rounding of averages. Fix: store exact aggregates at Decide (section 5); old rooms show "close call" when the top two are within 0.2. |
| 4 | Is anything private exposed by the panel? | No: it uses only `disagreement_map` and `outcomes`, which members can already read. Saved scenarios are author-only. |
| 5 | Can nudges work today? | Only owner-sent (v1). No email or WhatsApp sender in the server; Supabase email is limited to the team. |
| 6 | Does a "decide by" exist? | No; only `quorum` and `review_date`. Added in section 5. |
| 7 | Small-room privacy on reviews | With 2 members, an average plus one member's own rating reveals the other. Show the spread only from 3 raters; with 2, show the average alone. |
| 8 | Track record with few rooms | Under 3 reviewed rooms the rates mislead; hidden until then (section 2). |
| 8b | Do edited option scores keep it exact and private? | Yes: fit stays linear in the scores, so the rebuild is still exact; scores are already shared with the room. Edited scores never reach the Judge unless the owner reopens the room. |
| 9 | Fit with values | "Decide, then check" (value 5) and "Every voice counts" (value 2) are served directly; nothing trains on customer data. |

## 7. Not now

- Booking or calendar holds (trip features moved to the consumer product).
- Benchmarks against other organisations: needs many customers and consent.
- (Moved to release 2: the owner can re-run on a what-if, using a Decide credit; it never changes a settled call.)
