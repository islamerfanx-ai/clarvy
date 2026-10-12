# Clarvy Decision Rooms: Product Spec

Last updated: 2026-10-12 · Owner: Islam Erfan
Source of truth: the live Claude doc "Clarvy Decision Rooms: Product Spec". This file is the copy Claude Code builds from.

## Summary

Decision Rooms turn Clarvy from a solo answer machine into the place where partners and families make a big call together, write it down, and check later whether it was right.

**One-liner:** ChatGPT gives you an answer. Clarvy runs your decisions.

A room holds one decision. Each member privately says what matters to them and how much risk they can live with. Clarvy combines everyone's view with the facts and files, shows exactly where the group disagrees, recommends one call, and sets a date to review how it turned out.

Why this is our niche and not a chatbot feature:

- **Group, not one person.** Chatbots are one person in one chat. Real decisions involve partners, boards, teams, families and friends.
- **Memory and accountability.** Every decision is logged with its odds, owner and review date. Over time the room builds a track record no one can copy.
- **Global, with Arabic built in.** Works in English and Arabic from day one, with full right-to-left layout, so mixed teams can each read and answer in their own language.
- **The engine is already built.** The current Clarvy pipeline (framing, odds, stress test, bias check, judge) becomes the brain inside each room.

## Who it's for

Decision Rooms are global from launch and built around three serious domains (business, finance and politics) plus one fun one: group travel.

| Role | Who | What they need from a room |
| --- | --- | --- |
| Buyer and room owner | Founder, CEO, managing partner, fund partner, campaign or policy lead, or the friend who always plans the trip | A clear call the group signs off on, and a record of why |
| Members | Co-founders, partners, board members, investment committee, family shareholders, advisers, friends | A safe, private way to say what they really think |
| Observer (optional) | Board adviser, lawyer, banker, communications lead | Read the reasoning without a vote |

**Jobs they hire it for:**

- **Business:** expansion to a new city or country, launches, pricing, hiring or replacing a key leader, partnerships, M&A
- **Finance:** raising or taking on debt, investment committee calls, buy, hold or sell, capital allocation, dividends versus reinvestment
- **Politics and public affairs:** whether and how to respond to a new law or regulation, taking a public position, campaign and advocacy choices, policy options for a team
- **Travel (for fun):** where and when a group of friends, a family or a team goes, with calendars connected

**Why these first:** business, finance and politics decisions are large, contested and frequent enough to pay for, and private input matters most where power and money are uneven. Travel is the opposite: low stakes, high fun, and every trip invites new people, so it brings users in for free.

## Room types

Each room type is the same engine with its own templates, criteria, data and tone.

| Room type | Typical question | Suggested criteria | Live data it pulls |
| --- | --- | --- | --- |
| Business | Open in a second city this year or wait? | Upside, cash risk, execution capacity, brand fit | Market news, competitor moves, local rules |
| Finance | Take the loan, raise equity, or self-fund? | Cost of capital, control, downside protection, liquidity | Rates, FX, sector news, filings |
| Politics and public affairs | Speak publicly on the new regulation or stay quiet? | Mission and values, real-world impact, reputation, relationships, safety | The law or policy itself, its status, what each side says |
| Trip (fun) | Where and when should the six of us go? | Budget, travel time from each home, weather, vibe, dates that work for everyone | Calendars, flights, hotels, weather, local events |

**Politics rooms stay neutral.** Clarvy decides from the group's own stated values, never its own views, never favours a party or candidate, and always shows the strongest case for each side with sources.

### Trip rooms

A Trip room finds the best time and place for everyone, then lets the group pick from the top three.

1. **Connect calendars.** Each member connects Google, Outlook or Apple Calendar. Clarvy reads only free and busy times, never event details.
2. **Set the brief.** The organiser sets the trip length, a date range and any must-haves. Each member privately adds their budget, home city, vibe (beach, city, nature, food, adventure) and anything they won't do.
3. **Find the windows.** Clarvy finds the date windows where most people are free, across time zones and weekends, and counts public holidays in each person's country.
4. **Match the places.** For each window it ranks destinations on total travel time from every home city, the cheapest fair fare for each person, weather, visas, local events and fit with everyone's vibe.
5. **Vote and lock.** The group sees the top three options as cards, votes, and Clarvy holds the dates on everyone's calendar once it's decided.

Trip rooms are free and invite-heavy, so every trip brings new people into Clarvy.

## Core user flow

A room runs from question to reviewed outcome in eight steps, and the review feeds the next decision.

1. **Open a room** (owner): question, options, context and files.
2. **Invite people**: by link, WhatsApp or email.
3. **Private input** (each member, alone): weights and risk appetite.
4. **Clarvy analyses**: shared facts once, then odds per member.
5. **Verdict and map**: the call, plus where the group splits.
6. **Sign-off**: each member agrees, disagrees and commits, or objects.
7. **Review**: on the review date the owner logs what happened.
8. **Track record**: the outcome informs the next call, and the loop returns to step 1 for the next decision.

## Features: v1 and later

v1 ships the smallest room that proves two things: more than one person joins each decision, and people come back for the review.

| Feature | v1 | Later |
| --- | --- | --- |
| Create a room with question, context, options and files | Yes | |
| Room types with templates: Business, Finance, Politics, Trip | Yes | More types (Hiring, Property) |
| English and Arabic interface, right-to-left layout, each member picks their language | Yes | French, Spanish |
| Invite by link, WhatsApp and email | Yes | Slack, Teams |
| Private member input: what matters, weights, risk appetite, gut pick, one-line concern | Yes | Voice notes |
| Combined analysis using the existing Clarvy engine | Yes | |
| Disagreement map | Yes | |
| Verdict, with the owner accepting or overriding it and stating why | Yes | |
| Sign-off by each member (agree, disagree and commit, object) | Yes | |
| Review date and outcome check-in | Yes | |
| Decision memo (PDF, in English or Arabic) | Yes | Board-pack format |
| Calendar connection (free and busy only) for Trip rooms | Yes | Meeting scheduling for any room |
| Flights, hotels, weather and events search for Trip rooms | Yes | Booking in the app |
| Track record per room and per person | Basic | Calibration scores |
| Finance and market data pack | | Yes |
| Integrations (Drive, accounting, CRM) | | Yes |
| Weighted votes (for example by share ownership) | | Yes |

**Out of scope for v1:** real-time chat inside the room (WhatsApp already does this), formal legal voting or shareholder resolutions, and anonymous members.

## How the combined view works

Clarvy decides once for the group, but it scores every option through each member's eyes first, so disagreement is measured, not guessed.

1. **Shared frame.** The owner's question, options, files and live news run through the existing Frame, Scout and Reader steps once. Everyone sees the same facts.
2. **Each member's lens.** Every member privately sets weights on the criteria (summing to 100), picks a risk appetite (Play it safe, Balanced, Go big), names a gut pick and writes one concern.
3. **Score per member.** The Analyst's option scores and best/likely/worst outcomes are computed once. The math then reruns per member with that member's weights and risk appetite. This step is code, not extra AI calls, so it costs nothing extra.
4. **Group result.** The group's expected value for each option is the average across members, weighted equally in v1. The safest option, dominated options and anything worth checking first come from the existing stress test.
5. **Disagreement map.** For each criterion, the spread of weights shows where people value different things. For each member, their personal winner shows who leans which way. Concerns are grouped by theme. The map separates two kinds of disagreement: different facts, which a check can settle, and different values, which the owner has to weigh.
6. **Judge.** The Judge gets the group result plus the map. It names the call, the confidence, who it will disappoint and why, and what would bring them on board.

**Confidence rule:** if two or more members' personal winners differ from the group call, confidence is capped at Medium and the verdict names the split.

## Screens

Eight screens cover v1, all in the current Clarvy look (dark halo, mono type, message cards) and all mirrored for Arabic.

| Screen | Who sees it | What's on it |
| --- | --- | --- |
| Rooms | Everyone | Open rooms with status and who still owes input; decided rooms with their review dates; track record at the top |
| New room | Owner | Room type, question, options, context, files, criteria (suggested by Clarvy, editable), invite list, review date |
| My input | Member | The question and shared facts, a weight slider per criterion, risk appetite, gut pick, one concern. Takes under 3 minutes |
| Waiting | Everyone | Who has submitted (ticks, not content), a nudge button, "decide now" for the owner once a quorum is met |
| Verdict | Everyone | The call, confidence, check-first card, why, risks, files and news, then sign-off buttons |
| Disagreement map | Everyone | Spread of weights per criterion, each member's personal winner (anonymous by default), concerns grouped by theme, facts vs values split |
| Trip options | Trip members | Calendar overlap strip, top three date-and-place cards with travel time and fare per person, weather and events, vote buttons |
| Review | Owner, then everyone | What happened, a rating against the call, lessons; feeds the track record |

## Roles, privacy and trust

Private input is the product: if members fear their honest view will be seen and held against them, they will repeat what the elder or the majority partner wants.

| | Owner | Member | Observer |
| --- | --- | --- | --- |
| Set up the question, options and files | Yes | Suggest options | No |
| Give private input | Yes | Yes | No |
| See others' raw input | No | No | No |
| See the combined result and disagreement map | Yes | Yes | Yes |
| Accept or override the verdict | Yes | No | No |
| Sign off | Yes | Yes | No |
| Log the outcome at review | Yes | Comment | No |

- **Individual inputs stay private by default.** The map shows that "two members weigh cash risk far higher", not who. The owner can switch on named views only if every member agrees when they join.
- **Overrides are on the record.** If the owner overrides Clarvy, they write one line on why. That line goes into the memo and the track record.
- **Data handling:** questions, files and inputs go to the AI provider only to produce the analysis and are not used for training. Files are stored encrypted and can be deleted by the owner. Each room has an export and a delete button.
- **Not advice:** money and legal decisions carry a short note that Clarvy supports the decision and does not replace a licensed adviser.

## Data model and tech

Rooms extend the current Clarvy app in this folder. The engine stays; what's new is accounts, a database and invites.

| Entity | Key fields |
| --- | --- |
| Workspace | name, plan, owner, members |
| User | name, phone (WhatsApp), email, language (English or Arabic), home city, time zone |
| Room | workspace, type (business, finance, politics, trip), question, context, options, status (open, deciding, decided, reviewed), owner, review date |
| Membership | room, user, role (owner, member, observer), joined date |
| Input | room, user, weights per criterion, risk appetite, gut pick, concern, submitted date |
| Attachment | room, file name, extracted text, uploaded by |
| Calendar link | user, provider (Google, Outlook, Apple), token, free/busy scope only |
| Trip brief | room, date range, length, must-haves; per member: budget, vibe, no-gos |
| Trip option | room, dates, destination, travel time and fare per member, weather, events, votes |
| Analysis | room, frame, outcomes and odds, per-member scores, disagreement map, verdict, confidence |
| Sign-off | room, user, stance (agree, disagree and commit, object), note |
| Outcome | room, what happened, rating against the call, logged by, date |

**Stack (simple and cheap to start):**

- **Front end:** the current single-page app, split into a room list, room view and input view, with English and Arabic text files and right-to-left layout switching.
- **Back end:** the existing `/api/ask` and `/api/search`, plus new room endpoints on Vercel. Prompts ask the model to answer in each member's language.
- **Database and sign-in:** Supabase (Postgres, phone or email login, file storage, row-level security so members only see their rooms).
- **Calendars:** Google Calendar and Microsoft Graph free/busy endpoints; Apple through an iCloud calendar link.
- **Travel data:** a flights and hotels search API, a weather API and a public holidays API.
- **WhatsApp:** the WhatsApp Business API through a provider such as Twilio, for invites, "your input is waiting" nudges and review reminders.
- **PDF memo:** generated on the server from the analysis, in the owner's language.

## Pricing and packaging

Charge per workspace, not per question, so a team pays one predictable fee and invites whoever needs a say. The prices below are starting points to test in the pilot, not researched figures.

| Plan | For | Includes | Price to test |
| --- | --- | --- | --- |
| Free | Individuals and friend groups | Personal decisions (5 a month) and unlimited Trip rooms | Free |
| Team | A founding team, partnership or family business | Up to 8 members, 10 business, finance or politics rooms a month, memos, reviews | USD 99 a month |
| Organisation | Funds, holdings, policy and public-affairs teams | Several workspaces, more rooms, data packs, priority support | From USD 499 a month |
| Facilitated decision | One high-stakes call (succession, partner exit, a public stance) | A room plus a human facilitator session | One-off fee |

Each decision costs roughly 8 to 11 AI calls whatever the number of members, because per-member scoring is plain math. Price so that a heavy month stays under a fifth of the plan fee.

## Pilot plan and success metrics

Run 5 real decisions over 8 weeks with four groups in at least two countries: two business or finance teams, one public-affairs or policy team, and one friend group planning a trip. At least one group works in Arabic.

- [ ] Pick 3 or 4 businesses with a live decision in the next month
- [ ] Run the first room together in a 30-minute onboarding call
- [ ] Set every review date 4 to 6 weeks out
- [ ] Interview each owner after the verdict and after the review

| Metric | Target | Why it matters |
| --- | --- | --- |
| Members who submit input per room | 3 or more | Proves it is a group product, not a solo one |
| Rooms where the owner shares the memo | 60% | Proves the output is trusted enough to show others |
| Reviews completed on time | 70% | Proves the accountability loop works |
| Owners who open a second room unprompted | 50% | Proves repeat use |
| Owners willing to pay at the tested price | 2 of 4 | Proves the business |

## Risks and open questions

The biggest risk is social, not technical: an owner may not want a tool that surfaces disagreement they prefer to keep quiet.

| Risk | What we do about it |
| --- | --- |
| Owners don't want dissent made visible | Inputs anonymous by default; pitch it as "hear what people won't say in the meeting" |
| Members don't bother to give input | Input takes under 3 minutes; WhatsApp and email nudges; the verdict waits for a quorum |
| A bad call is blamed on Clarvy | The owner always signs off and can override; the memo states it supports, not replaces, judgement |
| Politics rooms seen as biased | Decide only from the group's stated values, show every side with sources, never endorse a party or candidate |
| Calendar privacy | Free/busy access only, never event titles; disconnect any time |
| Arabic answers read as machine-translated | Native Arabic prompts and copy reviewed by a native writer, not translated after the fact |
| Sensitive business and financial data | Encryption, delete and export per room, clear privacy note, regional hosting later if asked |
| AI cost per decision grows | Per-member scoring stays in code; cheaper model for the reading, search and trip steps |

**Open questions:**

- Should a majority shareholder's input count more than others' in v1, or only later?
- Does the owner see who signed "object", or only the count?
- What is the minimum number of inputs before Clarvy will give a verdict: 2, or all members?
- Should Trip rooms book flights and hotels directly (and earn a commission), or only link out?
