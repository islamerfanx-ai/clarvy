-- Phone notifications (decided 2026-10-28): the site installs as an app and sends push notifications.
-- Each device that allows notifications saves a subscription. Database triggers put events in an outbox (only for
-- people with a device and the kind switched on); the server's worker sends them and marks them sent.
-- Kinds people can switch off: invites (invites and reminders), progress (owner: joined, answered, objections),
-- call (the call is ready or made), after (talk, plan items, review day, reopen requests).

create table push_subscriptions (
  endpoint     text primary key check (endpoint ~ '^https://' and length(endpoint) <= 1000),
  user_id      uuid not null default auth.uid() references profiles (id) on delete cascade,
  p256dh       text not null check (length(p256dh) between 20 and 200),
  auth         text not null check (length(auth) between 8 and 100),
  ua           text check (length(ua) <= 200),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);
create index push_subscriptions_user_idx on push_subscriptions (user_id);
alter table push_subscriptions enable row level security;
create policy "people see their own devices" on push_subscriptions for select using (user_id = (select auth.uid()));
create policy "people remove their own devices" on push_subscriptions for delete using (user_id = (select auth.uid()));

-- Saving goes through a function, so a phone that changes hands moves to whoever signed in last.
create function save_push_subscription(p_endpoint text, p_key text, p_auth text, p_ua text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign_in_first' using errcode = 'insufficient_privilege'; end if;
  insert into push_subscriptions as s (endpoint, user_id, p256dh, auth, ua)
  values (p_endpoint, auth.uid(), p_key, p_auth, left(p_ua, 200))
  on conflict on constraint push_subscriptions_pkey
  do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, created_at = now();
end $$;
revoke execute on function save_push_subscription(text, text, text, text) from public, anon;

create table push_prefs (
  user_id uuid primary key default auth.uid() references profiles (id) on delete cascade,
  off     text[] not null default '{}' check (off <@ array['invites', 'progress', 'call', 'after']::text[])
);
alter table push_prefs enable row level security;
create policy "people read their own settings" on push_prefs for select using (user_id = (select auth.uid()));
create policy "people set their own settings" on push_prefs for insert with check (user_id = (select auth.uid()));
create policy "people change their own settings" on push_prefs for update using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Server only: no policies, so only the service role reads it.
create table push_outbox (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles (id) on delete cascade,
  event      text not null check (event in ('invite', 'joined', 'answered', 'all_answered', 'objection', 'call_ready', 'decided',
                                             'talk', 'reopen', 'plan_assigned', 'plan_due', 'review_due')),
  room_id    uuid references rooms (id) on delete cascade,
  data       jsonb not null default '{}',
  dedupe     text unique,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index push_outbox_waiting_idx on push_outbox (id) where sent_at is null;
create index push_outbox_user_idx on push_outbox (user_id);
create index push_outbox_room_idx on push_outbox (room_id);
alter table push_outbox enable row level security;
revoke all on push_outbox from anon, authenticated;

create function push_kind(ev text) returns text language sql immutable set search_path = public as $$
  select case
    when ev = 'invite' then 'invites'
    when ev in ('joined', 'answered', 'all_answered', 'objection') then 'progress'
    when ev in ('call_ready', 'decided') then 'call'
    else 'after' end
$$;

-- Queue one notification, only for someone with a device who hasn't switched the kind off.
create function push_enqueue(uid uuid, ev text, rid uuid, d jsonb default '{}', key text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if uid is null then return; end if;
  if not exists (select 1 from push_subscriptions s where s.user_id = uid) then return; end if;
  if exists (select 1 from push_prefs p where p.user_id = uid and push_kind(ev) = any (p.off)) then return; end if;
  insert into push_outbox (user_id, event, room_id, data, dedupe) values (uid, ev, rid, coalesce(d, '{}'), key)
  on conflict (dedupe) do nothing;
end $$;
revoke execute on function push_enqueue(uuid, text, uuid, jsonb, text) from public, anon, authenticated;

create function push_name(uid uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(name), ''), '') from profiles where id = uid
$$;
revoke execute on function push_name(uuid) from public, anon, authenticated;

-- An invite to someone who already has an account (matched by email).
create function push_on_invite() returns trigger language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if new.person_contact is null or position('@' in new.person_contact) = 0 then return new; end if;
  select id into uid from profiles where lower(email) = lower(trim(new.person_contact)) limit 1;
  if uid is null or uid = new.created_by then return new; end if;
  perform push_enqueue(uid, 'invite', new.room_id,
    jsonb_build_object('token', new.token, 'by', push_name((select owner_id from rooms where id = new.room_id))), 'invite:' || new.token);
  return new;
end $$;
create trigger push_invites after insert on invites for each row execute function push_on_invite();
revoke execute on function push_on_invite() from public, anon, authenticated;

create function push_on_join() returns trigger language plpgsql security definer set search_path = public as $$
declare own uuid;
begin
  if new.role = 'owner' then return new; end if;
  select owner_id into own from rooms where id = new.room_id;
  if own is distinct from new.user_id then
    perform push_enqueue(own, 'joined', new.room_id, jsonb_build_object('name', push_name(new.user_id)), 'joined:' || new.room_id || ':' || new.user_id);
  end if;
  return new;
end $$;
create trigger push_memberships after insert on memberships for each row execute function push_on_join();
revoke execute on function push_on_join() from public, anon, authenticated;

-- Answers: the owner hears the count (never who answered what); "everyone has answered" once.
create function push_on_input() returns trigger language plpgsql security definer set search_path = public as $$
declare own uuid; n int; m int;
begin
  select owner_id into own from rooms where id = new.room_id;
  if own is null or own = new.user_id then return new; end if;
  select count(*) into n from inputs where room_id = new.room_id;
  select count(*) into m from memberships where room_id = new.room_id and role in ('owner', 'member');
  if n >= m then
    perform push_enqueue(own, 'all_answered', new.room_id, jsonb_build_object('n', n), 'all:' || new.room_id || ':' || n);
  else
    perform push_enqueue(own, 'answered', new.room_id, jsonb_build_object('n', n, 'm', m), 'answered:' || new.room_id || ':' || n);
  end if;
  return new;
end $$;
create trigger push_inputs after insert on inputs for each row execute function push_on_input();
revoke execute on function push_on_input() from public, anon, authenticated;

create function push_on_objection() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform push_enqueue((select owner_id from rooms where id = new.room_id), 'objection', new.room_id,
    jsonb_build_object('name', push_name(new.user_id)), 'objection:' || new.id);
  return new;
end $$;
create trigger push_objections after insert on objections for each row execute function push_on_objection();
revoke execute on function push_on_objection() from public, anon, authenticated;

create function push_on_analysis() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform push_enqueue((select owner_id from rooms where id = new.room_id), 'call_ready', new.room_id,
    jsonb_build_object('headline', left(coalesce(new.verdict ->> 'headline', ''), 140)), 'ready:' || new.id);
  return new;
end $$;
create trigger push_analyses after insert on analyses for each row execute function push_on_analysis();
revoke execute on function push_on_analysis() from public, anon, authenticated;

-- The call is made: everyone in the room except the owner hears it.
create function push_on_decided() returns trigger language plpgsql security definer set search_path = public as $$
declare m record;
begin
  if new.status <> 'decided' or old.status = 'decided' then return new; end if;
  for m in select user_id from memberships where room_id = new.id and user_id <> new.owner_id loop
    perform push_enqueue(m.user_id, 'decided', new.id, '{}', null);
  end loop;
  return new;
end $$;
create trigger push_rooms after update of status on rooms for each row execute function push_on_decided();
revoke execute on function push_on_decided() from public, anon, authenticated;

-- Talk: one notification per person per room every 10 minutes at most.
create function push_on_message() returns trigger language plpgsql security definer set search_path = public as $$
declare m record; who text; bucket text;
begin
  if new.hidden then return new; end if;
  who := push_name(new.user_id);
  bucket := (extract(epoch from new.created_at)::bigint / 600)::text;
  for m in select user_id from memberships where room_id = new.room_id and user_id <> new.user_id loop
    perform push_enqueue(m.user_id, 'talk', new.room_id, jsonb_build_object('name', who, 'body', left(new.body, 140)),
      'talk:' || new.room_id || ':' || m.user_id || ':' || bucket);
  end loop;
  return new;
end $$;
create trigger push_messages after insert on room_messages for each row execute function push_on_message();
revoke execute on function push_on_message() from public, anon, authenticated;

create function push_on_reopen() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform push_enqueue((select owner_id from rooms where id = new.room_id), 'reopen', new.room_id,
    jsonb_build_object('name', push_name(new.user_id)), 'reopen:' || new.id);
  return new;
end $$;
create trigger push_reopen after insert on reopen_requests for each row execute function push_on_reopen();
revoke execute on function push_on_reopen() from public, anon, authenticated;

-- A plan item handed to someone (not to yourself). A whole drafted plan sends one notification per 10 minutes.
create function push_on_plan() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.assignee is null or new.assignee = coalesce(auth.uid(), new.created_by) then return new; end if;
  if tg_op = 'UPDATE' and old.assignee is not distinct from new.assignee then return new; end if;
  perform push_enqueue(new.assignee, 'plan_assigned', new.room_id, jsonb_build_object('title', left(new.title, 140)),
    'assigned:' || new.room_id || ':' || new.assignee || ':' || (extract(epoch from now())::bigint / 600)::text);
  return new;
end $$;
create trigger push_plan after insert or update of assignee on plan_items for each row execute function push_on_plan();
revoke execute on function push_on_plan() from public, anon, authenticated;

-- Once a day (the worker calls it often; each reminder goes once a day): plan items due today, and review day.
create function push_daily() returns void language plpgsql security definer set search_path = public as $$
declare x record;
begin
  for x in select p.id, p.room_id, p.assignee, p.title from plan_items p join rooms r on r.id = p.room_id
           where p.due_date = current_date and p.status <> 'done' and p.assignee is not null and r.status in ('decided', 'reviewed') loop
    perform push_enqueue(x.assignee, 'plan_due', x.room_id, jsonb_build_object('title', left(x.title, 140)), 'due:' || x.id || ':' || current_date);
  end loop;
  for x in select id, owner_id from rooms where review_date = current_date and status = 'decided' loop
    perform push_enqueue(x.owner_id, 'review_due', x.id, '{}', 'review:' || x.id || ':' || current_date);
  end loop;
end $$;
revoke execute on function push_daily() from public, anon, authenticated;
grant execute on function push_daily() to service_role;

-- The worker takes waiting notifications (each one is sent at most once), with the room's question and language.
create function claim_push(n int default 100)
returns table (id bigint, user_id uuid, event text, room_id uuid, data jsonb, question text, language text)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with picked as (
    select o.id from push_outbox o where o.sent_at is null and o.created_at > now() - interval '1 day'
    order by o.id limit n for update skip locked
  ), done as (
    update push_outbox o set sent_at = now() from picked where o.id = picked.id returning o.*
  )
  select d.id, d.user_id, d.event, d.room_id, d.data, r.question, r.language::text
  from done d left join rooms r on r.id = d.room_id order by d.id;
end $$;
revoke execute on function claim_push(int) from public, anon, authenticated;
grant execute on function claim_push(int) to service_role;
