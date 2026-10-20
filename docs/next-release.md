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

## Later (after launch)
Decision styles (majority vote, everyone agrees) · Slack sharing · Stated → Simulated → Outcome stories on the landing page (not yet decided; needs real reviewed rooms) · automatic reminders, email first, then WhatsApp · WhatsApp number (Kapso) · bot check (Turnstile) · Google and Microsoft sign-in · native Arabic review · contact email and operator name on privacy and terms.

## Already covered (from the New Features doc)
One decision per room with a named owner · start with the question · decision record (in the report) · neutral summary (disagreement map) · traceable reasoning (dated facts, why) · Analyst then Judge pipeline · team and personal reports · calendar (plan) · WhatsApp sharing (1.9).
