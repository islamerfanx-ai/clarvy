# Tripwire Watch: Build Plan

Status: proposed 2026-10-26 · Nothing below is built · Decisions in section 0 are open for the owner
Why: big decisions are rare, so rooms go quiet after the call. Tripwire Watch keeps each decided room watching the world and calls the group back when a fact that should change the call actually moves. Sales line: **"Your decision keeps watching the world after the meeting ends."**

Builds on what exists: the Judge already writes 1 to 3 tripwires (`{signal, when}`, lib/rooms.js), the plan already drafts tripwire checks, `room_messages` already has `tripwire:<n>` threads, `reopen_room()` exists, and the nudge worker already sends email through Resend when `RESEND_API_KEY` is set.

## 0. Decisions (open)

| # | Topic | Proposed | Alternatives |
| --- | --- | --- | --- |
| T1 | Who gets alerts | **Owner always; members who signed off, opt-out per person** | Owner only |
| T2 | Who acts on an alert | **Owner only: "Still holds" (reason recorded) or "Reopen the room"**; members can comment in the tripwire thread | Any approver can reopen |
| T3 | Check frequency | **Weekly by default; daily for rooms marked fast-moving (Cynefin, crisis)** | Daily for all |
| T4 | Source of facts | **Web search per tripwire now; switch to the world library once it is live** | Wait for the world library |
| T5 | Watch period | **Until the review date, or 6 months if none** | Until the room is reviewed or archived |
| T6 | Limits | **Max 3 watched tripwires per room; checks count against a daily cost cap (env `WATCH_DAILY_USD`, default $5)** | Per-plan limits |
| T7 | Plans | **All paid plans; Free gets the tripwires shown but not watched** | All plans |
| T8 | Channel | **Email first (Resend), in-app always; WhatsApp when the Kapso number is live** | Wait for WhatsApp |

## 1. Make tripwires checkable

Today a tripwire is a sentence plus "when to check". The Judge keeps writing the sentence, and also fills a structured block from the dated facts it already has:

| Field | Example | Notes |
| --- | --- | --- |
| `signal` | Container freight Shanghai to Jeddah rises more than 20% | Unchanged, shown to people |
| `watch` | Container freight rate, Shanghai to Jeddah, US$ per 40ft | What to look up |
| `baseline` | 2400 | Number at decision time |
| `baseline_date`, `baseline_source` | 2026-10-26, URL | From the Analyst's dated facts |
| `direction` | up / down / event | `event` = a yes/no happening (a law passes, a competitor launches) |
| `threshold` | 0.20 | Relative change, or absolute value, or null for `event` |
| `checkable` | true / false | False when no public source can answer it (e.g. "team morale drops") |

Prompt change (Judge, line ~881): "For each tripwire, add `watch`, `baseline`, `baseline_date`, `baseline_source`, `direction`, `threshold`, `checkable`. Use only facts from the Analyst's dated list for the baseline. If no public source can measure it, set `checkable` false." Non-checkable tripwires stay as plan reminders on their `when` date, as today.

## 2. The watch job

A worker in server.js beside the decide and nudge workers (`startWatchWorker`), every hour:

1. Claim due checks: `watch_due()` returns watched tripwires whose `next_check_at` has passed, for decided rooms inside their watch period (T5), under the daily cost cap (T6).
2. For each: one focused web search plus a small classifier call. Input: `watch`, `baseline`, `direction`, `threshold`, the last reading. Output JSON: `status` (`fired` / `close` / `no_change` / `unknown`), `reading`, `reading_date`, `source_url`, one-sentence `summary`.
3. Rules in code, not the model:
   - `fired` only with a dated source newer than the baseline; otherwise downgrade to `unknown`.
   - `close` = at least 70% of the way to the threshold.
   - Two `unknown` in a row: mark the tripwire "can't be checked automatically" and tell the owner once.
4. Write the reading to `tripwire_checks`; set `next_check_at` (T3).
5. Alert only on a change of status to `close` or `fired` (never twice for the same status).

Every call is logged in `ai_usage` with its estimated cost, as today.

## 3. What people see

**Alert (email and in-app):**
> A tripwire on *Open a Dubai office* may have fired.
> Office rents in Dubai Marina are up 24% since 26 Oct (source, 3 Mar 2027). The room said to rethink if they rose more than 20%.
> [Still holds] [Reopen the room] [See the room]

**In the room, on the verdict's tripwire card:** a small status per tripwire ("Watching · last checked 2 days ago · no change", "Close", "Fired"), the reading history, and the existing `tripwire:<n>` thread for comments.

**Owner's choices (T2):**
- **Still holds:** a short reason, stored on the check and shown in the thread; watching continues.
- **Reopen the room:** calls `reopen_room()` with the reason prefilled ("Tripwire fired: …"), and adds the new reading to what everyone should know.

**Your rooms:** a "Watching" count per room, and fired tripwires join the Needs attention strip.

**Report and Track record:** "Tripwires watched: 3 · fired: 1 · reopened in time: 1".

## 4. Data changes (one migration)

- `tripwires (id, room_id, analysis_id, n, signal, watch, baseline numeric, baseline_date, baseline_source, direction, threshold numeric, checkable bool, watched bool, next_check_at, status, created_at)`, written by the server at Decide from the verdict.
- `tripwire_checks (id, tripwire_id, checked_at, status, reading numeric, reading_date, source_url, summary, cost_usd)`, server only.
- `tripwire_responses (id, tripwire_id, check_id, user_id, action 'holds'|'reopen', reason, created_at)`, owner writes.
- `profiles.watch_alerts bool default true` (T1 opt-out).
- Functions: `watch_due()` (server), `room_tripwires(rid)` (members read status, readings, responses), `respond_tripwire(tid, action, reason)` (owner only).
- RLS: room members read; only the server writes checks; only the owner responds. Run `supabase/tests/test_rls.py` with new cases, then apply through the Supabase connector (ask first) and re-run advisors.

## 5. Privacy and trust

- Uses only the verdict's shared fields. No private answers are read or sent.
- Strictly confidential rooms: the search query uses `watch` only, never the room question or names.
- A `fired` alert always carries a dated source; no source, no alarm.
- The owner, not the system, decides whether the call changes.

## 6. Cost

Per check: one search plus one small classifier call, estimated $0.02 to $0.05. A room with 3 tripwires checked weekly for 6 months ≈ 78 checks ≈ $2 to $4, about the cost of 2 to 3 rooms. Confirm with `scripts/cost-report.py` after the first 50 checks. Covered by the daily cap (T6).

## 7. Test by hand before building

For the next 5 to 10 decided pilot rooms:
1. Write each room's tripwires into a sheet with watch, baseline and threshold.
2. Check them by hand once a week for 4 weeks.
3. When one moves, WhatsApp the owner with the message format from section 3.

Build it if at least half the owners reply or open the room after an alert. If they ignore it, stop: the frequency problem needs a different answer.

## 8. Checks against the code before building

| # | Check |
| --- | --- |
| C1 | Verdict JSON: confirm tripwires are kept on the `analyses` row and add the new fields without breaking old rooms (old tripwires = `checkable` false). |
| C2 | Reopen: confirm `reopen_room()` can take a reason and an extra fact from the server path, not only the owner's browser. |
| C3 | Worker: confirm the watch worker can share the claim pattern of `claim_decide_job` so two servers never check the same tripwire. |
| C4 | Email: confirm the nudge worker's Resend sender, unsubscribe link and quiet hours can be reused. |
| C5 | Quotas: add a `watch` counter to `usage_counts` or a server-wide daily spend check. |

## 9. Not now

- Live market data feeds (prices, FX, commodity APIs). Start with web search; add feeds for the most-watched signals later.
- Members adding their own tripwires after the call.
- Re-running the full analysis automatically when a tripwire fires (the owner reopens; what-if re-run stays owner-triggered).
