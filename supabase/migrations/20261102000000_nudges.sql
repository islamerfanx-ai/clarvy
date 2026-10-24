-- Nudges (decided 2026-10-24): the owner sees who has opened their invite, and people who haven't answered
-- get up to two reminders timed by the decide-by date (halfway, and a day before; a few hours before when the
-- window is short). The server sends them (Resend) only when a sender key is set; the owner can switch them off.

-- When a personal invite link was first opened (before joining). Members are told the owner can see this.
alter table invites add column opened_at timestamptz;

create function invite_opened(invite_token text) returns void
language sql volatile security definer set search_path = public as $$
  update invites set opened_at = now()
  where token = invite_token and opened_at is null and not revoked and expires_at > now()
$$;
revoke execute on function invite_opened(text) from public;
grant execute on function invite_opened(text) to anon, authenticated;

-- The owner can switch automatic reminders off for a room.
alter table rooms add column auto_nudge boolean not null default true;

-- Every reminder sent. Server only.
create table nudges (
  id           bigint generated always as identity primary key,
  room_id      uuid not null references rooms (id) on delete cascade,
  invite_token text references invites (token) on delete cascade,
  user_id      uuid references profiles (id) on delete cascade,
  kind         text not null check (kind in ('half', 'last')),
  sent_at      timestamptz not null default now(),
  check ((invite_token is null) <> (user_id is null))
);
create index nudges_room_idx on nudges (room_id);
create unique index nudges_once_invite on nudges (invite_token, kind) where invite_token is not null;
create unique index nudges_once_user on nudges (room_id, user_id, kind) where user_id is not null;
alter table nudges enable row level security;
revoke all on nudges from anon, authenticated;

-- The owner's view: how many reminders each person got, and when the last one went.
create function room_nudges(rid uuid)
returns table (invite_token text, user_id uuid, n bigint, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select n.invite_token, n.user_id, count(*), max(n.sent_at)
  from nudges n where n.room_id = rid and room_role(rid) = 'owner'
  group by n.invite_token, n.user_id
$$;
revoke execute on function room_nudges(uuid) from public, anon;
grant execute on function room_nudges(uuid) to authenticated;

-- Reminders due now (server only). The deadline is 18:00 UTC on the decide-by date. Halfway is skipped when
-- the whole window is under 36 hours; the last one goes a day before, or a quarter of the window when shorter.
create function nudge_due()
returns table (room_id uuid, question text, language app_language, owner_name text, decide_by date, kind text,
               invite_token text, user_id uuid, email text, person_name text)
language sql stable security definer set search_path = public as $$
  with targets as (
    -- Personal invites not used yet, sent to an email address.
    select r.id as room_id, i.token as invite_token, null::uuid as user_id, lower(trim(i.person_contact)) as email,
           i.person_name, i.created_at as start_at
    from invites i join rooms r on r.id = i.room_id
    where i.person_name is not null and i.uses = 0 and not i.revoked and i.expires_at > now()
      and i.person_contact ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    union all
    -- People who joined but haven't answered.
    select r.id, null, m.user_id, lower(p.email), p.name, m.joined_at
    from memberships m join rooms r on r.id = m.room_id join profiles p on p.id = m.user_id
    where m.role not in ('owner', 'observer') and p.email is not null
      and not exists (select 1 from inputs x where x.room_id = m.room_id and x.user_id = m.user_id)
  ),
  timed as (
    select t.*, r.question, r.language, r.decide_by, nullif(trim(o.name), '') as owner_name,
           (r.decide_by + time '18:00') at time zone 'UTC' as deadline
    from targets t join rooms r on r.id = t.room_id join profiles o on o.id = r.owner_id
    where r.status = 'open' and r.auto_nudge and r.decide_by is not null
  ),
  points as (
    select t.*, t.deadline - t.start_at as win,
           t.start_at + (t.deadline - t.start_at) / 2 as half_at,
           t.deadline - least(interval '1 day', (t.deadline - t.start_at) / 4) as last_at
    from timed t where t.deadline > now() and t.deadline > t.start_at
  )
  select p.room_id, p.question, p.language, p.owner_name, p.decide_by,
         case when now() >= p.last_at then 'last' else 'half' end,
         p.invite_token, p.user_id, p.email, p.person_name
  from points p
  where (now() >= p.last_at or (now() >= p.half_at and p.win >= interval '36 hours'))
    and not exists (select 1 from nudges n where n.room_id = p.room_id
                    and (n.invite_token = p.invite_token or n.user_id = p.user_id
                         -- someone reminded on their invite who then joined keeps the same count
                         or n.invite_token in (select i.token from invites i where i.room_id = p.room_id and i.joined_by = p.user_id))
                    and n.kind = case when now() >= p.last_at then 'last' else 'half' end)
  limit 200
$$;
revoke execute on function nudge_due() from public, anon, authenticated;
grant execute on function nudge_due() to service_role;
