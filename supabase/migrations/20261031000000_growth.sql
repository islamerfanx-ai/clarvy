-- Growth dashboard (decided 2026-10-22): the operator's admin page shows decisions per week (north star),
-- acquisition, activation, the growth loop, the room funnel, retention cohorts, quality, money,
-- organisations and health. All numbers come from admin_growth(), server only. Nothing per answer.

-- Where each account came from, saved once at first sign-in: room_invite, org_invite, org_link, or the
-- first visit's source (a utm_source, a referring site, or "direct").
alter table profiles add column signup_source text check (signup_source is null or length(signup_source) <= 40);
alter table profiles add column signup_detail text check (signup_detail is null or length(signup_detail) <= 200);

create or replace function guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  verified text;
begin
  select email into verified from auth.users where id = new.id and coalesce(is_anonymous, false) = false;
  if verified is not null then new.email := verified; end if;
  if new.completed_at is null and length(trim(new.name)) > 0 and length(trim(coalesce(new.organisation, ''))) > 0
     and length(trim(coalesce(new.job_title, ''))) > 0 and new.country is not null then
    new.completed_at := now();
  end if;
  -- The sign-up source is written once.
  if old.signup_source is not null then new.signup_source := old.signup_source; new.signup_detail := old.signup_detail; end if;
  return new;
end $$;
revoke execute on function guard_profile() from public, anon, authenticated;

create function admin_growth() returns jsonb
language sql stable security definer set search_path = public as $$
with
wk as (select generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') as w),
acct as (select u.id, u.created_at, u.last_sign_in_at, p.name, p.organisation, p.completed_at, p.signup_source, p.country, p.sector
         from auth.users u join profiles p on p.id = u.id where not coalesce(u.is_anonymous, false)),
dec as (select a.room_id, max(a.decided_at) as decided_at from analyses a where a.decided_at is not null group by a.room_id),
lastan as (select distinct on (a.room_id) a.room_id, a.owner_decision, a.confidence from analyses a order by a.room_id, a.created_at desc),
ans as (select room_id, count(*) as n from inputs group by room_id),
-- Owner activity per week, for active owners and retention.
act as (select owner_id, date_trunc('week', created_at) as aw from rooms
        union select r.owner_id, date_trunc('week', d.decided_at) from rooms r join dec d on d.room_id = r.id),
first_room as (select owner_id, min(created_at) as at, date_trunc('week', min(created_at)) as cw from rooms group by owner_id),
first_dec as (select r.owner_id, min(d.decided_at) as at from rooms r join dec d on d.room_id = r.id group by r.owner_id),
cohort as (
  select fr.cw, k, count(distinct fr.owner_id) as owners, count(distinct a.owner_id) as active
  from first_room fr cross join generate_series(0, 8) k
  left join act a on a.owner_id = fr.owner_id and a.aw = fr.cw + k * interval '1 week'
  where fr.cw >= date_trunc('week', now()) - interval '8 weeks' and fr.cw + k * interval '1 week' <= date_trunc('week', now())
  group by fr.cw, k),
recent as (select * from acct where created_at > now() - interval '84 days'),
proom as (select r.* from rooms r where r.created_at > now() - interval '84 days'),
pinv as (select v.* from invites v where v.person_name is not null and v.created_at > now() - interval '84 days'),
members30 as (select r.owner_id, r.id, (select count(*) from memberships m where m.room_id = r.id and m.role <> 'observer') as people
              from rooms r where r.created_at > now() - interval '30 days')
select jsonb_build_object(
  'generated_at', now(),
  'weeks', (select jsonb_agg(jsonb_build_object(
      'week', w::date,
      'decisions', (select count(*) from dec where decided_at >= w and decided_at < w + interval '1 week'),
      'opened', (select count(*) from rooms r where r.created_at >= w and r.created_at < w + interval '1 week'),
      'new_accounts', (select count(*) from acct where created_at >= w and created_at < w + interval '1 week'),
      'active_owners', (select count(distinct owner_id) from act where aw = w),
      'ai_cost', (select coalesce(round(sum(cost), 2), 0) from ai_usage where created_at >= w and created_at < w + interval '1 week')
    ) order by w) from wk),

  'acquisition', jsonb_build_object(
    'accounts', (select count(*) from recent),
    'profiles_done', (select count(*) from recent where completed_at is not null),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('k', s, 'n', n) order by n desc), '[]'::jsonb)
                from (select coalesce(signup_source, 'unknown') s, count(*) n from recent group by 1) x),
    'countries', (select coalesce(jsonb_agg(jsonb_build_object('k', c, 'n', n) order by n desc), '[]'::jsonb)
                  from (select country c, count(*) n from recent where country is not null group by 1 order by 2 desc limit 8) x),
    'sectors', (select coalesce(jsonb_agg(jsonb_build_object('k', c, 'n', n) order by n desc), '[]'::jsonb)
                from (select sector c, count(*) n from recent where sector is not null group by 1 order by 2 desc limit 8) x)),

  'activation', jsonb_build_object(
    'signed_up', (select count(*) from recent),
    'profile', (select count(*) from recent where completed_at is not null),
    'opened', (select count(*) from recent a where exists (select 1 from rooms r where r.owner_id = a.id)),
    'answered', (select count(*) from recent a where exists (select 1 from rooms r join ans on ans.room_id = r.id where r.owner_id = a.id and ans.n >= 2)),
    'decided', (select count(*) from recent a where exists (select 1 from first_dec f where f.owner_id = a.id)),
    'days_first_room', (select round((percentile_cont(0.5) within group (order by extract(epoch from fr.at - a.created_at) / 86400))::numeric, 1)
                        from recent a join first_room fr on fr.owner_id = a.id),
    'days_first_decision', (select round((percentile_cont(0.5) within group (order by extract(epoch from f.at - a.created_at) / 86400))::numeric, 1)
                            from recent a join first_dec f on f.owner_id = a.id)),

  'loop', jsonb_build_object(
    'invited', (select count(*) from pinv),
    'joined', (select count(*) from pinv where joined_by is not null),
    'answered', (select count(*) from pinv v where v.joined_by is not null and exists (select 1 from inputs i where i.room_id = v.room_id and i.user_id = v.joined_by)),
    'signed', (select count(*) from pinv v where v.joined_by is not null and exists (select 1 from signoffs s where s.room_id = v.room_id and s.user_id = v.joined_by)),
    'own_room', (select count(*) from pinv v where v.joined_by is not null and exists (select 1 from rooms r where r.owner_id = v.joined_by and r.created_at > v.created_at)),
    'per_room', (select round(avg(n), 1) from (select room_id, count(*) n from pinv group by room_id) x),
    -- New owners in the last 30 days who first came in as someone else's member, per owner active the 30 days before.
    'viral', (select round(
               (select count(*) from first_room fr where fr.at > now() - interval '30 days'
                  and exists (select 1 from memberships m join rooms r on r.id = m.room_id where m.user_id = fr.owner_id and m.role <> 'owner' and m.joined_at < fr.at))::numeric
               / nullif((select count(distinct owner_id) from act where aw >= date_trunc('week', now() - interval '60 days') and aw < date_trunc('week', now() - interval '30 days')), 0), 2))),

  'rooms', jsonb_build_object(
    'opened', (select count(*) from proom),
    'invited', (select count(*) from proom r where exists (select 1 from invites v where v.room_id = r.id)),
    'enough', (select count(*) from proom r join ans on ans.room_id = r.id where ans.n >= r.quorum),
    'decide', (select count(*) from proom r where exists (select 1 from analyses a where a.room_id = r.id)),
    'settled', (select count(*) from proom r where r.status in ('decided', 'reviewed')),
    'planned', (select count(*) from proom r where exists (select 1 from plan_items p where p.room_id = r.id)),
    'reviewed', (select count(*) from proom r where r.status = 'reviewed')),

  'cohorts', (select coalesce(jsonb_agg(jsonb_build_object('week', cw::date, 'owners', owners, 'pct', pct) order by cw), '[]'::jsonb)
              from (select cw, max(owners) owners, jsonb_agg(round(100.0 * active / nullif(owners, 0)) order by k) pct from cohort group by cw) c),

  'quality', jsonb_build_object(
    'accepted', (select count(*) from lastan where owner_decision = 'accepted'),
    'overridden', (select count(*) from lastan where owner_decision = 'overridden'),
    'signoffs', (select coalesce(jsonb_object_agg(stance, n), '{}'::jsonb) from (select stance, count(*) n from signoffs group by stance) s),
    'reviews', (select count(*) from outcomes),
    'held_up', (select count(*) from outcomes where rating >= 4),
    'days_to_decide', (select round((percentile_cont(0.5) within group (order by extract(epoch from d.decided_at - r.created_at) / 86400))::numeric, 1)
                       from rooms r join dec d on d.room_id = r.id),
    'by_confidence', (select coalesce(jsonb_agg(jsonb_build_object('k', confidence, 'reviews', n, 'held', held) order by confidence), '[]'::jsonb)
                      from (select la.confidence, count(*) n, count(*) filter (where o.rating >= 4) held
                            from outcomes o join lastan la on la.room_id = o.room_id where la.confidence is not null group by la.confidence) x)),

  'money', jsonb_build_object(
    'cost_month', (select coalesce(round(sum(cost), 2), 0) from ai_usage where created_at >= date_trunc('month', now())),
    'cost_30d', (select coalesce(round(sum(cost), 2), 0) from ai_usage where created_at > now() - interval '30 days'),
    'cost_per_room', (select round(avg(c), 2) from (select room_id, sum(cost) c from ai_usage where room_id is not null and created_at > now() - interval '84 days' group by room_id) x),
    'active_owners_30d', (select count(distinct owner_id) from act where aw > now() - interval '30 days'),
    'by_kind', (select coalesce(jsonb_agg(jsonb_build_object('k', kind, 'cost', c) order by c desc), '[]'::jsonb)
                from (select kind, round(sum(cost), 2) c from ai_usage where created_at >= date_trunc('month', now()) group by kind) x),
    'upgrade', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'organisation', a.organisation, 'max_people', x.max_people, 'rooms_30d', x.rooms)
                                         order by x.max_people desc, x.rooms desc), '[]'::jsonb)
                from (select owner_id, max(people) max_people, count(*) rooms from members30 group by owner_id) x
                join acct a on a.id = x.owner_id
                where x.max_people > 3 or x.rooms > 2)),

  'orgs', (select coalesce(jsonb_agg(jsonb_build_object(
              'name', w.name, 'memory', w.memory_on,
              'people', (select count(*) from workspace_members m where m.workspace_id = w.id),
              'active_30d', (select count(distinct m.user_id) from workspace_members m
                             where m.workspace_id = w.id and (exists (select 1 from rooms r where r.owner_id = m.user_id and r.workspace_id = w.id and r.created_at > now() - interval '30 days')
                                                            or exists (select 1 from inputs i join rooms r on r.id = i.room_id where i.user_id = m.user_id and r.workspace_id = w.id and i.submitted_at > now() - interval '30 days'))),
              'rooms_30d', (select count(*) from rooms r where r.workspace_id = w.id and r.created_at > now() - interval '30 days'),
              'decisions', (select count(*) from rooms r where r.workspace_id = w.id and r.status in ('decided', 'reviewed'))
            ) order by w.name), '[]'::jsonb)
           from workspaces w where w.kind = 'organisation'),

  'health', jsonb_build_object(
    'failed_now', (select count(*) from rooms where decide_error is not null and status = 'open'),
    'analyses_7d', (select count(*) from analyses where created_at > now() - interval '7 days'),
    'decide_seconds', (select round((percentile_cont(0.5) within group (order by s))::numeric) from (
                         select extract(epoch from max(created_at) - min(created_at)) s from ai_usage
                         where kind in ('sensemaker', 'analyst', 'judge') and room_id is not null and created_at > now() - interval '7 days'
                         group by room_id, date_trunc('hour', created_at)) x),
    'decide_seconds_max', (select round(max(s)::numeric) from (
                         select extract(epoch from max(created_at) - min(created_at)) s from ai_usage
                         where kind in ('sensemaker', 'analyst', 'judge') and room_id is not null and created_at > now() - interval '7 days'
                         group by room_id, date_trunc('hour', created_at)) x),
    'decide_limit_hits_7d', (select count(*) from usage_counts where kind = 'decide' and n >= 5 and day > current_date - 7),
    'stuck_open', (select count(*) from rooms r where r.status = 'open' and r.decide_by is not null and r.decide_by < current_date))
)
$$;
revoke execute on function admin_growth() from public, anon, authenticated;
grant execute on function admin_growth() to service_role;

-- Admin access (decided 2026-10-23): anyone signed in with a finished profile can ask from /admin.html;
-- an operator approves or declines on the admin page. Server only: no one reads or writes this from the browser.
create table operator_requests (
  user_id     uuid primary key references profiles(id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at  timestamptz not null default now(),
  decided_by  uuid references profiles(id) on delete set null,
  decided_at  timestamptz
);
alter table operator_requests enable row level security;
revoke all on operator_requests from anon, authenticated;
