-- The operator's admin page (decided 2026-10-22): sign-ups, who they are, rooms, decisions and AI cost.
-- Only accounts listed in operators can see it, and only through the server (service role).

create table operators (
  user_id  uuid primary key references profiles (id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table operators enable row level security;   -- no policies: nobody reads it from the browser

-- One row per AI call, written by the server, with its estimated cost.
create table ai_usage (
  id         bigint generated always as identity primary key,
  kind       text not null check (length(kind) <= 30),
  room_id    uuid references rooms (id) on delete set null,
  user_id    uuid references profiles (id) on delete set null,
  model      text check (length(model) <= 60),
  tokens_in  integer not null default 0,
  tokens_out integer not null default 0,
  searches   integer not null default 0,
  cost       numeric(10, 4) not null default 0,
  created_at timestamptz not null default now()
);
create index ai_usage_created_idx on ai_usage (created_at);
create index ai_usage_room_idx on ai_usage (room_id);
create index ai_usage_user_idx on ai_usage (user_id);
alter table ai_usage enable row level security;     -- no policies: server only

-- Everything the admin page shows, in one call (server only).
create function admin_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'accounts', (select count(*) from auth.users u where not coalesce(u.is_anonymous, false)),
    'profiles_complete', (select count(*) from profiles p join auth.users u on u.id = p.id where p.completed_at is not null and not coalesce(u.is_anonymous, false)),
    'rooms', (select count(*) from rooms),
    'decided', (select count(*) from rooms where status in ('decided', 'reviewed')),
    'reviewed', (select count(*) from rooms where status = 'reviewed'),
    'cost_30d', (select coalesce(sum(cost), 0) from ai_usage where created_at > now() - interval '30 days'),
    'cost_by_kind', (select coalesce(jsonb_object_agg(kind, c), '{}'::jsonb) from (select kind, round(sum(cost), 2) c from ai_usage where created_at > now() - interval '30 days' group by kind) k),
    'signups_by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'n', n) order by d), '[]'::jsonb)
                       from (select u.created_at::date d, count(*) n from auth.users u
                             where not coalesce(u.is_anonymous, false) and u.created_at > now() - interval '30 days' group by 1) s),
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
                  'name', p.name, 'email', p.email, 'organisation', p.organisation, 'job_title', p.job_title, 'country', p.country,
                  'sector', p.sector, 'org_size', p.org_size, 'phone', p.phone, 'news', p.news_opt_in,
                  'signed_up', u.created_at, 'last_seen', u.last_sign_in_at, 'complete', p.completed_at is not null,
                  'rooms_owned', (select count(*) from rooms r where r.owner_id = p.id),
                  'rooms_in', (select count(*) from memberships m where m.user_id = p.id),
                  'ai_cost', (select coalesce(round(sum(a.cost), 2), 0) from ai_usage a where a.user_id = p.id)
                ) order by u.created_at desc), '[]'::jsonb)
               from profiles p join auth.users u on u.id = p.id
               where not coalesce(u.is_anonymous, false))
  )
$$;
revoke execute on function admin_overview() from public, anon, authenticated;
grant execute on function admin_overview() to service_role;
