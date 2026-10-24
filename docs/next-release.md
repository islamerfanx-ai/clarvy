# The next two releases

Status: decided by the owner 2026-10-20, step by step. Nothing below is live yet. Sources: `product-foundation.md` section 0, `docs/review-whatif-nudges.md`, and the "New Features" doc (Cloverpop and Aaru research).

How we ship: build a whole release, show it once in the demo with screenshots, then ask before the database changes and the push.

## Release 1: before the call

### Already built, waiting to ship
| # | Feature | What changes |
| --- | --- | --- |
| 1.1 | Thinking screen | While the room decides, one live line with a spark shows the stage, finished stages tick off, a segmented bar fills. Built (7843034, 6bd1406). |
| 1.2 | Question check fix | Rephrasings never contain blanks like "[timeframe]". |

### Room setup, from the printed review
| # | Screen | What you'll see |
| --- | --- | --- |
| 1.3 | First screen | Name, email and organisation type together, shown for every new room; returning people just confirm. |
| 1.4 | The question | Pressing Next corrects it ("Corrected by AI", with Undo). Three rephrasings stay as choices. "Check my question" gets a one-line description. |
| 1.5 | Starter questions | Example questions for the organisation type, in English and Arabic, one tap to use. |
| 1.6 | Background research | Starts on Next from the question. The world brief is ready as tickable facts by the last step. Counts against the daily limit. |
| 1.7 | Options and what to weigh | One page. Options pre-filled from the question (when, how, who); weights as an editable list. |
| 1.8 | How should we decide? | Says plainly why the model is recommended. RAPID keeps its name with a short explanation. |
| 1.9 | Who's in the room | People one by one (name, role, email or phone), an address book of saved contacts, no per-link limit, one personal link each, sent with one tap by WhatsApp or email. |
| 1.10 | Asks per person | Suggested asks are tick boxes, still editable. |
| 1.11 | Decide by | Optional date, 7 days by default. |
| 1.12 | Files | "Import files" and "Help me export". |
| 1.13 | Moved out of setup | Review date is asked after the decision, next to the plan. Report choice is made when the report is made. |

### Members, the room and Your rooms
| # | Where | What you'll see |
| --- | --- | --- |
| 1.14 | Personal link | Opens on "Hi Kenji" with details filled in. |
| 1.15 | Ratings | An optional folded comment under each rating, read pooled and unnamed. |
| 1.16 | Adding people later | The owner adds people from the room until the call is made. Old rooms keep their role links. |
| 1.17 | Needs attention | Stuck rooms (past Decide by, quorum but no Decide now, failed analysis, no sign-offs after 3 days) show a strip with "Send a reminder" that opens WhatsApp or mail with a ready message. The group never sees who hasn't answered. |
| 1.18 | Search | A search box on Your rooms: question, options, decision. Only rooms you're in. |

### Database changes (asked before applying)
`rooms.decide_stage` (written), `rooms.decide_by`, `room_invites` (one row per person, owner-only, safe preview for the link), `contacts` (owner-only), `inputs.comments` (author-only). RLS tests first, advisors after.

## Release 2: after the call

| # | Feature | What you'll see |
| --- | --- | --- |
| 2.1 | Stakeholder reactions | The analysis role-plays 3 to 5 outsiders (customer, investor, regulator, competitor, picked for the organisation type) and shows how each would react to each option. A new verdict card; one extra AI step. |
| 2.2 | Said vs would do | Code, no AI: flags when the group's weights point one way and its gut picks another. |
| 2.3 | Value line | "Decided in 2 days · 6 people · 4 options weighed" on the verdict, report and share card. |
| 2.4 | The numbers (what if) | Sliders for each weight, the risk mix, ignore gut picks, edit the Analyst's option scores. Shows "What would flip it". Free, no AI, from aggregates only. |
| 2.5 | What-if re-run | Owner only: type a condition ("prices up 20%") and the analysis runs again. Uses a Decide credit. The result is shown beside the call and never changes a settled call. |
| 2.6 | Reopen the room | The only way to change a settled call; the reason is recorded. |
| 2.7 | Review | On the review date: the owner logs what happened; members rate privately 1-5; the room sees the average (and spread from 3 raters). Can repeat at 3 or 6 months. |
| 2.8 | Track record | After 3 reviewed rooms: calls that held up, confidence that matched, accepted vs overridden, time to decide, voices heard, follow-through. |

Database: `outcomes` per review, `review_ratings`, `whatif_scenarios`, `log_review`, `reopen_room`, exact aggregates stored at Decide.

## Release 2: validation against the code (2026-10-21)

Checked each feature against the database and server, with probes on a test copy of the schema.

| # | Check | Result |
| --- | --- | --- |
| V0 | Can a signed-in person change a room's status directly? | **Yes, and it's live.** The owner's "edit room" permission covers `status` and the `decide_*` columns. A trial account can create a room straight in "deciding", or flip any of its rooms to "deciding", and the worker runs a full analysis: no quorum, no daily limit of 5, real AI cost. An owner can also move a decided room back to open, or mark any room "reviewed". Fix: a guard so only the server and the database's own functions change status and the decide columns. Needed now, before release 2. |
| V1 | 2.1 Reactions: room in the pipeline? | Yes. One more step between facts and the Judge, about 10 to 15 s; the worker allows 8 minutes per run. The thinking-stage list needs the new name. Rooms with no organisation type (made before release 1) get a general panel. |
| V2 | 2.2 Said vs do: data there? | Yes, plain code. Overlaps with the existing "most of the room leaned to X" line (gut picks vs the call). Two similar lines would confuse; better to show both comparisons in one place. Gut pick is optional, so count only those who picked. |
| V3 | 2.3 Value line: data there? | Yes (room created, decided, answers, options). The room page needs to load the room's start date. |
| V4 | 2.4 The numbers | Validated 2026-10-19 on 500 rooms; exact totals must be saved at Decide. Option scores are already visible to members, so editing them in the panel reveals nothing new. |
| V5 | 2.5 What-if re-run: can it reuse Decide? | **Not as is.** The worker only picks up rooms in "deciding", and a decided room isn't; and every screen reads the newest analysis as the call, so a what-if saved there would replace the real call. Needs its own table and its own job claim. "Credit returned if it fails" needs a refund in the daily counter, which doesn't exist yet. |
| V6 | 2.6 Reopen | Inputs reopen for editing automatically once the room is open. Sign-offs allow one per person per room, so old ones must move to history first; same for open objections. A new Decide becomes the newest analysis, so the old call stays as history without extra work. |
| V7 | 2.7 Review | Today the owner can log an outcome on a room that isn't decided (no status check), and only one review per room fits. Both are in the planned database change. |
| V8 | 2.8 Track record per organisation | **Not meaningful yet.** Each owner has their own workspace, so "organisation" equals "owner" today. Per-owner works; per-organisation needs shared workspaces first. |
| V9 | Privacy, all features | Nothing new is exposed: reactions read shared fields only, sliders use group totals, review ratings are private with the spread from 3 raters. |

**Decided 2026-10-21 after validation:** V0 fixed and live the same day (migration 20261026000000_room_guard: only the server and `decide_verdict` change status and the decide columns; 188/188 tests; checked on the live database). Said vs do and "the room leaned elsewhere" become one combined block on the verdict. A failed what-if re-run still uses its Decide credit (no refund). Track record is per owner for now; per organisation waits for shared workspaces.

**Live 2026-10-22:** 2.4 The numbers (no saved scenarios yet) and 2.7 Review (migration 20261027000000_review). Still to build from release 2: 2.2 said vs do (combined block), 2.3 value line, 2.6 reopen, 2.8 track record (per owner); later with AI: 2.1 reactions, 2.5 what-if re-run.

## Later (after launch)
- **Talk space after the call (idea, 2026-10-24):** Ask the decision, follow-through threads, open team chat, reopen request; everyone posts; badge alerts. Mock-up first. See product-foundation section 0.
- **World library (decided 2026-10-24):** daily dated, sourced briefs per sector and customer country in the database, read by the Analyst and the world brief; automatic, shown on an admin tab; $20 a month to start. Not model training. See product-foundation section 0.
Decision styles (majority vote, everyone agrees) · Slack sharing · Stated → Simulated → Outcome stories on the landing page (not yet decided; needs real reviewed rooms) · automatic reminders, email first, then WhatsApp · WhatsApp number (Kapso) · bot check (Turnstile) · Google and Microsoft sign-in · native Arabic review · contact email and operator name on privacy and terms.

## Already covered (from the New Features doc)
One decision per room with a named owner · start with the question · decision record (in the report) · neutral summary (disagreement map) · traceable reasoning (dated facts, why) · Analyst then Judge pipeline · team and personal reports · calendar (plan) · WhatsApp sharing (1.9).
