-- Review (release 2, decided 2026-10-22): on the review date the room checks how the call turned out.
-- The owner logs what happened, a 1-5 rating and lessons; each member rates privately. The room sees the
-- average, and the spread and notes only from 3 raters. A review can be repeated ("review again in 3 or
-- 6 months"), so outcomes are one row per review.

-- ---------- Outcomes: one row per review, written only through log_review ----------
drop table outcome_comments;   -- never used by any screen
alter table outcomes drop constraint outcomes_pkey;
alter table outcomes add column id uuid not null default gen_random_uuid() primary key;
alter table outcomes add column review_no integer not null default 1 check (review_no between 1 and 50);
alter table outcomes add column plan_total integer not null default 0;
alter table outcomes add column plan_done integer not null default 0;
alter table outcomes add column plan_blocked integer not null default 0;
alter table outcomes add constraint outcomes_room_review unique (room_id, review_no);
alter table outcomes add constraint outcomes_text_sizes check (length(what_happened) between 1 and 2000 and length(lessons) <= 2000);
drop policy "owner logs outcome" on outcomes;
drop policy "owner edits outcome" on outcomes;

-- ---------- Members' private ratings ----------
create table review_ratings (
  room_id    uuid not null,
  user_id    uuid not null,
  review_no  integer not null,
  rating     smallint not null check (rating between 1 and 5),
  note       text not null default '' check (length(note) <= 500),
  created_at timestamptz not null default now(),
  primary key (room_id, user_id, review_no),
  foreign key (room_id, user_id) references memberships (room_id, user_id) on delete cascade
);
alter table review_ratings enable row level security;

-- The review that is open now, if any: the first one once the call is settled, then another only when
-- the owner set a later review date after the last one was logged.
create function review_round(rid uuid) returns integer
language sql stable security definer set search_path = public as $$
  select case
    when r.status not in ('decided', 'reviewed') then null
    when lo.n = 0 then 1
    when r.review_date > lo.last_at::date then lo.n + 1
    else null end
  from rooms r,
       lateral (select count(*)::int n, max(logged_at) last_at from outcomes o where o.room_id = r.id) lo
  where r.id = rid
$$;

create policy "own rating: read" on review_ratings for select using (user_id = (select auth.uid()));
create policy "own rating: add" on review_ratings for insert with check (
  user_id = (select auth.uid()) and review_no = review_round(room_id)
  and exists (select 1 from memberships m where m.room_id = review_ratings.room_id and m.user_id = (select auth.uid()) and m.role <> 'observer'));
create policy "own rating: change" on review_ratings for update
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and review_no = review_round(room_id));
create index review_ratings_user_idx on review_ratings (user_id);

-- Where the review stands, for everyone in the room.
create function review_state(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when room_role(rid) is null then null else jsonb_build_object(
    'round', review_round(rid),
    'due', review_round(rid) is not null and r.review_date <= current_date,
    'review_date', r.review_date,
    'raters', (select count(*) from review_ratings x where x.room_id = rid and x.review_no = review_round(rid))
  ) end
  from rooms r where r.id = rid
$$;

-- Each logged review with the room's ratings: average always; spread and notes only from 3 raters,
-- so in a small room nobody can work out another person's rating.
create function review_summary(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when room_role(rid) is null then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'review_no', o.review_no, 'logged_at', o.logged_at, 'what_happened', o.what_happened, 'rating', o.rating,
    'lessons', o.lessons, 'plan_total', o.plan_total, 'plan_done', o.plan_done, 'plan_blocked', o.plan_blocked,
    'raters', s.n, 'avg', case when s.n > 0 then round(s.avg, 1) end,
    'min', case when s.n >= 3 then s.mn end, 'max', case when s.n >= 3 then s.mx end,
    'notes', case when s.n >= 3 then s.notes else '[]'::jsonb end) order by o.review_no), '[]'::jsonb) end
  from outcomes o
  left join lateral (
    select count(*) n, avg(rating) avg, min(rating) mn, max(rating) mx,
           coalesce(jsonb_agg(note order by note) filter (where length(trim(note)) > 0), '[]'::jsonb) notes
    from review_ratings x where x.room_id = o.room_id and x.review_no = o.review_no) s on true
  where o.room_id = rid
$$;

-- The owner logs the review. It closes this round, moves the room to "reviewed" and, if asked,
-- sets the next review date.
create function log_review(rid uuid, what_happened text, rating integer, lessons text default '', next_review date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  rnd integer := review_round(rid);
begin
  if room_role(rid) is distinct from 'owner' then
    raise exception 'only_owner_reviews' using errcode = 'insufficient_privilege';
  end if;
  if rnd is null then
    raise exception 'no_review_open' using errcode = 'check_violation';
  end if;
  if length(trim(coalesce(what_happened, ''))) = 0 then
    raise exception 'review_needs_text' using errcode = 'check_violation';
  end if;
  if next_review is not null and next_review <= current_date then
    raise exception 'next_review_in_future' using errcode = 'check_violation';
  end if;
  insert into outcomes (room_id, review_no, what_happened, rating, lessons, logged_by, plan_total, plan_done, plan_blocked)
  select rid, rnd, trim(what_happened), rating, coalesce(trim(lessons), ''), auth.uid(),
         count(*), count(*) filter (where status = 'done'), count(*) filter (where status = 'blocked')
  from plan_items where room_id = rid and kind <> 'review';
  perform set_config('app.room_trusted', 'on', true);
  -- No next review: bring the date to today, so a review logged early doesn't leave another one open.
  update rooms set status = 'reviewed', review_date = coalesce(next_review, least(review_date, current_date)) where id = rid;
  perform set_config('app.room_trusted', 'off', true);
  return rnd;
end $$;

revoke execute on function review_round(uuid), review_state(uuid), review_summary(uuid), log_review(uuid, text, integer, text, date) from public, anon;
grant execute on function review_round(uuid), review_state(uuid), review_summary(uuid), log_review(uuid, text, integer, text, date) to authenticated;

-- ---------- The report carries the reviews ----------
create or replace function room_report(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'room', jsonb_build_object('question', r.question, 'type', r.type, 'type_label', r.type_label, 'language', r.language,
                               'context', r.context, 'options', r.options, 'links', r.links, 'model', r.model, 'rapid', r.rapid,
                               'status', r.status, 'review_date', r.review_date, 'created_at', r.created_at,
                               'override_rule', r.override_rule, 'report_mode', r.report_mode,
                               'override_role', (select x->>'title' from jsonb_array_elements(r.roles) x where x->>'id' = r.override_role_id)),
    'owner_name', nullif(trim(p.name), ''),
    'members', (select count(*) from memberships m where m.room_id = r.id and m.role <> 'observer'),
    'answered', (select count(*) from inputs i where i.room_id = r.id),
    'analysis', (select jsonb_build_object('frame', a.frame, 'verdict', a.verdict, 'disagreement_map', a.disagreement_map,
                                           'confidence', a.confidence, 'owner_decision', a.owner_decision,
                                           'override_reason', a.override_reason, 'final_option', a.final_option,
                                           'decided_at', a.decided_at, 'created_at', a.created_at)
                 from analyses a where a.room_id = r.id order by a.created_at desc limit 1),
    'signoffs', (select coalesce(jsonb_object_agg(s.stance, s.n), '{}'::jsonb)
                 from (select stance, count(*) n from signoffs where room_id = r.id group by stance) s),
    'objections', (select coalesce(jsonb_agg(jsonb_build_object(
                      'by_role', coalesce(m.role_title, 'Approver'), 'reason', ob.reason, 'option_id', ob.option_id,
                      'status', ob.status, 'override_reason', ob.override_reason,
                      'created_at', ob.created_at, 'resolved_at', ob.resolved_at) order by ob.created_at), '[]'::jsonb)
                   from objections ob left join memberships m on m.room_id = ob.room_id and m.user_id = ob.user_id
                   where ob.room_id = r.id),
    'plan', (select coalesce(jsonb_agg(jsonb_build_object(
                'kind', pi.kind, 'title', pi.title, 'owner', coalesce(pi.owner_label, mm.role_title, pp.name),
                'due_date', pi.due_date, 'status', pi.status) order by pi.due_date nulls last, pi.position), '[]'::jsonb)
             from plan_items pi
             left join memberships mm on mm.room_id = pi.room_id and mm.user_id = pi.assignee
             left join profiles pp on pp.id = pi.assignee
             where pi.room_id = r.id),
    -- Reviews with the room's ratings, same small-room rule as review_summary.
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object(
                   'review_no', o.review_no, 'logged_at', o.logged_at, 'what_happened', o.what_happened, 'rating', o.rating,
                   'lessons', o.lessons, 'plan_total', o.plan_total, 'plan_done', o.plan_done, 'plan_blocked', o.plan_blocked,
                   'raters', s.n, 'avg', case when s.n > 0 then round(s.avg, 1) end,
                   'min', case when s.n >= 3 then s.mn end, 'max', case when s.n >= 3 then s.mx end) order by o.review_no), '[]'::jsonb)
                from outcomes o
                left join lateral (select count(*) n, avg(rating) avg, min(rating) mn, max(rating) mx
                                   from review_ratings x where x.room_id = o.room_id and x.review_no = o.review_no) s on true
                where o.room_id = r.id)
  )
  from rooms r join profiles p on p.id = r.owner_id
  where r.id = rid
$$;
revoke execute on function room_report(uuid) from public, anon, authenticated;

-- ---------- Your rooms: reviews that are due ----------
drop function my_rooms();
create function my_rooms()
returns table (id uuid, type room_type, type_label text, question text, status room_status, role member_role, language app_language,
               review_date date, created_at timestamptz, quorum smallint, members bigint, submitted bigint,
               i_submitted boolean, has_verdict boolean,
               options jsonb, decide_by date, decide_error text, last_input timestamptz,
               decided_at timestamptz, final_label text, signed bigint, invited bigint, review_due boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.type_label, r.question, r.status, m.role, r.language, r.review_date, r.created_at, r.quorum,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         exists (select 1 from inputs i where i.room_id = r.id and i.user_id = auth.uid()),
         exists (select 1 from analyses a where a.room_id = r.id),
         r.options, r.decide_by, r.decide_error,
         (select max(i.submitted_at) from inputs i where i.room_id = r.id),
         a.decided_at,
         (select o->>'label' from jsonb_array_elements(r.options) o where o->>'id' = a.final_option),
         (select count(*) from signoffs s where s.room_id = r.id),
         case when m.role = 'owner' then (select count(*) from invites v where v.room_id = r.id and v.person_name is not null and not v.revoked) end,
         review_round(r.id) is not null and r.review_date <= current_date
  from memberships m join rooms r on r.id = m.room_id
  left join lateral (select x.decided_at, x.final_option from analyses x where x.room_id = r.id order by x.created_at desc limit 1) a on true
  where m.user_id = auth.uid()
  order by r.created_at desc
$$;
revoke execute on function my_rooms() from public, anon;
grant execute on function my_rooms() to authenticated;
